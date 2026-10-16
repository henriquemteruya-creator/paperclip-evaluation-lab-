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
docker_special_files_diagnostic="$tmpdir/docker-special-files-diagnostic.sh"
awk '
  /DOCKER_SPECIAL_FILES_DIAGNOSTIC_BEGIN/ { in_program = 1; next }
  /DOCKER_SPECIAL_FILES_DIAGNOSTIC_END/ { exit }
  in_program { sub(/^            /, ""); print }
' "$workflow" >"$docker_special_files_diagnostic"
[[ -s "$docker_special_files_diagnostic" ]] || { printf 'FAIL Docker special-file diagnostic was not extracted from workflow\n' >&2; exit 1; }
# shellcheck source=/dev/null
source "$docker_special_files_diagnostic"
docker_special_correlation_result="$tmpdir/docker-special-correlation-result.sh"
awk '
  /DOCKER_SPECIAL_CORRELATION_RESULT_BEGIN/ { in_program = 1; next }
  /DOCKER_SPECIAL_CORRELATION_RESULT_END/ { exit }
  in_program { sub(/^            /, ""); print }
' "$workflow" >"$docker_special_correlation_result"
[[ -s "$docker_special_correlation_result" ]] || { printf 'FAIL Docker special-file result handler was not extracted from workflow\n' >&2; exit 1; }
# shellcheck source=/dev/null
source "$docker_special_correlation_result"
# The extracted result handler depends only on these trusted workflow helpers;
# keep the test stubs equivalent and silent so diagnostics never leak fixtures.
diagnostic_no_go() { diagnostic_findings+=("$1"); }
info() { :; }
preflight_decision_helpers="$tmpdir/preflight-decision-helpers.sh"
awk '
  /PREFLIGHT_DECISION_HELPERS_BEGIN/ { in_program = 1; next }
  /PREFLIGHT_DECISION_HELPERS_END/ { exit }
  in_program { sub(/^          /, ""); print }
' "$workflow" >"$preflight_decision_helpers"
[[ -s "$preflight_decision_helpers" ]] || { printf 'FAIL preflight decision helpers were not extracted from workflow\n' >&2; exit 1; }
# shellcheck source=/dev/null
source "$preflight_decision_helpers"
runtime_mask_shell="$tmpdir/runtime-mask-diagnostic.sh"
awk '
  /RUNTIME_MASK_DIAGNOSTIC_AWK_BEGIN/ { in_program = 1; next }
  /RUNTIME_MASK_DIAGNOSTIC_AWK_END/ { exit }
  in_program { sub(/^          /, ""); print }
' "$workflow" >"$runtime_mask_shell"
[[ -s "$runtime_mask_shell" ]] || { printf 'FAIL runtime mask mount diagnostic was not extracted from workflow\n' >&2; exit 1; }
# shellcheck source=/dev/null
source "$runtime_mask_shell"
runtime_mask_verdict() { awk "$runtime_mask_diagnostic_awk" "$1"; }
runtime_object_diagnostic="$tmpdir/runtime-object-diagnostic.sh"
awk '
  /RUNTIME_OBJECT_DIAGNOSTIC_BEGIN/ { in_program = 1; next }
  /RUNTIME_OBJECT_DIAGNOSTIC_END/ { exit }
  in_program { sub(/^          /, ""); print }
' "$workflow" >"$runtime_object_diagnostic"
[[ -s "$runtime_object_diagnostic" ]] || { printf 'FAIL runtime mask object diagnostic was not extracted from workflow\n' >&2; exit 1; }
# shellcheck source=/dev/null
source "$runtime_object_diagnostic"
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

