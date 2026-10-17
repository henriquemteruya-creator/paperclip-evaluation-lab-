#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
workflow="$repo_root/.github/workflows/vm-systemd-preflight.yml"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT

pass_count=0
test_fail() { printf 'FAIL %s\n' "$1" >&2; exit 1; }
test_pass() { (( ++pass_count )); printf 'PASS %s\n' "$1"; }

extract_heredoc() {
  local delimiter="$1" output="$2"
  awk -v delimiter="$delimiter" '
    $0 ~ "<<\\047" delimiter "\\047$" {inside=1; next}
    inside && $0 ~ "^[[:space:]]*" delimiter "$" {exit}
    inside {sub(/^          /, ""); print}
    END {if (!inside) exit 2}
  ' "$workflow" >"$output"
}

extract_marker_block() {
  local begin="$1" end="$2" input="$3" output="$4"
  awk -v begin="$begin" -v end="$end" '
    index($0, begin) {inside=1; next}
    index($0, end) {inside=0; found_end=1; exit}
    inside {print}
    END {if (!found_end) exit 2}
  ' "$input" >"$output"
}

[[ -s "$workflow" ]] || test_fail workflow_missing
extract_heredoc CONTROLLER "$tmp/controller.sh"
extract_heredoc PROBE "$tmp/probe.sh"
bash -n "$tmp/controller.sh"
bash -n "$tmp/probe.sh"
test_pass embedded_scripts_parse

[[ "$(grep -Ec '^[[:space:]]*workflow_dispatch:' "$workflow")" == 1 ]] || test_fail dispatch_trigger
! grep -Eq '^[[:space:]]*(push|pull_request|schedule|workflow_call):' "$workflow" || test_fail automatic_trigger
grep -Fxq 'permissions: {}' "$workflow" || test_fail permissions
grep -Fxq '    runs-on: ubuntu-24.04' "$workflow" || test_fail runner
grep -Fq 'REPOSITORY_IS_PRIVATE="${{ github.event.repository.private }}"' "$workflow" || test_fail public_repository_gate
! grep -Eq '^[[:space:]]*uses:' "$workflow" || test_fail external_action
! grep -Eqi 'paperclipai|pnpm|npm |apt(-get)? |git clone|git fetch|docker[[:space:]]' "$workflow" || test_fail prohibited_acquisition_or_docker
test_pass workflow_surface

for required in \
  "--property='NoNewPrivileges=yes'" \
  "--property='PrivateNetwork=yes'" \
  "--property='ProtectSystem=strict'" \
  "--property='ProtectHome=yes'" \
  "--property='MemoryMax=256M'" \
  "--property='CPUQuota=50%'" \
  "--property='TasksMax=64'" \
  "--property='CapabilityBoundingSet='" \
  "--property='AmbientCapabilities='" \
  "systemd-run --system"; do
  grep -Fq -- "$required" "$tmp/controller.sh" || test_fail "missing_control_${required//[^a-zA-Z0-9]/_}"
done
test_pass required_systemd_controls

grep -Fq "InaccessiblePaths=-\$PRIVATE_ROOT" "$tmp/controller.sh" || test_fail socket_mask_root
for path in /run/docker.sock /run/systemd/private /run/dbus/system_bus_socket /run/containerd/containerd.sock; do
  grep -Fq -- "$path" "$tmp/controller.sh" || test_fail "socket_mask_${path//\//_}"
  grep -Fq -- "$path" "$tmp/probe.sh" || test_fail "socket_probe_${path//\//_}"
done
test_pass socket_policy

# Source the real parser function without installing the controller's EXIT trap.
extract_marker_block PROBE_LOG_PARSER_BEGIN PROBE_LOG_PARSER_END "$tmp/controller.sh" "$tmp/parser.sh"
MAX_LOG_BYTES=16384
EXPECTED_RECORDS=22
# shellcheck disable=SC1090
source "$tmp/parser.sh"

make_valid_log() {
  local output="$1" phase="$2" id
  : >"$output"
  local ids=(
    identity groups privilege_tools capabilities nonewprivs environment
    descriptors workdir_write outside_write_denied tmp_write_denied
    vartmp_write_denied workspace_hidden controller_hidden sockets_hidden
    network_interfaces routes dns_blocked tcp_blocked https_blocked
    cgroup_memory cgroup_pids cgroup_cpu
  )
  for id in "${ids[@]}"; do printf 'RESULT id=%s status=PASS code=ok\n' "$id" >>"$output"; done
  printf 'READY status=PASS records=22\n' >>"$output"
  [[ "$phase" == final ]] && printf 'FINAL status=PASS records=22\n' >>"$output"
  chmod 0600 "$output"
}

valid_ready="$tmp/valid-ready.log"
valid_final="$tmp/valid-final.log"
make_valid_log "$valid_ready" ready
make_valid_log "$valid_final" final
parse_probe_log "$valid_ready" ready || test_fail parser_valid_ready
parse_probe_log "$valid_final" final || test_fail parser_valid_final
test_pass parser_positive

expect_reject() {
  local file="$1" phase="$2" label="$3"
  if parse_probe_log "$file" "$phase" >/dev/null 2>&1; then test_fail "parser_accepted_$label"; fi
  test_pass "parser_rejects_$label"
}

