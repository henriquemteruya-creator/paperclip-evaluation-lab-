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

# The diagnostic is passed to `docker start` as a literal heredoc.  Parsing the
# enclosing workflow step alone does not parse that payload as Bash, so extract
# the exact YAML body and check it independently.
diagnostic_heredoc="$tmpdir/diagnostic-heredoc.sh"
set +e
awk '
  /docker start --attach --interactive/ && /DIAGNOSTIC/ { in_heredoc = 1; found = 1; next }
  in_heredoc && /^[[:space:]]*DIAGNOSTIC[[:space:]]*$/ { complete = 1; exit }
  in_heredoc { sub(/^          /, ""); print }
  END { if (!found || !complete) exit 2 }
' "$workflow" >"$diagnostic_heredoc"
diagnostic_extract_rc=$?
set -e
assert_rc 0 "$diagnostic_extract_rc" diagnostic_heredoc_extracted_from_yaml
[[ -s "$diagnostic_heredoc" ]] || { printf 'FAIL diagnostic heredoc was empty\n' >&2; exit 1; }
rg -Fq 'MOUNTINFO_AWK_BEGIN' "$diagnostic_heredoc"
rg -Fq 'RUNTIME_MASK_DIAGNOSTIC_AWK_BEGIN' "$diagnostic_heredoc"
bash -n "$diagnostic_heredoc"
printf 'PASS diagnostic_heredoc_bash_syntax\n'

# Run the exact mountinfo AWK shell command after replacing only its input with
# /dev/null.  This exercises the real Bash quote boundary as well as AWK's
# parser, without starting Docker or evaluating the diagnostic payload.
mountinfo_shell_command="$tmpdir/mountinfo-shell-command.sh"
set +e
awk '
  /^[[:space:]]*awk/ { candidate = $0; awaiting_marker = 1; next }
  awaiting_marker && /MOUNTINFO_AWK_BEGIN/ {
    print candidate
    print
    collecting = 1
    awaiting_marker = 0
    next
  }
  collecting {
    if (/\/proc\/self\/mountinfo/) {
      sub(/\/proc\/self\/mountinfo/, "/dev/null")
      print
      complete = 1
      exit
    }
    print
  }
  END { if (!complete) exit 2 }
' "$diagnostic_heredoc" >"$mountinfo_shell_command"
mountinfo_shell_extract_rc=$?
set -e
assert_rc 0 "$mountinfo_shell_extract_rc" mountinfo_awk_shell_command_extracted
bash -n "$mountinfo_shell_command"
set +e
bash "$mountinfo_shell_command" >/dev/null 2>"$tmpdir/mountinfo-shell-command.err"
mountinfo_shell_rc=$?
set -e
assert_rc 2 "$mountinfo_shell_rc" mountinfo_awk_real_bash_quoting_is_valid
[[ ! -s "$tmpdir/mountinfo-shell-command.err" ]] || {
  printf 'FAIL extracted mountinfo AWK emitted a parser error through Bash\n' >&2
  exit 1
}

# A literal apostrophe inside the single-quoted AWK program must make the
# extracted payload unparsable.  Build the negative fixture from the exact
# heredoc so the regression cannot drift away from the workflow source.
apostrophe_marker_line="$(grep -n -m1 'MOUNTINFO_AWK_BEGIN' "$diagnostic_heredoc" | cut -d: -f1)"
[[ "$apostrophe_marker_line" =~ ^[1-9][0-9]*$ ]] || {
  printf 'FAIL mountinfo AWK marker was not found in diagnostic heredoc\n' >&2
  exit 1
}
apostrophe_fixture="$tmpdir/diagnostic-heredoc-unescaped-apostrophe.sh"
{
  sed -n "1,${apostrophe_marker_line}p" "$diagnostic_heredoc"
  printf '%s\n' "              # runc's unescaped apostrophe regression sentinel"
  sed -n "$((apostrophe_marker_line + 1)),\$p" "$diagnostic_heredoc"
} >"$apostrophe_fixture"
set +e
bash -n "$apostrophe_fixture" >/dev/null 2>&1
apostrophe_fixture_rc=$?
set -e
(( apostrophe_fixture_rc != 0 )) || {
  printf 'FAIL an unescaped apostrophe inside AWK was accepted\n' >&2
  exit 1
}
printf 'PASS unescaped_awk_apostrophe_is_rejected\n'
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
docker_managed_etc_runtime="$tmpdir/docker-managed-etc-runtime.sh"
awk '
  /DOCKER_MANAGED_ETC_RUNTIME_DIAGNOSTIC_BEGIN/ { in_program = 1; next }
  /DOCKER_MANAGED_ETC_RUNTIME_DIAGNOSTIC_END/ { exit }
  in_program { sub(/^          /, ""); print }
