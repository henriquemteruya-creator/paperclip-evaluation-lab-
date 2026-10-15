#!/usr/bin/env bash
# Offline checks for the fail-closed verifiers in .github/workflows/preflight.yml.
# This script never invokes Docker, GitHub Actions, or Paperclip.
set -Eeuo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
workflow="${PREFLIGHT_WORKFLOW:-$root_dir/.github/workflows/preflight.yml}"
[[ -f "$workflow" ]] || { printf 'FAIL workflow not found: %s\n' "$workflow" >&2; exit 1; }
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

assert_rc() {
  local expected="$1" actual="$2" label="$3"
  [[ "$actual" == "$expected" ]] || {
    printf 'FAIL %s: expected rc=%s, got rc=%s\n' "$label" "$expected" "$actual" >&2
    exit 1
  }
  printf 'PASS %s\n' "$label"
}

route_verdict() {
  local ip_command="$1" family="$2" output rc
  output="$tmpdir/route-${family}"
  if "$ip_command" "-$family" route show default >"$output" 2>&1; then
    rc=0
  else
    rc=$?
  fi
  (( rc == 0 )) || return 2
  [[ ! -s "$output" ]] || return 1
}

embedded_bash="$tmpdir/preflight-step.sh"
awk '
  /^[[:space:]]*run: \|[[:space:]]*$/ { in_run = 1; next }
  in_run { sub(/^          /, ""); print }
' "$workflow" >"$embedded_bash"
bash -n "$embedded_bash"
tmpfs_validator="$tmpdir/tmpfs-validator.sh"
awk '
  /TMPFS_VALIDATOR_BEGIN/ { in_program = 1; next }
  /TMPFS_VALIDATOR_END/ { exit }
  in_program { sub(/^            /, ""); print }
' "$workflow" >"$tmpfs_validator"
[[ -s "$tmpfs_validator" ]] || { printf 'FAIL tmpfs validator was not extracted from workflow\n' >&2; exit 1; }
# shellcheck source=/dev/null
source "$tmpfs_validator"
tmpfs_verdict() { validate_tmpfs_config "$1" >/dev/null; }
tmpfs_inspect_verdict() { validate_inspected_tmpfs >/dev/null; }
docker_reported_mounts_validator="$tmpdir/docker-reported-mounts-validator.sh"
awk '
  /DOCKER_REPORTED_MOUNTS_VALIDATOR_BEGIN/ { in_program = 1; next }
  /DOCKER_REPORTED_MOUNTS_VALIDATOR_END/ { exit }
  in_program { sub(/^            /, ""); print }
' "$workflow" >"$docker_reported_mounts_validator"
[[ -s "$docker_reported_mounts_validator" ]] || { printf 'FAIL Docker-reported-mount validator was not extracted from workflow\n' >&2; exit 1; }
# shellcheck source=/dev/null
source "$docker_reported_mounts_validator"
docker_reported_mounts_verdict() { validate_docker_reported_mounts "$1"; }
socket_classifier="$tmpdir/socket-scan-classifier.sh"
awk '
  /SOCKET_SCAN_CLASSIFIER_BEGIN/ { in_program = 1; next }
  /SOCKET_SCAN_CLASSIFIER_END/ { exit }
  in_program { sub(/^          /, ""); print }
' "$workflow" >"$socket_classifier"
[[ -s "$socket_classifier" ]] || { printf 'FAIL socket classifier was not extracted from workflow\n' >&2; exit 1; }
# shellcheck source=/dev/null
source "$socket_classifier"
mountinfo_program="$tmpdir/mountinfo-verifier.awk"
awk '
  /MOUNTINFO_AWK_BEGIN/ { in_program = 1; next }
  /MOUNTINFO_AWK_END/ { exit }
  in_program { sub(/^            /, ""); print }
' "$workflow" >"$mountinfo_program"
[[ -s "$mountinfo_program" ]] || { printf 'FAIL mountinfo verifier was not extracted from workflow\n' >&2; exit 1; }
set +e
awk -f "$mountinfo_program" /dev/null >/dev/null 2>"$tmpdir/mountinfo-awkeval.err"
awk_rc=$?
set -e
[[ "$awk_rc" == 2 && ! -s "$tmpdir/mountinfo-awkeval.err" ]] || {
  printf 'FAIL extracted mountinfo verifier is not valid AWK\n' >&2
  exit 1
}
mountinfo_verdict() { awk -f "$mountinfo_program" "$1"; }
rg -Fq 'mountinfo_inspection_error_rc_' "$workflow"
rg -Fq 'verify_no_default_route 4' "$workflow"
rg -Fq 'verify_no_default_route 6' "$workflow"
rg -Fq 'docker_reported_mounts=' "$workflow"
if rg -Fq 'mount_count ==' "$workflow"; then
  printf 'FAIL workflow still assumes a fixed Docker .Mounts count\n' >&2
  exit 1