docker_special_sentinel="$tmpdir/private-special-source"
printf -v docker_special_entries '%s\n%s\n%s\n%s\n%s' "/etc/hosts|bind|false|$docker_special_sentinel/hosts" "/etc/hostname|bind|true|$docker_special_sentinel/hostname" "/etc/resolv.conf|bind|false|$docker_special_sentinel/resolv" '/tmp|tmpfs|true|tmpfs' '/run|tmpfs|true|tmpfs'
set +e; docker_special_diagnostic="$(diagnose_docker_special_files "$docker_special_entries" "$docker_special_sentinel/hosts" "$docker_special_sentinel/hostname" "$docker_special_sentinel/resolv" true)"; rc=$?; set -e
assert_rc 0 "$rc" docker_special_file_correlation_passes
[[ "$docker_special_diagnostic" == *'id=etc_hosts cardinality_one=true type_bind=true metadata_present=true metadata_source_match=true mount_rw=false readonly_rootfs=true'* && "$docker_special_diagnostic" == *'id=etc_hostname cardinality_one=true type_bind=true metadata_present=true metadata_source_match=true mount_rw=true readonly_rootfs=true'* && "$docker_special_diagnostic" != *"$docker_special_sentinel"* ]] || {
  printf 'FAIL Docker special-file diagnostic is incomplete or exposed a source\n' >&2
  exit 1
}
printf 'PASS docker_special_file_diagnostic_is_sanitized\n'

printf -v docker_special_missing_metadata '%s\n%s\n%s' "/etc/hosts|bind|false|$docker_special_sentinel/hosts" "/etc/hostname|bind|false|$docker_special_sentinel/hostname" "/etc/resolv.conf|bind|false|$docker_special_sentinel/resolv"
set +e; docker_special_diagnostic="$(diagnose_docker_special_files "$docker_special_missing_metadata" '' "$docker_special_sentinel/hostname" "$docker_special_sentinel/resolv" true)"; rc=$?; set -e
assert_rc 1 "$rc" docker_special_missing_metadata_is_no_go
[[ "$docker_special_diagnostic" != *"$docker_special_sentinel"* ]] || { printf 'FAIL missing metadata diagnostic exposed a source\n' >&2; exit 1; }

printf -v docker_special_wrong_type '%s\n%s\n%s' "/etc/hosts|volume|false|$docker_special_sentinel/hosts" "/etc/hostname|bind|false|$docker_special_sentinel/hostname" "/etc/resolv.conf|bind|false|$docker_special_sentinel/resolv"
set +e; docker_special_diagnostic="$(diagnose_docker_special_files "$docker_special_wrong_type" "$docker_special_sentinel/hosts" "$docker_special_sentinel/hostname" "$docker_special_sentinel/resolv" true)"; rc=$?; set -e
assert_rc 1 "$rc" docker_special_wrong_type_is_no_go
[[ "$docker_special_diagnostic" != *"$docker_special_sentinel"* ]] || { printf 'FAIL wrong-type diagnostic exposed a source\n' >&2; exit 1; }

printf -v docker_special_unexpected '%s\n%s\n%s\n%s' "/etc/hosts|bind|false|$docker_special_sentinel/hosts" "/etc/hostname|bind|false|$docker_special_sentinel/hostname" "/etc/resolv.conf|bind|false|$docker_special_sentinel/resolv" "/private/unexpected|bind|false|$docker_special_sentinel/unexpected"
set +e; docker_special_diagnostic="$(diagnose_docker_special_files "$docker_special_unexpected" "$docker_special_sentinel/hosts" "$docker_special_sentinel/hostname" "$docker_special_sentinel/resolv" true)"; rc=$?; set -e
assert_rc 1 "$rc" docker_special_unexpected_mount_is_no_go
[[ "$docker_special_diagnostic" == *'docker_special_file_unexpected_count=1'* && "$docker_special_diagnostic" != *"$docker_special_sentinel"* && "$docker_special_diagnostic" != *'/private/unexpected'* ]] || { printf 'FAIL unexpected special-file mount was exposed\n' >&2; exit 1; }