' "$workflow" >"$docker_managed_etc_runtime"
[[ -s "$docker_managed_etc_runtime" ]] || { printf 'FAIL Docker-managed /etc runtime diagnostic was not extracted from workflow\n' >&2; exit 1; }
# shellcheck source=/dev/null
source "$docker_managed_etc_runtime"

# Exercise the mount-record helper extracted from the real workflow. The
# optional fixture parameter is test-only; production supplies /proc/PID.
mount_record_fixture="$tmpdir/mount-record.fixture"
printf '%s\n' '36 25 0:32 /hosts /etc/hosts rw,nosuid,nodev - ext4 /dev/loop0 rw' >"$mount_record_fixture"
set +e; mount_record_for_target 999 /etc/hosts "$mount_record_fixture" >"$tmpdir/mount-record.out"; rc=$?; set -e
assert_rc 0 "$rc" mount_record_single_cardinality_passes
[[ "$(tr -d '[:space:]' <"$tmpdir/mount-record.out")" == 'true|true' ]] || { printf 'FAIL mount record values were not exact booleans\n' >&2; exit 1; }
[[ "$(od -An -t x1 "$tmpdir/mount-record.out" | tr -d '[:space:]')" == '747275657c747275650a' ]] || { printf 'FAIL mount record did not terminate with one real newline\n' >&2; exit 1; }
IFS='|' read -r mount_record_rw mount_record_propagation <"$tmpdir/mount-record.out"
[[ "$mount_record_rw" == true && "$mount_record_propagation" == true ]] || { printf 'FAIL Bash did not receive exact mount-record booleans\n' >&2; exit 1; }
printf 'PASS mount_record_real_newline_and_bash_values\n'

printf '%s\n' '36 25 0:32 /hosts /etc/hosts ro,nosuid,nodev - ext4 /dev/loop0 ro' >"$mount_record_fixture"
set +e; mount_record_flags="$(mount_record_for_target 999 /etc/hosts "$mount_record_fixture")"; rc=$?; set -e
assert_rc 0 "$rc" mount_record_ro_is_observed
[[ "$mount_record_flags" == 'false|true' ]] || { printf 'FAIL read-only mount record was parsed incorrectly\n' >&2; exit 1; }
printf '%s\n' '36 25 0:32 /hosts /etc/hosts rw,nosuid shared:1 - ext4 /dev/loop0 rw' >"$mount_record_fixture"
set +e; mount_record_flags="$(mount_record_for_target 999 /etc/hosts "$mount_record_fixture")"; rc=$?; set -e
assert_rc 0 "$rc" mount_record_propagation_is_observed
[[ "$mount_record_flags" == 'true|false' ]] || { printf 'FAIL propagation marker was parsed incorrectly\n' >&2; exit 1; }
printf '%s\n' '36 25 0:32 /hosts /etc/hosts rw,nosuid - ext4 /dev/loop0 rw' '37 25 0:33 /hosts /etc/hosts rw,nosuid - ext4 /dev/loop1 rw' >"$mount_record_fixture"
set +e; mount_record_for_target 999 /etc/hosts "$mount_record_fixture" >/dev/null; rc=$?; set -e
assert_rc 1 "$rc" mount_record_duplicate_cardinality_is_no_go
printf '%s\n' '36 25 0:32 /hosts /etc/hosts rw,nosuid' >"$mount_record_fixture"
set +e; mount_record_for_target 999 /etc/hosts "$mount_record_fixture" >/dev/null; rc=$?; set -e
assert_rc 1 "$rc" mount_record_malformed_is_no_go
set +e; mount_record_for_target 999 /etc/hosts "$tmpdir/missing-mountinfo" >/dev/null; rc=$?; set -e
(( rc >= 2 )) || { printf 'FAIL unreadable mountinfo did not remain an inspection error\n' >&2; exit 1; }
printf 'PASS mount_record_read_failure_is_no_go\n'