fi
printf 'PASS workflow_static_contract\n'

tmpfs_equivalent=$'/tmp|size=67108864,nosuid,rw,noexec\n/run|noexec,size=8MiB,rw,nosuid'
set +e; tmpfs_verdict "$tmpfs_equivalent"; rc=$?; set -e
assert_rc 0 "$rc" tmpfs_equivalent_order_and_size_pass

tmpfs_equivalent_units=$'/run|size=8192k,nosuid,noexec,rw\n/tmp|rw,size=64mb,noexec,nosuid'
set +e; tmpfs_verdict "$tmpfs_equivalent_units"; rc=$?; set -e
assert_rc 0 "$rc" tmpfs_equivalent_units_pass

tmpfs_too_large=$'/tmp|rw,noexec,nosuid,size=65m\n/run|rw,noexec,nosuid,size=8m'
set +e; tmpfs_verdict "$tmpfs_too_large"; rc=$?; set -e
assert_rc 1 "$rc" tmpfs_excessive_size_is_no_go

tmpfs_missing_flag=$'/tmp|rw,nosuid,size=64m\n/run|rw,noexec,nosuid,size=8m'
set +e; tmpfs_verdict "$tmpfs_missing_flag"; rc=$?; set -e
assert_rc 1 "$rc" tmpfs_missing_noexec_is_no_go

tmpfs_extra_mount=$'/tmp|rw,noexec,nosuid,size=64m\n/run|rw,noexec,nosuid,size=8m\n/scratch|rw,noexec,nosuid,size=1m'
set +e; tmpfs_verdict "$tmpfs_extra_mount"; rc=$?; set -e
assert_rc 1 "$rc" tmpfs_extra_mount_is_no_go
set +e; tmpfs_diagnostic="$(validate_tmpfs_config "$tmpfs_extra_mount")"; rc=$?; set -e
assert_rc 1 "$rc" tmpfs_extra_mount_diagnostic_is_no_go
[[ "$tmpfs_diagnostic" == *'tmpfs_unexpected_key_count=1'* && "$tmpfs_diagnostic" != *'/scratch'* && "$tmpfs_diagnostic" != *'size=1m'* ]] || {
  printf 'FAIL tmpfs diagnostic exposed an unexpected path or raw option\n' >&2
  exit 1
}
printf 'PASS tmpfs_diagnostic_is_sanitized\n'

tmpfs_malformed=$'/tmp|rw,noexec,nosuid,size=64m\n/run rw,noexec,nosuid,size=8m'
set +e; tmpfs_verdict "$tmpfs_malformed"; rc=$?; set -e
assert_rc 2 "$rc" tmpfs_parser_error_is_no_go

tmpfs_trailing_comma=$'/tmp|rw,noexec,nosuid,size=64m,\n/run|rw,noexec,nosuid,size=8m'
set +e; tmpfs_verdict "$tmpfs_trailing_comma"; rc=$?; set -e
assert_rc 2 "$rc" tmpfs_trailing_comma_is_no_go

tmpfs_unknown_sentinel='/unexpected/sensitive-tmpfs-key'
tmpfs_unknown_trailing_comma="$tmpfs_unknown_sentinel|rw,noexec,nosuid,size=64m,"$'\n'"/run|rw,noexec,nosuid,size=8m"
set +e; tmpfs_diagnostic="$(validate_tmpfs_config "$tmpfs_unknown_trailing_comma")"; rc=$?; set -e
assert_rc 2 "$rc" tmpfs_unknown_trailing_comma_is_no_go
[[ "$tmpfs_diagnostic" == *'tmpfs_key=unexpected state=invalid'* && "$tmpfs_diagnostic" != *"$tmpfs_unknown_sentinel"* ]] || {
  printf 'FAIL malformed unexpected tmpfs key was exposed in diagnostic\n' >&2
  exit 1
}