set +e; docker_special_diagnostic="$(diagnose_docker_special_files "$docker_special_entries" "$docker_special_sentinel/hosts" "$docker_special_sentinel/hostname" "$docker_special_sentinel/resolv" maybe)"; rc=$?; set -e
assert_rc 2 "$rc" docker_special_malformed_readonly_metadata_is_no_go
[[ "$docker_special_diagnostic" == docker_special_file_parser_error && "$docker_special_diagnostic" != *"$docker_special_sentinel"* ]] || { printf 'FAIL malformed special metadata was exposed\n' >&2; exit 1; }

# An empty or partial .Mounts report is diagnostic-only: it must never be
# treated as correlation evidence or turn the final verdict into GO, but it
# also must not suppress runtime data collection after mandatory controls pass.
set +e; docker_special_diagnostic="$(diagnose_docker_special_files '' "$docker_special_sentinel/hosts" "$docker_special_sentinel/hostname" "$docker_special_sentinel/resolv" true)"; rc=$?; set -e
assert_rc 1 "$rc" docker_special_empty_mounts_is_inconclusive
[[ "$docker_special_diagnostic" == *'cardinality_one=false'* && "$docker_special_diagnostic" != *"$docker_special_sentinel"* ]] || { printf 'FAIL empty special-mount report was not sanitized\n' >&2; exit 1; }

printf -v docker_special_partial '%s\n%s' "/etc/hosts|bind|false|$docker_special_sentinel/hosts" "/etc/hostname|bind|false|$docker_special_sentinel/hostname"
set +e; docker_special_diagnostic="$(diagnose_docker_special_files "$docker_special_partial" "$docker_special_sentinel/hosts" "$docker_special_sentinel/hostname" "$docker_special_sentinel/resolv" true)"; rc=$?; set -e
assert_rc 1 "$rc" docker_special_partial_mounts_is_inconclusive

hard_prestart_failures=()
diagnostic_findings=()
set +e; record_docker_special_correlation_result 1; rc=$?; set -e
assert_rc 0 "$rc" docker_special_incomplete_result_is_recorded
runtime_collection_permitted; rc=$?
assert_rc 0 "$rc" incomplete_special_correlation_does_not_block_runtime_collection
set +e; final_verdict_is_go; rc=$?; set -e
assert_rc 1 "$rc" incomplete_special_correlation_preserves_final_no_go
[[ "${diagnostic_findings[*]}" == 'docker special-file correlation incomplete or unexpected' ]] || { printf 'FAIL incomplete special correlation was not recorded\n' >&2; exit 1; }

hard_prestart_failures=()
diagnostic_findings=()
set +e; record_docker_special_correlation_result inspect_error; rc=$?; set -e
assert_rc 0 "$rc" docker_special_inspect_error_is_recorded
runtime_collection_permitted; rc=$?
assert_rc 0 "$rc" special_inspect_error_does_not_block_runtime_collection
set +e; final_verdict_is_go; rc=$?; set -e
assert_rc 1 "$rc" special_inspect_error_preserves_final_no_go

hard_prestart_failures=('docker reported unexpected mount')
diagnostic_findings=()
set +e; runtime_collection_permitted; rc=$?; set -e
assert_rc 1 "$rc" unexpected_mandatory_mount_blocks_runtime_collection
set +e; final_verdict_is_go; rc=$?; set -e
assert_rc 1 "$rc" unexpected_mandatory_mount_preserves_final_no_go
hard_prestart_failures=()
diagnostic_findings=()
final_verdict_is_go; rc=$?
assert_rc 0 "$rc" clean_preflight_decision_is_go
printf 'PASS special_correlation_decision_is_fail_closed\n'