docker_hosts_path='/private/docker/hosts'
docker_hostname_path='/private/docker/hostname'
docker_resolv_path='/private/docker/resolv'
reported_mounts_valid=$'/etc/hosts|bind|true|/private/docker/hosts\n/etc/hostname|bind|true|/private/docker/hostname\n/etc/resolv.conf|bind|true|/private/docker/resolv\n/tmp|tmpfs|true|tmpfs\n/run|tmpfs|true|tmpfs'
reported_mount_status="$(runtime_reported_etc_mount_status "$reported_mounts_valid" etc_hosts /etc/hosts "$docker_hosts_path")"
[[ "$reported_mount_status" == consistent ]] || { printf 'FAIL exact valid Docker .Mounts fixture was not accepted\n' >&2; exit 1; }
printf 'PASS runtime_mounts_exact_structured_match\n'
reported_mount_duplicate="$reported_mounts_valid"$'\n/etc/hosts|bind|true|/private/docker/hosts'
reported_mount_status="$(runtime_reported_etc_mount_status "$reported_mount_duplicate" etc_hosts /etc/hosts "$docker_hosts_path")"
[[ "$reported_mount_status" == inconsistent ]] || { printf 'FAIL duplicate Docker .Mounts record was accepted\n' >&2; exit 1; }
reported_mount_partial=$'/etc/hosts|bind|true|/private/docker/hosts-unexpected'
reported_mount_status="$(runtime_reported_etc_mount_status "$reported_mount_partial" etc_hosts /etc/hosts "$docker_hosts_path")"
[[ "$reported_mount_status" == inconsistent && "$reported_mount_status" != *private* ]] || { printf 'FAIL partial or raw Docker .Mounts value was accepted or leaked\n' >&2; exit 1; }
reported_mount_extra="$reported_mounts_valid"$'\n/unknown-host-resource|bind|true|/private/docker/unknown'
reported_mount_status="$(runtime_reported_etc_mount_status "$reported_mount_extra" etc_hosts /etc/hosts "$docker_hosts_path")"
[[ "$reported_mount_status" == inconsistent && "$reported_mount_status" != *unknown* ]] || { printf 'FAIL unexpected Docker .Mounts record was accepted or leaked\n' >&2; exit 1; }
reported_mount_status="$(runtime_reported_etc_mount_status '' etc_hosts /etc/hosts "$docker_hosts_path")"
[[ "$reported_mount_status" == unavailable ]] || { printf 'FAIL absent Docker .Mounts evidence was not unavailable\n' >&2; exit 1; }
printf 'PASS runtime_mounts_missing_extra_and_contradictory_are_no_go\n'
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

# The Docker-managed /etc diagnostic is observation-only.  Its validator is
# extracted from the workflow and accepts evidence only when every independent
# predicate holds; callers must still record a final diagnostic NO-GO.
etc_record_valid() {
  validate_docker_managed_etc_record etc_hosts true true true true true true true true true true true true consistent
}
set +e; docker_etc_diagnostic="$(etc_record_valid)"; rc=$?; set -e
assert_rc 0 "$rc" docker_managed_etc_complete_evidence_is_recognized
[[ "$docker_etc_diagnostic" == *'id=etc_hosts'*'provenance_verified=true'*'source_stable=true'*'identity_before=true'*'identity_after=true'*'reported_runtime_mount=consistent'* ]] || {
  printf 'FAIL complete Docker-managed /etc diagnostic is incomplete\n' >&2
  exit 1
}
hard_prestart_failures=()
diagnostic_findings=()
diagnostic_no_go 'docker-managed etc runtime evidence is diagnostic-only'
set +e; final_verdict_is_go; rc=$?; set -e
assert_rc 1 "$rc" docker_etc_complete_evidence_preserves_final_no_go