tmpfs_unknown_double_comma="$tmpfs_unknown_sentinel|rw,,noexec,nosuid,size=64m"$'\n'"/run|rw,noexec,nosuid,size=8m"
set +e; tmpfs_diagnostic="$(validate_tmpfs_config "$tmpfs_unknown_double_comma")"; rc=$?; set -e
assert_rc 2 "$rc" tmpfs_unknown_double_comma_is_no_go
[[ "$tmpfs_diagnostic" == *'tmpfs_key=unexpected state=invalid'* && "$tmpfs_diagnostic" != *"$tmpfs_unknown_sentinel"* ]] || {
  printf 'FAIL doubly malformed unexpected tmpfs key was exposed in diagnostic\n' >&2
  exit 1
}
printf 'PASS tmpfs_unknown_key_diagnostic_is_sanitized\n'

docker_mount_sentinel='/unexpected/sensitive-docker-destination'
set +e; docker_reported_mount_diagnostic="$(docker_reported_mounts_verdict "bind|$docker_mount_sentinel|true")"; rc=$?; set -e
assert_rc 1 "$rc" docker_reported_unexpected_mount_is_no_go
[[ "$docker_reported_mount_diagnostic" == 'docker_reported_mount_unexpected_count=1' && "$docker_reported_mount_diagnostic" != *"$docker_mount_sentinel"* && "$docker_reported_mount_diagnostic" != *'bind'* ]] || {
  printf 'FAIL Docker-reported mount diagnostic exposed an unexpected mount\n' >&2
  exit 1
}
printf 'PASS docker_reported_mount_diagnostic_is_sanitized\n'

inspect_value() { return 9; }
set +e; tmpfs_inspect_verdict; rc=$?; set -e
assert_rc 2 "$rc" tmpfs_inspect_error_is_no_go
unset -f inspect_value

socket_stderr="$tmpdir/socket-stderr"
socket_result="$tmpdir/socket-result"
: >"$socket_stderr"; : >"$socket_result"
set +e; socket_diagnostic="$(classify_socket_scan 1 "$socket_stderr" "$socket_result")"; rc=$?; set -e
assert_rc 1 "$rc" socket_tool_or_io_failure_is_no_go
[[ "$socket_diagnostic" == socket_scan_incomplete_tool_or_io_rc_1 ]] || { printf 'FAIL unexpected socket tool/IO diagnostic\n' >&2; exit 1; }
set +e; socket_diagnostic="$(classify_socket_scan 127 "$socket_stderr" "$socket_result")"; rc=$?; set -e
assert_rc 1 "$rc" socket_tool_unavailable_is_no_go
[[ "$socket_diagnostic" == socket_scan_tool_unavailable ]] || { printf 'FAIL unexpected socket unavailable diagnostic\n' >&2; exit 1; }
printf '%s\n' 'Permission denied: hidden directory' >"$socket_stderr"
set +e; socket_diagnostic="$(classify_socket_scan 1 "$socket_stderr" "$socket_result")"; rc=$?; set -e
assert_rc 1 "$rc" socket_permission_failure_is_no_go
[[ "$socket_diagnostic" == socket_scan_incomplete_permission_rc_1 ]] || { printf 'FAIL unexpected socket permission diagnostic\n' >&2; exit 1; }
: >"$socket_stderr"; printf '%s\n' 'opaque candidate marker' >"$socket_result"
set +e; socket_diagnostic="$(classify_socket_scan 0 "$socket_stderr" "$socket_result")"; rc=$?; set -e
assert_rc 1 "$rc" socket_candidate_is_no_go
[[ "$socket_diagnostic" == host_control_socket_candidate_found ]] || { printf 'FAIL unexpected socket candidate diagnostic\n' >&2; exit 1; }
: >"$socket_result"
set +e; socket_diagnostic="$(classify_socket_scan 0 "$socket_stderr" "$socket_result")"; rc=$?; set -e
assert_rc 0 "$rc" socket_complete_scan_passes
[[ "$socket_diagnostic" == socket_scan_complete_no_candidates ]] || { printf 'FAIL unexpected clean socket diagnostic\n' >&2; exit 1; }