runtime_mask_valid=$'36 25 0:32 / /proc/acpi ro,nosuid,nodev,noexec - tmpfs tmpfs ro\n37 25 0:33 / /proc/scsi ro,nosuid,nodev,noexec - tmpfs tmpfs ro\n38 25 0:34 / /sys/firmware ro,nosuid,nodev,noexec - tmpfs tmpfs ro\n39 25 0:35 /null /proc/interrupts rw,nosuid,nodev,noexec - tmpfs tmpfs rw\n40 25 0:35 /null /proc/kcore rw,nosuid,nodev,noexec - tmpfs tmpfs rw\n41 25 0:35 /null /proc/keys rw,nosuid,nodev,noexec - tmpfs tmpfs rw\n42 25 0:35 /null /proc/latency_stats rw,nosuid,nodev,noexec - tmpfs tmpfs rw\n43 25 0:35 /null /proc/timer_list rw,nosuid,nodev,noexec - tmpfs tmpfs rw'
printf '%s\n' "$runtime_mask_valid" >"$tmpdir/runtime-mask-valid"
set +e; runtime_mask_diagnostic="$(runtime_mask_verdict "$tmpdir/runtime-mask-valid")"; rc=$?; set -e
assert_rc 0 "$rc" runtime_mask_metadata_complete
[[ "$runtime_mask_diagnostic" == *'runtime_mask_directory id=proc_acpi cardinality_one=true type_source_tmpfs=true root_is_slash=true per_mount_ro=true propagation_markers_absent=true submounts_unexpected=false'* && "$runtime_mask_diagnostic" == *'runtime_mask_file id=proc_interrupts cardinality_one=true type_source_tmpfs=true root_is_null=true per_mount_rw=true propagation_markers_absent=true'* ]] || {
  printf 'FAIL runtime mask diagnostic lacks expected sanitized evidence\n' >&2
  exit 1
}
[[ "$runtime_mask_diagnostic" != *'\\n'* ]] || { printf 'FAIL runtime mask diagnostic contains literal newline escapes\n' >&2; exit 1; }
runtime_mask_line_count="$(printf '%s\n' "$runtime_mask_diagnostic" | awk 'NF { count++ } END { print count + 0 }')"
[[ "$runtime_mask_line_count" == 8 ]] || { printf 'FAIL runtime mask diagnostic expected 8 lines, got %s\n' "$runtime_mask_line_count" >&2; exit 1; }
runtime_mask_record_count="$(printf '%s\n' "$runtime_mask_diagnostic" | grep -Ec '^runtime_mask_(directory|file) id=')"
[[ "$runtime_mask_record_count" == 8 ]] || { printf 'FAIL runtime mask diagnostic expected 8 separate records, got %s\n' "$runtime_mask_record_count" >&2; exit 1; }
printf 'PASS runtime_mask_diagnostic_has_eight_real_lines\n'

runtime_mask_sentinel='/proc/acpi/unexpected-host-mount'
runtime_mask_submount=$'36 25 0:32 / /proc/acpi ro,nosuid,nodev,noexec - tmpfs tmpfs ro\n37 36 8:1 / /proc/acpi/unexpected-host-mount rw - ext4 /private/source rw\n38 25 0:33 / /proc/scsi ro,nosuid,nodev,noexec - tmpfs tmpfs ro\n39 25 0:34 / /sys/firmware ro,nosuid,nodev,noexec - tmpfs tmpfs ro\n40 25 0:35 /null /proc/interrupts rw,nosuid,nodev,noexec - tmpfs tmpfs rw\n41 25 0:35 /null /proc/kcore rw,nosuid,nodev,noexec - tmpfs tmpfs rw\n42 25 0:35 /null /proc/keys rw,nosuid,nodev,noexec - tmpfs tmpfs rw\n43 25 0:35 /null /proc/latency_stats rw,nosuid,nodev,noexec - tmpfs tmpfs rw\n44 25 0:35 /null /proc/timer_list rw,nosuid,nodev,noexec - tmpfs tmpfs rw'
printf '%s\n' "$runtime_mask_submount" >"$tmpdir/runtime-mask-submount"
set +e; runtime_mask_diagnostic="$(runtime_mask_verdict "$tmpdir/runtime-mask-submount")"; rc=$?; set -e
assert_rc 1 "$rc" runtime_mask_submount_is_no_go
[[ "$runtime_mask_diagnostic" == *'id=proc_acpi'*'submounts_unexpected=true'* && "$runtime_mask_diagnostic" != *"$runtime_mask_sentinel"* && "$runtime_mask_diagnostic" != *'/private/source'* ]] || {
  printf 'FAIL runtime mask submount diagnostic exposed raw mount data\n' >&2
  exit 1
}