cp "$valid_ready" "$tmp/duplicate.log"
sed -n '1p' "$valid_ready" >>"$tmp/duplicate.log"
expect_reject "$tmp/duplicate.log" ready duplicate

cp "$valid_ready" "$tmp/unknown.log"
sed -i '1cRESULT id=private_path_secret status=PASS code=ok' "$tmp/unknown.log"
expect_reject "$tmp/unknown.log" ready unknown_id

cp "$valid_ready" "$tmp/failure.log"
sed -i '1cRESULT id=identity status=FAIL code=mismatch' "$tmp/failure.log"
expect_reject "$tmp/failure.log" ready failed_control

cp "$valid_ready" "$tmp/malformed.log"
printf '%s\n' 'untrusted=/home/runner/work/private ::set-output:: token=secret-value' >>"$tmp/malformed.log"
expect_reject "$tmp/malformed.log" ready malformed_sensitive_line

cp "$valid_ready" "$tmp/control.log"
printf '\001' >>"$tmp/control.log"
expect_reject "$tmp/control.log" ready control_character

python3 - "$tmp/oversized.log" <<'PY'
import pathlib, sys
pathlib.Path(sys.argv[1]).write_text("X" * 17000 + "\n", encoding="utf-8")
PY
expect_reject "$tmp/oversized.log" ready oversized

cp "$valid_ready" "$tmp/truncated.log"
truncate -s -1 "$tmp/truncated.log"
expect_reject "$tmp/truncated.log" ready missing_final_newline

# Parser functions return only status; the controller never emits private log content.
secret='SENSITIVE_PATH_/home/runner/work/private_TOKEN_abc123'
cp "$valid_ready" "$tmp/sanitization.log"
printf '%s\n' "$secret" >>"$tmp/sanitization.log"
captured="$(parse_probe_log "$tmp/sanitization.log" ready 2>&1 || true)"
[[ "$captured" != *"$secret"* && "$captured" != *'/home/runner'* && "$captured" != *'abc123'* ]] || test_fail parser_leak
test_pass parser_sanitization

grep -Fq "StandardOutput=append:\$log_file" "$tmp/controller.sh" || test_fail private_output
grep -Fq "StandardError=append:\$log_file" "$tmp/controller.sh" || test_fail private_error
! grep -Fq 'systemd-run --pipe' "$tmp/controller.sh" || test_fail pipe_streaming
! grep -Eq '(cat|tee)[[:space:]].*\$(main_log|timeout_log)' "$tmp/controller.sh" || test_fail raw_log_streaming
! grep -Fq 'journalctl' "$tmp/controller.sh" || test_fail journal_streaming
grep -Fq "stat -Lc '%u:%g:%a:%F'" "$tmp/controller.sh" || test_fail private_log_metadata
test_pass private_log_channel

grep -Fq "RuntimeMaxSec=\$runtime" "$tmp/controller.sh" || test_fail runtime_limit
grep -Fq "Result timeout" "$tmp/controller.sh" || test_fail timeout_result
grep -Fq 'verify_unit_cgroup_empty "$TIMEOUT_UNIT"' "$tmp/controller.sh" || test_fail timeout_cleanup
grep -Fq "pgrep -u \"\$lab_uid\"" "$tmp/controller.sh" || test_fail process_cleanup
test_pass timeout_and_cleanup_logic

grep -Fq 'READY status=PASS records=%s' "$tmp/probe.sh" || test_fail ready_marker
grep -Fq 'FINAL status=PASS records=%s' "$tmp/probe.sh" || test_fail final_marker
grep -Fq 'example.com' "$tmp/probe.sh" || test_fail dns_https_probe
grep -Fq '/dev/tcp/1.1.1.1/443' "$tmp/probe.sh" || test_fail direct_tcp_probe
grep -Fq '/proc/self/status' "$tmp/probe.sh" || test_fail runtime_status_probe
grep -Fq '/proc/self/cgroup' "$tmp/probe.sh" || test_fail runtime_cgroup_probe
test_pass effective_runtime_probes

grep -Fq "install -o root -g root -m 0444 /dev/null \"\$HOST_SENTINEL\"" "$tmp/controller.sh" || test_fail readable_workspace_sentinel
grep -Fq "install -d -o \"\$LAB_USER\" -g \"\$LAB_GROUP\" -m 0700 \"\$LAB_WORK\" \"\$LAB_OUTSIDE\"" "$tmp/controller.sh" || test_fail uid_owned_outside_fixture
grep -Fq "ReadWritePaths=\$LAB_WORK" "$tmp/controller.sh" || test_fail closed_write_allowlist
grep -Fq "ReadOnlyPaths=/tmp /var/tmp" "$tmp/controller.sh" || test_fail private_tmp_readonly
test_pass filesystem_fixture_design

grep -Fq "REPOSITORY_IS_PRIVATE:-}" "$tmp/controller.sh" || test_fail repository_visibility_consumed
grep -Fq "WORKFLOW_SHA:-}" "$tmp/controller.sh" || test_fail immutable_sha_gate
grep -Fq "write_summary 'NO-GO'" "$tmp/controller.sh" || test_fail fail_closed_summary
grep -Fq 'exit 86' "$tmp/controller.sh" || test_fail fail_closed_exit
test_pass fail_closed_decision

printf 'RESULT offline_static_tests=%s status=PASS\n' "$pass_count"