printf '%s\n' \
  '36 25 0:32 / / ro,relatime - overlay overlay ro' \
  '37 36 0:33 / /proc rw,nosuid,nodev,noexec,relatime - proc proc rw' \
  '38 36 0:34 / /dev rw,nosuid - tmpfs tmpfs rw' \
  '39 38 0:35 / /dev/pts rw,nosuid,noexec,relatime - devpts devpts rw' \
  '40 38 0:36 / /dev/mqueue rw,nosuid,nodev,noexec,relatime - mqueue mqueue rw' \
  '41 38 0:37 / /dev/shm rw,nosuid,nodev,noexec,relatime - tmpfs shm rw' \
  '42 36 0:38 / /sys ro,nosuid,nodev,noexec,relatime - sysfs sysfs ro' \
  '43 42 0:39 / /sys/fs/cgroup ro,nosuid,nodev,noexec,relatime - cgroup2 cgroup ro' \
  '44 36 0:40 / /tmp rw,nosuid,noexec - tmpfs tmpfs rw' \
  '45 36 0:41 / /run rw,nosuid,noexec - tmpfs tmpfs rw' \
  '46 36 0:42 / /etc/hosts rw,relatime - tmpfs tmpfs rw' \
  '47 36 0:42 / /etc/hostname rw,relatime - tmpfs tmpfs rw' \
  '48 36 0:42 / /etc/resolv.conf rw,relatime - tmpfs tmpfs rw' >"$tmpdir/mounts-allowed"
set +e; mountinfo_verdict "$tmpdir/mounts-allowed"; rc=$?; set -e
assert_rc 0 "$rc" mountinfo_allowed

printf '%s\n' '36 25 0:32 / /__w rw - ext4 /dev/sda1 rw' >"$tmpdir/mounts-forbidden"
set +e; mountinfo_verdict "$tmpdir/mounts-forbidden"; rc=$?; set -e
assert_rc 1 "$rc" mountinfo_forbidden_is_no_go

printf '%s\n' \
  '36 25 0:32 / / ro,relatime - overlay overlay ro' \
  '37 36 0:33 / /proc rw,nosuid,nodev,noexec,relatime - proc proc rw' \
  '38 37 8:1 / /proc/unexpected-host-mount rw,relatime - ext4 /dev/sda1 rw' >"$tmpdir/mounts-unexpected-proc"
set +e; mountinfo_verdict "$tmpdir/mounts-unexpected-proc"; rc=$?; set -e
assert_rc 1 "$rc" unexpected_proc_descendant_is_no_go
set +e; mountinfo_diagnostic="$(mountinfo_verdict "$tmpdir/mounts-unexpected-proc")"; rc=$?; set -e
assert_rc 1 "$rc" unexpected_proc_diagnostic_is_no_go
[[ "$mountinfo_diagnostic" == *'reason=destination_not_allowlisted destination_class=proc_descendant'* && "$mountinfo_diagnostic" != *'/proc/unexpected-host-mount'* && "$mountinfo_diagnostic" != *'/dev/sda1'* ]] || {
  printf 'FAIL unexpected mount diagnostic exposed sensitive mountinfo fields\n' >&2
  exit 1
}
printf 'PASS unexpected_mount_diagnostic_is_sanitized\n'

printf '%s\n' '36 25 0:32 / /tmp rw,nosuid,noexec - ext4 /dev/sda1 rw' >"$tmpdir/mounts-known-identity-mismatch"
set +e; mountinfo_diagnostic="$(mountinfo_verdict "$tmpdir/mounts-known-identity-mismatch")"; rc=$?; set -e
assert_rc 1 "$rc" known_mount_identity_mismatch_is_no_go
[[ "$mountinfo_diagnostic" == *'reason=filesystem_or_source_incompatible destination_class=expected'* ]] || {
  printf 'FAIL missing known-mount identity diagnostic\n' >&2
  exit 1
}

printf '%s\n' '36 25 0:32 / /tmp rw,nosuid - tmpfs tmpfs rw' >"$tmpdir/mounts-known-options-mismatch"
set +e; mountinfo_diagnostic="$(mountinfo_verdict "$tmpdir/mounts-known-options-mismatch")"; rc=$?; set -e
assert_rc 1 "$rc" known_mount_options_mismatch_is_no_go
[[ "$mountinfo_diagnostic" == *'reason=mount_options_incompatible destination_class=expected destination_id=tmp per_mount=missing_noexec superblock_access=rw'* ]] || {
  printf 'FAIL missing known-mount options diagnostic\n' >&2
  exit 1
}

printf '%s\n' '36 25 0:32 / /etc/hosts rw,relatime - tmpfs /private/host-generated-file rw' >"$tmpdir/mounts-etc-identity-mismatch"
set +e; mountinfo_diagnostic="$(mountinfo_verdict "$tmpdir/mounts-etc-identity-mismatch")"; rc=$?; set -e
assert_rc 1 "$rc" etc_special_identity_mismatch_is_no_go
[[ "$mountinfo_diagnostic" == *'reason=filesystem_or_source_incompatible destination_class=expected destination_id=etc_hosts fstype_category=tmpfs source_category=other'* && "$mountinfo_diagnostic" != *'/private/host-generated-file'* ]] || {
  printf 'FAIL etc special-file diagnostic is missing or exposed raw source\n' >&2
  exit 1
}
printf 'PASS etc_special_identity_diagnostic_is_sanitized\n'