printf '%s\n' 'malformed mountinfo record' >"$tmpdir/runtime-mask-malformed"
set +e; runtime_mask_verdict "$tmpdir/runtime-mask-malformed" >/dev/null; rc=$?; set -e
assert_rc 2 "$rc" runtime_mask_malformed_mountinfo_is_no_go

mkdir "$tmpdir/empty-masked-directory"
set +e; runtime_object_diagnostic="$(diagnose_masked_directory_objects "proc_acpi|$tmpdir/empty-masked-directory")"; rc=$?; set -e
assert_rc 0 "$rc" runtime_mask_directory_empty_real_object_passes
[[ "$runtime_object_diagnostic" == 'runtime_mask_directory_object id=proc_acpi object_dir=true object_symlink=false empty=true inspection_complete=true' && "$runtime_object_diagnostic" != *"$tmpdir"* ]] || { printf 'FAIL directory-object diagnostic exposed a path\n' >&2; exit 1; }
printf 'x\n' >"$tmpdir/empty-masked-directory/unexpected"
set +e; runtime_object_diagnostic="$(diagnose_masked_directory_objects "proc_acpi|$tmpdir/empty-masked-directory")"; rc=$?; set -e
assert_rc 1 "$rc" runtime_mask_directory_nonempty_is_no_go
rm "$tmpdir/empty-masked-directory/unexpected"
ln -s "$tmpdir/empty-masked-directory" "$tmpdir/masked-directory-link"
set +e; runtime_object_diagnostic="$(diagnose_masked_directory_objects "proc_scsi|$tmpdir/masked-directory-link")"; rc=$?; set -e
assert_rc 1 "$rc" runtime_mask_directory_symlink_is_no_go
[[ "$runtime_object_diagnostic" != *"$tmpdir"* ]] || { printf 'FAIL symlink diagnostic exposed a path\n' >&2; exit 1; }

set +e; runtime_object_diagnostic="$(diagnose_masked_file_objects 'proc_interrupts|/dev/null')"; rc=$?; set -e
assert_rc 0 "$rc" runtime_mask_file_dev_null_identity_passes
[[ "$runtime_object_diagnostic" == 'runtime_mask_file_object id=proc_interrupts character_device=true object_symlink=false null_char_1_3=true null_identity_match=true inspection_complete=true' ]] || { printf 'FAIL file-object diagnostic lacks /dev/null identity result\n' >&2; exit 1; }
printf 'not-a-device\n' >"$tmpdir/not-a-device"
set +e; runtime_object_diagnostic="$(diagnose_masked_file_objects "proc_kcore|$tmpdir/not-a-device")"; rc=$?; set -e
assert_rc 1 "$rc" runtime_mask_file_regular_file_is_no_go
ln -s /dev/null "$tmpdir/masked-file-link"
set +e; runtime_object_diagnostic="$(diagnose_masked_file_objects "proc_keys|$tmpdir/masked-file-link")"; rc=$?; set -e
assert_rc 1 "$rc" runtime_mask_file_symlink_is_no_go
[[ "$runtime_object_diagnostic" != *"$tmpdir"* ]] || { printf 'FAIL file-object diagnostic exposed a path\n' >&2; exit 1; }
set +e; runtime_object_diagnostic="$(diagnose_masked_file_objects "unknown_id|$tmpdir/not-a-device")"; rc=$?; set -e
assert_rc 2 "$rc" runtime_mask_file_unknown_id_is_no_go
printf 'PASS runtime_mask_diagnostics_are_sanitized\n'

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
