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

python3 - "$workflow" <<'PY'
import pathlib, sys, yaml
document = yaml.safe_load(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
assert isinstance(document, dict) and "jobs" in document
PY
test_pass yaml_valid

[[ "$(grep -Ec '^[[:space:]]*workflow_dispatch:' "$workflow")" == 1 ]] || test_fail dispatch_trigger
! grep -Eq '^[[:space:]]*(push|pull_request|schedule|workflow_call):' "$workflow" || test_fail automatic_trigger
grep -Fxq 'permissions: {}' "$workflow" || test_fail permissions
grep -Fxq '    runs-on: ubuntu-24.04' "$workflow" || test_fail runner
grep -Fq 'REPOSITORY_IS_PRIVATE="${{ github.event.repository.private }}"' "$workflow" || test_fail public_repository_gate
! grep -Eq '^[[:space:]]*uses:' "$workflow" || test_fail external_action
! grep -Eqi 'paperclipai|pnpm|npm |apt(-get)? |git clone|git fetch|docker[[:space:]]' "$workflow" || test_fail prohibited_acquisition_or_docker
test_pass workflow_surface

python3 - "$workflow" <<'PY'
import pathlib
import re
import sys

lines = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8").splitlines(keepends=True)
lengths = []
for index, line in enumerate(lines):
    match = re.match(r"^(\s*)run:\s*\|\s*$", line.rstrip("\n"))
    if not match:
        continue
    parent_indent = len(match.group(1))
    block = []
    for candidate in lines[index + 1:]:
        if candidate.strip() and len(candidate) - len(candidate.lstrip(" ")) <= parent_indent:
            break
        trim = min(len(candidate) - len(candidate.lstrip(" ")), parent_indent + 2)
        block.append(candidate[trim:])
    lengths.append(len("".join(block)))

if len(lengths) != 3 or any(length >= 21000 for length in lengths):
    raise SystemExit(1)
PY
test_pass run_expression_limits

for required in \
  "-p 'NoNewPrivileges=yes'" \
  "-p 'PrivateNetwork=yes'" \
  "-p 'ProtectSystem=strict'" \
  "-p 'ProtectHome=yes'" \
  "-p 'MemoryMax=256M'" \
  "-p 'CPUQuota=50%'" \
  "-p 'TasksMax=64'" \
  "-p 'CapabilityBoundingSet='" \
  "-p 'AmbientCapabilities='" \
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
EXPECTED_RECORDS=23
# shellcheck disable=SC1090
source "$tmp/parser.sh"

make_valid_log() {
  local output="$1" phase="$2" id
  : >"$output"
  local ids=(
    identity groups privilege_tools capabilities nonewprivs environment
    descriptors workdir_write outside_write_denied tmp_write_denied
    vartmp_write_denied devshm_write_denied workspace_hidden controller_hidden sockets_hidden
    network_interfaces routes dns_blocked tcp_blocked https_blocked
    cgroup_memory cgroup_pids cgroup_cpu
  )
  for id in "${ids[@]}"; do printf 'RESULT id=%s status=PASS code=ok\n' "$id" >>"$output"; done
  printf 'READY status=PASS records=23\n' >>"$output"
  [[ "$phase" == final ]] && printf 'FINAL status=PASS records=23\n' >>"$output"
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

cp "$valid_final" "$tmp/final-before-ready.log"
python3 - "$tmp/final-before-ready.log" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]); lines=p.read_text().splitlines()
lines[-2], lines[-1] = lines[-1], lines[-2]
p.write_text("\n".join(lines)+"\n")
PY
expect_reject "$tmp/final-before-ready.log" final final_before_ready

cp "$valid_ready" "$tmp/ready-early.log"
sed -i '1iREADY status=PASS records=23' "$tmp/ready-early.log"
expect_reject "$tmp/ready-early.log" ready ready_before_results

cp "$valid_ready" "$tmp/result-after-ready.log"
sed -n '1p' "$valid_ready" >>"$tmp/result-after-ready.log"
expect_reject "$tmp/result-after-ready.log" ready result_after_ready

cp "$valid_final" "$tmp/after-final.log"
printf '%s\n' 'READY status=PASS records=23' >>"$tmp/after-final.log"
expect_reject "$tmp/after-final.log" final record_after_final
test_pass parser_marker_order