docker_etc_no_go() {
  local label="$1"; shift
  set +e; docker_etc_diagnostic="$(validate_docker_managed_etc_record "$@")"; rc=$?; set -e
  assert_rc 1 "$rc" "$label"
  [[ "$docker_etc_diagnostic" != *'/private/'* && "$docker_etc_diagnostic" != *'987654'* ]] || {
    printf 'FAIL Docker-managed /etc diagnostic exposed raw fixture data\n' >&2
    exit 1
  }
}
docker_etc_no_go docker_etc_pid_unstable_is_no_go etc_hosts true true true true true true true true true true true false unavailable
docker_etc_no_go docker_etc_pid_reuse_starttime_change_is_no_go etc_hostname true true true true true true true true true true true false unavailable
docker_etc_no_go docker_etc_namespace_change_is_no_go etc_resolv_conf true true true true true true true true true true true false unavailable
docker_etc_no_go docker_etc_source_outside_root_is_no_go etc_hosts true true true false true true true true true true true true unavailable
docker_etc_no_go docker_etc_source_symlink_is_no_go etc_hosts true true false true true true true true true true true true unavailable
docker_etc_no_go docker_etc_source_restat_changed_is_no_go etc_hosts true true true true false true true true true true true true unavailable
docker_etc_no_go docker_etc_target_symlink_is_no_go etc_hosts true true true true true true false true true true true true unavailable
docker_etc_no_go docker_etc_identity_mismatch_is_no_go etc_hosts true true true true true true true false true true true true unavailable
docker_etc_no_go docker_etc_identity_after_restat_mismatch_is_no_go etc_hosts true true true true false true true true false true true true unavailable
docker_etc_no_go docker_etc_mount_ro_is_no_go etc_hosts true true true true true true true true true false true true unavailable
docker_etc_no_go docker_etc_propagation_is_no_go etc_hosts true true true true true true true true true true true false unavailable
docker_etc_no_go docker_etc_runtime_report_unavailable_is_no_go etc_hosts true true true true true true true true true true true true unavailable
docker_etc_no_go docker_etc_runtime_report_inconsistent_is_no_go etc_hosts true true true true true true true true true true true true inconsistent
docker_etc_no_go docker_etc_proc_access_failure_is_no_go etc_hosts true true true true false false false false false false false false unavailable
set +e; validate_docker_managed_etc_record unknown_id true true true true true true true true true true true true unavailable >/dev/null; rc=$?; set -e
assert_rc 2 "$rc" docker_etc_unknown_id_is_parser_error

# A synthetic source/inode sentinel is never passed to public diagnostics: the
# effective validator accepts only booleans and known IDs.  Its absence proves
# fixture paths and identity numbers cannot leak through this log surface.
docker_etc_sentinel='/private/docker-root/987654/sensitive-source'
[[ "$docker_etc_diagnostic" != *"$docker_etc_sentinel"* && "$docker_etc_diagnostic" != *987654* ]] || {
  printf 'FAIL Docker-managed /etc sanitization regression\n' >&2
  exit 1
}
rg -Fq 'PAPERCLIP_PREFLIGHT_RUNTIME_READY' "$workflow"
rg -Fq 'kill "$diagnostic_start_pid"' "$workflow"
rg -Fq 'readiness timeout or start failure' "$workflow"
rg -Fq '/proc/$pid/mountinfo' "$workflow"
rg -Fq '/proc/$pid/root$destination' "$workflow"
if rg -n '(^|[[:space:]])nsenter[[:space:]]+-|sudo[[:space:]]+.*nsenter' "$workflow"; then
  printf 'FAIL Docker-managed /etc diagnostic unexpectedly uses nsenter\n' >&2
  exit 1