printf '%s\n' '36 25 0:32 / /etc/hostname ro,relatime - tmpfs tmpfs ro' >"$tmpdir/mounts-etc-options-mismatch"
set +e; mountinfo_diagnostic="$(mountinfo_verdict "$tmpdir/mounts-etc-options-mismatch")"; rc=$?; set -e
assert_rc 1 "$rc" etc_special_options_mismatch_is_no_go
[[ "$mountinfo_diagnostic" == *'destination_id=etc_hostname per_mount=access_rw_required superblock_access=ro'* ]] || {
  printf 'FAIL etc special-file options diagnostic is incomplete\n' >&2
  exit 1
}

printf '%s\n' \
  '36 25 0:32 / /tmp rw,nosuid,noexec - tmpfs tmpfs rw' \
  '37 25 0:32 / /tmp rw,nosuid,noexec - tmpfs tmpfs rw' >"$tmpdir/mounts-duplicate"
set +e; mountinfo_diagnostic="$(mountinfo_verdict "$tmpdir/mounts-duplicate")"; rc=$?; set -e
assert_rc 1 "$rc" duplicate_mount_is_no_go
[[ "$mountinfo_diagnostic" == *'reason=duplicate_destination destination_class=expected'* ]] || {
  printf 'FAIL missing duplicate-mount diagnostic\n' >&2
  exit 1
}

printf '%s\n' \
  '36 25 0:32 / / ro,relatime - overlay overlay ro' \
  '37 36 8:1 / /sys/unexpected-host-mount rw,relatime - ext4 /dev/sda1 rw' >"$tmpdir/mounts-unexpected-sys"
set +e; mountinfo_verdict "$tmpdir/mounts-unexpected-sys"; rc=$?; set -e
assert_rc 1 "$rc" unexpected_sys_descendant_is_no_go

printf '%s\n' \
  '36 25 0:32 / / ro,relatime - overlay overlay ro' \
  '37 36 8:1 / /dev/unexpected-host-mount rw,relatime - ext4 /dev/sda1 rw' >"$tmpdir/mounts-unexpected-dev"
set +e; mountinfo_verdict "$tmpdir/mounts-unexpected-dev"; rc=$?; set -e
assert_rc 1 "$rc" unexpected_dev_descendant_is_no_go

: >"$tmpdir/mounts-empty"
set +e; mountinfo_verdict "$tmpdir/mounts-empty"; rc=$?; set -e
assert_rc 2 "$rc" empty_mountinfo_is_no_go

printf '%s\n' 'malformed mountinfo record' >"$tmpdir/mounts-malformed"
set +e; mountinfo_verdict "$tmpdir/mounts-malformed"; rc=$?; set -e
assert_rc 2 "$rc" malformed_mountinfo_is_no_go

set +e; mountinfo_verdict "$tmpdir/does-not-exist" 2>/dev/null; rc=$?; set -e
(( rc >= 2 )) || { printf 'FAIL unreadable mountinfo did not return an error\n' >&2; exit 1; }
printf 'PASS mountinfo_error_is_no_go\n'

fake_ip="$tmpdir/ip"
printf '%s\n' '#!/usr/bin/env bash' 'exit 7' >"$fake_ip"
chmod 700 "$fake_ip"
set +e; route_verdict "$fake_ip" 4; rc=$?; set -e
assert_rc 2 "$rc" ipv4_query_error_is_no_go
set +e; route_verdict "$fake_ip" 6; rc=$?; set -e
assert_rc 2 "$rc" ipv6_query_error_is_no_go

printf '%s\n' '#!/usr/bin/env bash' 'printf "default via 192.0.2.1\\n"' >"$fake_ip"
chmod 700 "$fake_ip"
set +e; route_verdict "$fake_ip" 4; rc=$?; set -e
assert_rc 1 "$rc" ipv4_route_present_is_no_go

printf '%s\n' '#!/usr/bin/env bash' 'exit 0' >"$fake_ip"
chmod 700 "$fake_ip"
set +e; route_verdict "$fake_ip" 6; rc=$?; set -e
assert_rc 0 "$rc" ipv6_no_route_passes

printf '%s\n' 'PASS preflight_v2_static_complete'