# Exercise the closed FD validator extracted from the actual embedded probe.
extract_marker_block FD_VALIDATOR_BEGIN FD_VALIDATOR_END "$tmp/probe.sh" "$tmp/fd-validator.sh"
source "$tmp/fd-validator.sh"
mkdir "$tmp/fds"
: >"$tmp/probe-fixture"; : >"$tmp/fd-output"
ln -s /dev/null "$tmp/fds/0"
ln -s "$tmp/fd-output" "$tmp/fds/1"
ln -s "$tmp/fd-output" "$tmp/fds/2"
ln -s "$tmp/probe-fixture" "$tmp/fds/255"
validate_descriptor_snapshot "$tmp/fds" "$tmp/probe-fixture" || test_fail fd_clean_rejected
ln -s /etc/passwd "$tmp/fds/9"
if validate_descriptor_snapshot "$tmp/fds" "$tmp/probe-fixture"; then test_fail fd_extra_accepted; fi
rm "$tmp/fds/9"
set +e
validate_descriptor_snapshot /missing "$tmp/probe-fixture"
fd_missing_rc=$?
set -e
[[ "$fd_missing_rc" == 2 ]] || test_fail fd_inspection_not_inconclusive
test_pass descriptor_closed_allowlist

# Pure classifiers are the same functions used by the runtime checks.
extract_marker_block NETWORK_CLASSIFIERS_BEGIN NETWORK_CLASSIFIERS_END "$tmp/probe.sh" "$tmp/network.sh"
source "$tmp/network.sh"
classify_dns_result 2 || test_fail dns_blocked_rejected
set +e; classify_dns_result 0; rc=$?; set -e; [[ "$rc" == 1 ]] || test_fail dns_connected_not_rejected
set +e; classify_dns_result 124; rc=$?; set -e; [[ "$rc" == 2 ]] || test_fail dns_timeout_not_inconclusive
printf '%s\n' 'bash: connect: Network is unreachable' >"$tmp/tcp.err"
classify_tcp_result 1 "$tmp/tcp.err" || test_fail tcp_blocked_rejected
: >"$tmp/tcp.err"
set +e; classify_tcp_result 1 "$tmp/tcp.err"; rc=$?; set -e; [[ "$rc" == 2 ]] || test_fail tcp_tool_error_not_inconclusive
set +e; classify_tcp_result 0 "$tmp/tcp.err"; rc=$?; set -e; [[ "$rc" == 1 ]] || test_fail tcp_connected_not_rejected
classify_https_result 7 true true || test_fail https_blocked_rejected
set +e; classify_https_result 7 false true; rc=$?; set -e; [[ "$rc" == 2 ]] || test_fail https_ambiguous_not_inconclusive
set +e; classify_https_result 35 true true; rc=$?; set -e; [[ "$rc" == 1 ]] || test_fail tls_reachability_not_rejected
set +e; classify_https_result 28 true true; rc=$?; set -e; [[ "$rc" == 2 ]] || test_fail https_timeout_not_inconclusive
test_pass network_result_classification

extract_marker_block SOCKET_SCAN_VALIDATOR_BEGIN SOCKET_SCAN_VALIDATOR_END "$tmp/probe.sh" "$tmp/socket-validator.sh"
source "$tmp/socket-validator.sh"
validate_socket_scan 0 '' || test_fail empty_socket_scan_rejected
set +e; validate_socket_scan 0 synthetic_socket; rc=$?; set -e; [[ "$rc" == 1 ]] || test_fail socket_not_rejected
set +e; validate_socket_scan 1 ''; rc=$?; set -e; [[ "$rc" == 2 ]] || test_fail socket_scan_error_not_inconclusive
test_pass socket_scan_fail_closed