fi
printf 'PASS docker_managed_etc_runtime_diagnostic_is_fail_closed\n'

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

# The runtime allowlist must accept only the eight observed mask records when
# every mount-level predicate is satisfied.  Each negative fixture below calls
# the AWK extracted from the workflow, not a duplicate implementation.
set +e; mountinfo_verdict "$tmpdir/runtime-mask-valid" >/dev/null; rc=$?; set -e
assert_rc 0 "$rc" verified_runtime_masks_pass_closed_allowlist
mask_mountinfo_no_go() {
  local label="$1" fixture="$2"
  printf '%s\n' "$fixture" >"$tmpdir/mask-negative"
  set +e; mountinfo_verdict "$tmpdir/mask-negative" >/dev/null; rc=$?; set -e
  assert_rc 1 "$rc" "$label"
}
mask_mountinfo_no_go mask_directory_type_source_required $'36 25 0:32 / /proc/acpi ro - ext4 private rw\n37 25 0:33 / /proc/scsi ro - tmpfs tmpfs ro\n38 25 0:34 / /sys/firmware ro - tmpfs tmpfs ro\n39 25 0:35 /null /proc/interrupts rw - tmpfs tmpfs rw\n40 25 0:35 /null /proc/kcore rw - tmpfs tmpfs rw\n41 25 0:35 /null /proc/keys rw - tmpfs tmpfs rw\n42 25 0:35 /null /proc/latency_stats rw - tmpfs tmpfs rw\n43 25 0:35 /null /proc/timer_list rw - tmpfs tmpfs rw'
mask_mountinfo_no_go mask_directory_root_required $'36 25 0:32 /wrong /proc/acpi ro - tmpfs tmpfs ro\n37 25 0:33 / /proc/scsi ro - tmpfs tmpfs ro\n38 25 0:34 / /sys/firmware ro - tmpfs tmpfs ro\n39 25 0:35 /null /proc/interrupts rw - tmpfs tmpfs rw\n40 25 0:35 /null /proc/kcore rw - tmpfs tmpfs rw\n41 25 0:35 /null /proc/keys rw - tmpfs tmpfs rw\n42 25 0:35 /null /proc/latency_stats rw - tmpfs tmpfs rw\n43 25 0:35 /null /proc/timer_list rw - tmpfs tmpfs rw'
mask_mountinfo_no_go mask_directory_access_required $'36 25 0:32 / /proc/acpi rw - tmpfs tmpfs rw\n37 25 0:33 / /proc/scsi ro - tmpfs tmpfs ro\n38 25 0:34 / /sys/firmware ro - tmpfs tmpfs ro\n39 25 0:35 /null /proc/interrupts rw - tmpfs tmpfs rw\n40 25 0:35 /null /proc/kcore rw - tmpfs tmpfs rw\n41 25 0:35 /null /proc/keys rw - tmpfs tmpfs rw\n42 25 0:35 /null /proc/latency_stats rw - tmpfs tmpfs rw\n43 25 0:35 /null /proc/timer_list rw - tmpfs tmpfs rw'
mask_mountinfo_no_go mask_file_root_required $'36 25 0:32 / /proc/acpi ro - tmpfs tmpfs ro\n37 25 0:33 / /proc/scsi ro - tmpfs tmpfs ro\n38 25 0:34 / /sys/firmware ro - tmpfs tmpfs ro\n39 25 0:35 /wrong /proc/interrupts rw - tmpfs tmpfs rw\n40 25 0:35 /null /proc/kcore rw - tmpfs tmpfs rw\n41 25 0:35 /null /proc/keys rw - tmpfs tmpfs rw\n42 25 0:35 /null /proc/latency_stats rw - tmpfs tmpfs rw\n43 25 0:35 /null /proc/timer_list rw - tmpfs tmpfs rw'
mask_mountinfo_no_go mask_file_access_required $'36 25 0:32 / /proc/acpi ro - tmpfs tmpfs ro\n37 25 0:33 / /proc/scsi ro - tmpfs tmpfs ro\n38 25 0:34 / /sys/firmware ro - tmpfs tmpfs ro\n39 25 0:35 /null /proc/interrupts ro - tmpfs tmpfs ro\n40 25 0:35 /null /proc/kcore rw - tmpfs tmpfs rw\n41 25 0:35 /null /proc/keys rw - tmpfs tmpfs rw\n42 25 0:35 /null /proc/latency_stats rw - tmpfs tmpfs rw\n43 25 0:35 /null /proc/timer_list rw - tmpfs tmpfs rw'
mask_mountinfo_no_go mask_propagation_required $'36 25 0:32 / /proc/acpi ro shared:1 - tmpfs tmpfs ro\n37 25 0:33 / /proc/scsi ro - tmpfs tmpfs ro\n38 25 0:34 / /sys/firmware ro - tmpfs tmpfs ro\n39 25 0:35 /null /proc/interrupts rw - tmpfs tmpfs rw\n40 25 0:35 /null /proc/kcore rw - tmpfs tmpfs rw\n41 25 0:35 /null /proc/keys rw - tmpfs tmpfs rw\n42 25 0:35 /null /proc/latency_stats rw - tmpfs tmpfs rw\n43 25 0:35 /null /proc/timer_list rw - tmpfs tmpfs rw'
mask_mountinfo_no_go mask_submount_required $'36 25 0:32 / /proc/acpi ro - tmpfs tmpfs ro\n37 36 0:33 / /proc/acpi/child ro - tmpfs tmpfs ro\n38 25 0:33 / /proc/scsi ro - tmpfs tmpfs ro\n39 25 0:34 / /sys/firmware ro - tmpfs tmpfs ro\n40 25 0:35 /null /proc/interrupts rw - tmpfs tmpfs rw\n41 25 0:35 /null /proc/kcore rw - tmpfs tmpfs rw\n42 25 0:35 /null /proc/keys rw - tmpfs tmpfs rw\n43 25 0:35 /null /proc/latency_stats rw - tmpfs tmpfs rw\n44 25 0:35 /null /proc/timer_list rw - tmpfs tmpfs rw'
mask_mountinfo_no_go mask_cardinality_required $'36 25 0:32 / /proc/acpi ro - tmpfs tmpfs ro\n37 25 0:32 / /proc/acpi ro - tmpfs tmpfs ro\n38 25 0:33 / /proc/scsi ro - tmpfs tmpfs ro\n39 25 0:34 / /sys/firmware ro - tmpfs tmpfs ro\n40 25 0:35 /null /proc/interrupts rw - tmpfs tmpfs rw\n41 25 0:35 /null /proc/kcore rw - tmpfs tmpfs rw\n42 25 0:35 /null /proc/keys rw - tmpfs tmpfs rw\n43 25 0:35 /null /proc/latency_stats rw - tmpfs tmpfs rw\n44 25 0:35 /null /proc/timer_list rw - tmpfs tmpfs rw'
runtime_mask_missing=$'36 25 0:32 / /proc/acpi ro - tmpfs tmpfs ro\n37 25 0:33 / /proc/scsi ro - tmpfs tmpfs ro\n38 25 0:34 / /sys/firmware ro - tmpfs tmpfs ro\n39 25 0:35 /null /proc/interrupts rw - tmpfs tmpfs rw\n40 25 0:35 /null /proc/kcore rw - tmpfs tmpfs rw\n41 25 0:35 /null /proc/keys rw - tmpfs tmpfs rw\n42 25 0:35 /null /proc/latency_stats rw - tmpfs tmpfs rw'
printf '%s\n' "$runtime_mask_missing" >"$tmpdir/runtime-mask-missing"
set +e; runtime_mask_verdict "$tmpdir/runtime-mask-missing" >/dev/null; rc=$?; set -e
assert_rc 1 "$rc" mask_cardinality_missing_is_no_go
printf 'PASS runtime_mask_closed_exceptions_are_regression_tested\n'

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