# Simulate ownership flags against the exact cleanup function from the controller.
extract_marker_block OWNED_CLEANUP_BEGIN OWNED_CLEANUP_END "$tmp/controller.sh" "$tmp/cleanup.sh"
source "$tmp/cleanup.sh"
declare -a cleanup_calls=()
stop_owned_unit() { cleanup_calls+=("unit:$1"); [[ "${STOP_FAIL:-false}" != true ]]; }
userdel() { cleanup_calls+=("user:$1"); return 0; }
groupdel() { cleanup_calls+=("group:$1"); return 0; }
getent() { return 1; }
rm() { cleanup_calls+=("path:${*: -1}"); return 0; }
MAIN_UNIT=main.service TIMEOUT_UNIT=timeout.service LAB_USER=lab LAB_GROUP=lab
HOST_SENTINEL=/home/runner/work/.ti0093-vm-preflight-sentinel
PRIVATE_ROOT=/run/ti0093-vm-preflight LAB_ROOT=/var/lib/ti0093-vm-preflight
main_owned=false timeout_owned=false user_owned=false sentinel_owned=false private_root_created=false lab_root_created=false
cleanup_owned_resources || test_fail empty_cleanup_failed
(( ${#cleanup_calls[@]} == 0 )) || test_fail preexisting_resources_touched
main_owned=true private_root_created=true user_owned=true
cleanup_owned_resources || test_fail partial_owned_cleanup_failed
[[ " ${cleanup_calls[*]} " == *' unit:main.service '* && " ${cleanup_calls[*]} " == *' user:lab '* && " ${cleanup_calls[*]} " == *' path:/run/ti0093-vm-preflight '* ]] || test_fail partial_cleanup_missing
[[ " ${cleanup_calls[*]} " != *'timeout.service'* && " ${cleanup_calls[*]} " != *'/var/lib/ti0093-vm-preflight'* ]] || test_fail unowned_resource_touched
cleanup_calls=(); main_owned=true lab_root_created=true STOP_FAIL=true
set +e; cleanup_owned_resources; rc=$?; set -e
[[ "$rc" == 1 && " ${cleanup_calls[*]} " == *' unit:main.service '* && " ${cleanup_calls[*]} " == *' path:/var/lib/ti0093-vm-preflight '* ]] || test_fail cleanup_failure_not_preserved
unset STOP_FAIL
unset -f stop_owned_unit userdel groupdel getent rm
test_pass owned_cleanup_collision_and_partial_failure

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

grep -Fq "sentinel_owned=true" "$tmp/controller.sh" || test_fail readable_workspace_sentinel
grep -Fq 'mkdir -m 0700 -- "$LAB_WORK" "$LAB_OUTSIDE"' "$tmp/controller.sh" || test_fail uid_owned_outside_fixture
grep -Fq "ReadWritePaths=\$LAB_WORK" "$tmp/controller.sh" || test_fail closed_write_allowlist
grep -Fq "ReadOnlyPaths=/tmp /var/tmp /dev/shm" "$tmp/controller.sh" || test_fail temporary_paths_readonly
grep -Fq "TemporaryFileSystem=/run:ro,nosuid,nodev,noexec,size=1M" "$tmp/controller.sh" || test_fail run_private_readonly
grep -Fq '/dev/shm/ti0093-denied' "$tmp/probe.sh" || test_fail devshm_write_probe
grep -Fq 'find -L "$root" -xdev -type s' "$tmp/probe.sh" || test_fail filesystem_socket_scan
test_pass filesystem_fixture_design

# Collision checks must precede creators, and every destructive cleanup path is ownership-gated.
line_of() { grep -nF -- "$1" "$2" | head -1 | cut -d: -f1; }
(( $(line_of "lab_root_preexisting" "$tmp/controller.sh") < $(line_of 'mkdir -m 0755 -- "$LAB_ROOT"' "$tmp/controller.sh") )) || test_fail lab_collision_order
(( $(line_of "host_sentinel_preexisting" "$tmp/controller.sh") < $(line_of 'sentinel_owned=true' "$tmp/controller.sh") )) || test_fail sentinel_collision_order
(( $(line_of "main_unit_name_collision" "$tmp/controller.sh") < $(line_of 'systemd-run --system --quiet --unit="$MAIN_UNIT"' "$tmp/controller.sh") )) || test_fail unit_collision_order
grep -Fq '[[ ! -e "$controller_installed" && ! -L "$controller_installed" ]] || exit 86' "$workflow" || test_fail controller_binary_collision
grep -Fq '[[ ! -e "$probe_installed" && ! -L "$probe_installed" ]] || exit 86' "$workflow" || test_fail probe_binary_collision
grep -Fq 'RUN_OWNER_TAG="ti0093-${GITHUB_RUN_ID:-invalid}-${GITHUB_RUN_ATTEMPT:-invalid}-${GITHUB_SHA:-invalid}"' "$workflow" || test_fail unit_owner_tag
test_pass collision_gates

grep -Fq "REPOSITORY_IS_PRIVATE:-}" "$tmp/controller.sh" || test_fail repository_visibility_consumed
grep -Fq "WORKFLOW_SHA:-}" "$tmp/controller.sh" || test_fail immutable_sha_gate
grep -Fq "write_summary 'NO-GO'" "$tmp/controller.sh" || test_fail fail_closed_summary
grep -Fq 'exit 86' "$tmp/controller.sh" || test_fail fail_closed_exit
test_pass fail_closed_decision

printf 'RESULT offline_static_tests=%s status=PASS\n' "$pass_count"
