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
extract_heredoc CONTROLLER_A "$tmp/controller-a.sh"
extract_heredoc CONTROLLER_B "$tmp/controller-b.sh"
cat "$tmp/controller-a.sh" "$tmp/controller-b.sh" >"$tmp/controller.sh"
extract_heredoc PROBE "$tmp/probe.sh"
bash -n "$tmp/controller.sh"
bash -n "$tmp/probe.sh"
test_pass embedded_scripts_parse

# Exercise the transactional installation and partial-cleanup helpers extracted
# directly from the workflow. The mock installer provides deterministic failure
# modes without writing below /usr/local or requiring root.
extract_marker_block INSTALL_HELPER_BEGIN INSTALL_HELPER_END "$workflow" "$tmp/install-helper.sh"
extract_marker_block PARTIAL_INSTALL_CLEANUP_BEGIN PARTIAL_INSTALL_CLEANUP_END "$workflow" "$tmp/install-cleanup.sh"
source "$tmp/install-helper.sh"
source "$tmp/install-cleanup.sh"
sudo() { "$@"; }
mktemp() {
  [[ "${TEST_MKTEMP_MODE:-success}" != fail ]] || return 73
  command mktemp "$@"
}
install() {
  local source_path="${@: -2:1}" target_path="${@: -1}"
  case "${TEST_INSTALL_MODE:-success}" in
    before_create_fail) return 74 ;;
    partial_create_fail)
      printf '%s\n' partial >"$target_path"
      chmod 0555 -- "$target_path"
      return 75
      ;;
    success)
      cp -- "$source_path" "$target_path"
      chmod 0555 -- "$target_path"
      ;;
    *) return 76 ;;
  esac
}
install_root="$tmp/install-root"
source_file="$tmp/reviewed-probe.sh"
printf '%s\n' '#!/usr/bin/env bash' >"$source_file"
chmod 0500 "$source_file"
# The production helper must require root:root.  This test intentionally
# models only the metadata returned by privileged operations for paths inside
# its disposable fixture, so it can exercise the real helper under a normal
# non-root CI user without weakening the production predicate.
stat() {
  local format='' arg last=''
  for arg in "$@"; do
    [[ "$arg" == -c || "$arg" == -Lc ]] && continue
    if [[ -z "$format" && "$arg" == *%* ]]; then format="$arg"; fi
    last="$arg"
  done
  if [[ "$last" == "$install_root"/* ]]; then
    case "$format" in
      '%u:%g:%a:%F') printf '0:0:%s:%s\n' "$(command stat -Lc '%a' -- "$last")" "$(command stat -Lc '%F' -- "$last")"; return 0 ;;
      '%d:%i:%u:%g:%a:%F') printf '%s:0:0:%s:%s\n' "$(command stat -Lc '%d:%i' -- "$last")" "$(command stat -Lc '%a' -- "$last")" "$(command stat -Lc '%F' -- "$last")"; return 0 ;;
    esac
  fi
  command stat "$@"
}
controller_installed_by_run=false
probe_installed_by_run=false
controller_installed_identity=''
probe_installed_identity=''
install_temp_path=''
install_temp_identity=''
install_temp_owned=false

# This is the #4 failure mode: a missing parent is rejected without creating it.
missing_target="$install_root/usr/local/libexec/ti0093-vm-preflight-probe"
set +e; install_root_owned_script "$source_file" "$missing_target" probe_installed_by_run probe_installed_identity; rc=$?; set -e
[[ "$rc" == 2 && ! -e "$missing_target" && ! -e "$install_root/usr/local/libexec" ]] || test_fail install_missing_parent_fail_closed

install_dir="$install_root/usr/local/sbin"
mkdir -p -- "$install_dir"
chmod 0755 -- "$install_dir"
controller_target="$install_dir/ti0093-vm-preflight-controller"
probe_target="$install_dir/ti0093-vm-preflight-probe"
controller_installed="$controller_target"
probe_installed="$probe_target"
install_root_owned_script "$source_file" "$controller_target" controller_installed_by_run controller_installed_identity || test_fail install_controller_existing_dir
install_root_owned_script "$source_file" "$probe_target" probe_installed_by_run probe_installed_identity || test_fail install_probe_existing_dir
[[ -f "$probe_target" && ! -L "$probe_target" && "$(stat -Lc '%a' "$probe_target")" == 555 ]] || test_fail install_probe_mode
[[ "$controller_installed_by_run" == true && "$probe_installed_by_run" == true ]] || test_fail install_publication_ownership

# The installation directory itself is a trusted boundary; writable metadata
# is rejected before any temporary file is reserved.
chmod 0777 -- "$install_dir"
set +e; install_root_owned_script "$source_file" "$controller_target" controller_installed_by_run controller_installed_identity; rc=$?; set -e
chmod 0755 -- "$install_dir"
[[ "$rc" == 2 ]] || test_fail install_directory_metadata_gate

# A preexisting file or symlink is never overwritten.
set +e; install_root_owned_script "$source_file" "$controller_target" controller_installed_by_run controller_installed_identity; rc=$?; set -e
[[ "$rc" == 1 && -f "$controller_target" ]] || test_fail install_collision_preserved
rm -f -- "$probe_target"
symlink_target="$tmp/install-symlink-target"
printf '%s\n' target >"$symlink_target"
ln -s "$symlink_target" "$probe_target"
set +e; install_root_owned_script "$source_file" "$probe_target" probe_installed_by_run probe_installed_identity; rc=$?; set -e
[[ "$rc" == 1 && -L "$probe_target" && "$(<"$symlink_target")" == target ]] || test_fail install_symlink_preserved
rm -f -- "$probe_target"

# Failure before a reservation exists leaves no cleanup authority or target.
TEST_MKTEMP_MODE=fail
set +e; install_root_owned_script "$source_file" "$probe_target" probe_installed_by_run probe_installed_identity; rc=$?; set -e
unset TEST_MKTEMP_MODE
[[ "$rc" == 2 && "$install_temp_owned" == false && ! -e "$probe_target" ]] || test_fail install_precreation_failure

# A failing installer may leave bytes in its private temporary path. The EXIT
# cleanup removes that proven path but does not create a final target.
TEST_INSTALL_MODE=partial_create_fail
set +e; install_root_owned_script "$source_file" "$probe_target" probe_installed_by_run probe_installed_identity; rc=$?; set -e
unset TEST_INSTALL_MODE
[[ "$rc" == 1 && "$install_temp_owned" == true && ! -e "$probe_target" ]] || test_fail install_partial_failure_state
partial_temp="$install_temp_path"
set +e
( trap cleanup_partial_install EXIT; false )
rc=$?
set -e
[[ "$rc" == 1 && ! -e "$partial_temp" && ! -e "$probe_target" ]] || test_fail install_partial_failure_cleanup

# Interruption after the first publication removes that owned final file and
# the second private temporary file.
rm -f -- "$controller_target"
controller_installed_by_run=false
probe_installed_by_run=false
controller_installed_identity=''
probe_installed_identity=''
install_root_owned_script "$source_file" "$controller_target" controller_installed_by_run controller_installed_identity || test_fail install_first_file_for_interrupt
TEST_INSTALL_MODE=partial_create_fail
set +e; install_root_owned_script "$source_file" "$probe_target" probe_installed_by_run probe_installed_identity; rc=$?; set -e
unset TEST_INSTALL_MODE
[[ "$rc" == 1 && "$controller_installed_by_run" == true && "$install_temp_owned" == true ]] || test_fail install_interrupt_state
interrupt_temp="$install_temp_path"
set +e
( trap cleanup_partial_install EXIT; false )
rc=$?
set -e
[[ "$rc" == 1 && ! -e "$controller_target" && ! -e "$probe_target" && ! -e "$interrupt_temp" ]] || test_fail install_interrupt_cleanup

# Cleanup refuses an identity it cannot prove, rather than deleting it.
controller_installed_by_run=false
probe_installed_by_run=false
install_temp_owned=true
install_temp_path="$install_dir/.ti0093-vm-preflight-ti0093-vm-preflight-probe.unproven"
printf '%s\n' unproven >"$install_temp_path"
install_temp_identity='0:0'
set +e
( trap cleanup_partial_install EXIT; false )
rc=$?
set -e
[[ "$rc" == 86 && -f "$install_temp_path" ]] || test_fail install_unproven_cleanup_preserved
rm -f -- "$install_temp_path"

unset -f sudo mktemp install stat install_root_owned_script installation_dir_is_trusted installation_temp_is_owned remove_execution_owned_install cleanup_partial_install
test_pass reviewed_transactional_script_installation_and_partial_cleanup

# Exercise the actual step-4 manifest reader and cleanup verifier.  The
# manifest transports only identity and digest values; the paths remain fixed
# in the trusted workflow, and no raw values are logged.
extract_marker_block INSTALL_MANIFEST_READER_BEGIN INSTALL_MANIFEST_READER_END "$workflow" "$tmp/manifest-reader.sh"
source "$tmp/manifest-reader.sh"
continuity_root="$tmp/continuity"
stage="$continuity_root/stage"
mkdir -p -- "$stage"
chmod 0700 -- "$stage"
owner_marker="$stage/.owner"
manifest="$stage/.installed-manifest"
expected_owner='run:attempt:sha'
printf '%s\n' "$expected_owner" >"$owner_marker"
chmod 0400 -- "$owner_marker"
controller_installed="$continuity_root/controller"
probe_installed="$continuity_root/probe"
printf '%s\n' controller >"$controller_installed"
printf '%s\n' probe >"$probe_installed"
chmod 0555 -- "$controller_installed" "$probe_installed"
controller_identity="$(stat -Lc '%d:%i' -- "$controller_installed")"
probe_identity="$(stat -Lc '%d:%i' -- "$probe_installed")"
controller_hash="$(sha256sum -- "$controller_installed" | awk '{print $1}')"
probe_hash="$(sha256sum -- "$probe_installed" | awk '{print $1}')"
{
  printf 'owner\t%s\n' "$expected_owner"
  printf 'controller\t%s\t%s\n' "$controller_identity" "$controller_hash"
  printf 'probe\t%s\t%s\n' "$probe_identity" "$probe_hash"
} >"$manifest"
chmod 0400 -- "$manifest"
verify_stage_manifest || test_fail continuity_manifest_valid_rejected
stage_owned=true
read_install_manifest || test_fail continuity_manifest_parse_valid_rejected
verify_installed_artifact "$controller_installed" "$controller_identity" "$controller_hash" || test_fail continuity_controller_valid_rejected
verify_installed_artifact "$probe_installed" "$probe_identity" "$probe_hash" || test_fail continuity_probe_valid_rejected

# A symlink, missing file, device/inode drift or changed content cannot pass
# the before-execution gate.  The cleanup helper consequently preserves each
# unproven resource.
probe_saved="$probe_installed"
rm -f -- "$probe_installed"
ln -s "$controller_installed" "$probe_installed"
set +e; verify_installed_artifact "$probe_installed" "$probe_identity" "$probe_hash"; rc=$?; set -e
[[ "$rc" == 1 && -L "$probe_installed" ]] || test_fail continuity_symlink_not_rejected
rm -f -- "$probe_installed"
set +e; verify_installed_artifact "$probe_installed" "$probe_identity" "$probe_hash"; rc=$?; set -e
[[ "$rc" == 1 ]] || test_fail continuity_missing_not_rejected
replacement_probe="$continuity_root/replacement-probe"
printf '%s\n' probe >"$replacement_probe"
chmod 0555 -- "$replacement_probe"
mv -- "$replacement_probe" "$probe_installed"
drifted_probe_identity='999999:999999'
set +e; verify_installed_artifact "$probe_installed" "$drifted_probe_identity" "$probe_hash"; rc=$?; set -e
[[ "$rc" == 1 ]] || test_fail continuity_identity_drift_not_rejected
replacement_controller="$continuity_root/replacement-controller"
printf '%s\n' altered >"$replacement_controller"
chmod 0555 -- "$replacement_controller"
mv -- "$replacement_controller" "$controller_installed"
set +e; verify_installed_artifact "$controller_installed" "$controller_identity" "$controller_hash"; rc=$?; set -e
[[ "$rc" == 1 ]] || test_fail continuity_hash_drift_not_rejected
set +e; remove_verified_artifact "$controller_installed" "$controller_identity" "$controller_hash"; rc=$?; set -e
[[ "$rc" == 1 && -f "$controller_installed" ]] || test_fail continuity_cleanup_removed_unproven

# A malformed or extended manifest is rejected before any executable is run.
replacement_manifest="$continuity_root/replacement-manifest"
cat -- "$manifest" >"$replacement_manifest"
printf 'extra\tentry\n' >>"$replacement_manifest"
chmod 0400 -- "$replacement_manifest"
mv -- "$replacement_manifest" "$manifest"
set +e; read_install_manifest; rc=$?; set -e
[[ "$rc" == 1 ]] || test_fail continuity_manifest_extra_record_not_rejected
unset -f verify_stage_manifest read_install_manifest verify_installed_artifact remove_verified_artifact remove_verified_stage
test_pass continuity_manifest_and_verified_cleanup

# Exercise the two workflow staging blocks as the owning, non-root user when a
# normal test user is available.  This deliberately uses the extracted
# controller fragments rather than a duplicate fixture: the append is
# meaningful only if the exact heredoc boundary remains executable after the
# mode transition.
grep -Fq 'chmod 0600 "$controller_stage"' "$workflow" || test_fail staging_append_window_missing
grep -Fq 'bash -n "$controller_stage"' "$workflow" || test_fail staging_final_parse_missing
grep -Fq 'chmod 0500 "$controller_stage"' "$workflow" || test_fail staging_final_close_missing
chmod 0444 "$tmp/controller-a.sh" "$tmp/controller-b.sh"
chmod 0755 "$tmp"
cat >"$tmp/staging-integration.sh" <<'STAGING_INTEGRATION'
#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

parent="$1"
part_a="$2"
part_b="$3"
owner="$(id -u):$(id -g)"
expected_marker='run:attempt:sha'

assert_mode() {
  local path="$1" mode="$2"
  [[ "$(stat -Lc '%u:%g:%a' "$path")" == "$owner:$mode" ]]
}

cleanup_owned_stage() {
  local stage="$1"
  [[ "$stage" == "$parent"/stage-* && -d "$stage" && ! -L "$stage" ]] || return 1
  rm -rf -- "$stage"
  [[ ! -e "$stage" && ! -L "$stage" ]]
}

validate_stage() {
  local stage="$1" controller marker
  controller="$stage/controller.sh"
  marker="$stage/.owner"
  [[ -d "$stage" && ! -L "$stage" && -f "$controller" && ! -L "$controller" && -f "$marker" && ! -L "$marker" ]] || return 1
  assert_mode "$stage" 700 && assert_mode "$controller" 400 && assert_mode "$marker" 400 || return 1
  [[ "$(<"$marker")" == "$expected_marker" ]]
}

make_valid_stage() {
  local stage="$1" controller marker
  controller="$stage/controller.sh"
  marker="$stage/.owner"
  [[ ! -e "$stage" && ! -L "$stage" ]] || return 1
  mkdir -m 0700 -- "$stage"
  cat "$part_a" >"$controller"
  printf '%s\n' "$expected_marker" >"$marker"
  chmod 0400 "$controller" "$marker"
}

# Successful two-step transaction: closed -> validated -> append window ->
# parsed -> closed.  A post-close append must be denied to this non-root owner.
success="$parent/stage-success"
make_valid_stage "$success"
validate_stage "$success"
chmod 0600 "$success/controller.sh"
assert_mode "$success/controller.sh" 600
cat "$part_b" >>"$success/controller.sh"
bash -n "$success/controller.sh"
chmod 0500 "$success/controller.sh"
assert_mode "$success/controller.sh" 500
if ( printf '\n' >>"$success/controller.sh" ) >/dev/null 2>&1; then exit 10; fi
cleanup_owned_stage "$success"

# An incorrect initial mode is rejected before the controlled append, then an
# execution-owned stage is removed safely.
wrong_mode="$parent/stage-wrong-mode"
make_valid_stage "$wrong_mode"
chmod 0600 "$wrong_mode/controller.sh"
if validate_stage "$wrong_mode"; then exit 11; fi
cleanup_owned_stage "$wrong_mode"

# A preexisting controller is a collision: it is neither overwritten nor
# removed by this execution because ownership was never established.
collision="$parent/stage-preexisting"
mkdir -m 0700 -- "$collision"
printf '%s\n' preexisting >"$collision/controller.sh"
chmod 0600 "$collision/controller.sh"
if make_valid_stage "$collision"; then exit 12; fi
[[ -f "$collision/controller.sh" && "$(<"$collision/controller.sh")" == preexisting ]] || exit 13

# A symlink is rejected; the target outside the stage survives cleanup.
target="$parent/symlink-target"
printf '%s\n' target >"$target"
chmod 0600 "$target"
symlink_stage="$parent/stage-symlink"
mkdir -m 0700 -- "$symlink_stage"
ln -s "$target" "$symlink_stage/controller.sh"
printf '%s\n' "$expected_marker" >"$symlink_stage/.owner"
chmod 0400 "$symlink_stage/.owner"
if validate_stage "$symlink_stage"; then exit 14; fi
cleanup_owned_stage "$symlink_stage"
[[ -f "$target" && "$(<"$target")" == target ]] || exit 15

# A marker mismatch is rejected before the append and its owned stage is
# removed.  No content is emitted by this test.
bad_marker="$parent/stage-bad-marker"
make_valid_stage "$bad_marker"
chmod 0600 "$bad_marker/.owner"
printf '%s\n' wrong >"$bad_marker/.owner"
chmod 0400 "$bad_marker/.owner"
if validate_stage "$bad_marker"; then exit 16; fi
cleanup_owned_stage "$bad_marker"

# Simulate a failing append after the short writable window.  The stage was
# created by this execution and therefore must be cleaned; no collision is
# allowed to escape the transaction.
append_failure="$parent/stage-append-failure"
make_valid_stage "$append_failure"
validate_stage "$append_failure"
chmod 0600 "$append_failure/controller.sh"
rm -- "$append_failure/controller.sh"
mkdir -- "$append_failure/controller.sh"
if ( cat "$part_b" >>"$append_failure/controller.sh" ) >/dev/null 2>&1; then exit 17; fi
cleanup_owned_stage "$append_failure"

printf '%s\n' stage_integration_restricted_identity_pass
STAGING_INTEGRATION
chmod 0755 "$tmp/staging-integration.sh"
staging_parent="$tmp/staging-parent"
mkdir -m 1777 "$staging_parent"
if (( EUID == 0 )); then
  # Some constrained development sandboxes run as uid 0 with every effective
  # capability removed and no ability to change uid.  That identity still
  # cannot bypass owner write bits, so it safely exercises the DAC transition;
  # a normal GitHub-hosted runner takes the non-root branch below.
  cap_eff="$(awk '/^CapEff:/ {print $2}' /proc/self/status 2>/dev/null || true)"
  [[ "$cap_eff" =~ ^0+$ ]] || test_fail staging_privileged_root_environment
  staging_output="$("$tmp/staging-integration.sh" "$staging_parent" "$tmp/controller-a.sh" "$tmp/controller-b.sh")" || test_fail staging_restricted_identity_integration
else
  staging_output="$("$tmp/staging-integration.sh" "$staging_parent" "$tmp/controller-a.sh" "$tmp/controller-b.sh")" || test_fail staging_nonroot_integration
fi
[[ "$staging_output" == stage_integration_restricted_identity_pass ]] || test_fail staging_restricted_identity_output
test_pass controller_staging_restricted_identity_integration

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

if len(lengths) != 4 or any(length >= 21000 for length in lengths):
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
EXPECTED_RECORDS=24
# shellcheck disable=SC1090
source "$tmp/parser.sh"

make_valid_log() {
  local output="$1" phase="$2" id
  : >"$output"
  local ids=(
    identity groups privilege_tools capabilities nonewprivs environment
    descriptors workdir_write outside_write_denied tmp_write_denied
    vartmp_write_denied devshm_write_denied workspace_hidden controller_hidden sockets_hidden run_mount
    network_interfaces routes dns_blocked tcp_blocked https_blocked
    cgroup_memory cgroup_pids cgroup_cpu
  )
  for id in "${ids[@]}"; do printf 'RESULT id=%s status=PASS code=ok\n' "$id" >>"$output"; done
  printf 'READY status=PASS records=24\n' >>"$output"
  [[ "$phase" == final ]] && printf 'FINAL status=PASS records=24\n' >>"$output"
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
sed -i '1iREADY status=PASS records=24' "$tmp/ready-early.log"
expect_reject "$tmp/ready-early.log" ready ready_before_results

cp "$valid_ready" "$tmp/result-after-ready.log"
sed -n '1p' "$valid_ready" >>"$tmp/result-after-ready.log"
expect_reject "$tmp/result-after-ready.log" ready result_after_ready

cp "$valid_final" "$tmp/after-final.log"
printf '%s\n' 'READY status=PASS records=24' >>"$tmp/after-final.log"
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

# The actual synchronous enumerator must preserve producer and sorter failures.
extract_marker_block INTERFACE_ENUMERATOR_BEGIN INTERFACE_ENUMERATOR_END "$tmp/probe.sh" "$tmp/interfaces.sh"
source "$tmp/interfaces.sh"
mkdir "$tmp/net-root" "$tmp/net-scratch"
make_tool() {
  local path="$1" body="$2"
  { printf '%s\n' '#!/usr/bin/env bash' 'set -u'; printf '%s\n' "$body"; } >"$path"
  chmod 0700 "$path"
}
make_tool "$tmp/find-valid" "printf 'lo\\n'"
make_tool "$tmp/find-extra" "printf 'lo\\neth0\\n'"
make_tool "$tmp/find-partial" "printf 'lo\\n'; exit 1"
make_tool "$tmp/find-empty" "exit 0"
make_tool "$tmp/find-error" "exit 2"
make_tool "$tmp/find-stderr" "printf 'lo\\n'; printf 'diagnostic\\n' >&2"
make_tool "$tmp/sort-fail" "cat >/dev/null; exit 1"
make_tool "$tmp/sort-stderr" "cat; printf 'diagnostic\\n' >&2"
enumerate_network_interfaces "$tmp/net-root" "$tmp/net-scratch" "$tmp/find-valid" /usr/bin/sort || test_fail interface_valid_rejected
set +e; enumerate_network_interfaces "$tmp/net-root" "$tmp/net-scratch" "$tmp/find-extra" /usr/bin/sort; rc=$?; set -e
[[ "$rc" == 1 ]] || test_fail interface_extra_not_rejected
for fixture in find-partial find-empty find-error find-stderr; do
  set +e; enumerate_network_interfaces "$tmp/net-root" "$tmp/net-scratch" "$tmp/$fixture" /usr/bin/sort; rc=$?; set -e
  [[ "$rc" == 2 ]] || test_fail "interface_${fixture}_not_inconclusive"
done
set +e; enumerate_network_interfaces "$tmp/net-root" "$tmp/net-scratch" "$tmp/find-valid" "$tmp/sort-fail"; rc=$?; set -e
[[ "$rc" == 2 ]] || test_fail interface_sort_failure_not_inconclusive
set +e; enumerate_network_interfaces "$tmp/net-root" "$tmp/net-scratch" "$tmp/find-valid" "$tmp/sort-stderr"; rc=$?; set -e
[[ "$rc" == 2 ]] || test_fail interface_sort_stderr_not_inconclusive
test_pass interface_enumeration_fail_closed

# Parse the effective /run mount using the exact function embedded in the probe.
extract_marker_block RUN_MOUNT_VALIDATOR_BEGIN RUN_MOUNT_VALIDATOR_END "$tmp/probe.sh" "$tmp/run-mount.sh"
source "$tmp/run-mount.sh"
make_mountinfo() {
  local output="$1" run_line="$2"
  printf '%s\n' '24 1 0:20 / / rw,relatime - overlay overlay rw' "$run_line" >"$output"
}
valid_run='25 24 0:45 / /run ro,nosuid,nodev,noexec,relatime - tmpfs tmpfs rw,size=1024k,inode64'
make_mountinfo "$tmp/mount-valid" "$valid_run"
[[ "$(validate_run_mountinfo "$tmp/mount-valid")" == 0:45 ]] || test_fail run_mount_valid_rejected
for pair in \
  'missing_ro|25 24 0:45 / /run rw,nosuid,nodev,noexec - tmpfs tmpfs rw,size=1024k' \
  'missing_nosuid|25 24 0:45 / /run ro,nodev,noexec - tmpfs tmpfs rw,size=1024k' \
  'unexpected_fstype|25 24 8:1 / /run ro,nosuid,nodev,noexec - ext4 host rw,size=1024k' \
  'propagation|25 24 0:45 / /run ro,nosuid,nodev,noexec shared:7 - tmpfs tmpfs rw,size=1024k' \
  'oversize|25 24 0:45 / /run ro,nosuid,nodev,noexec - tmpfs tmpfs rw,size=2048k'; do
  label="${pair%%|*}"; line="${pair#*|}"; make_mountinfo "$tmp/mount-$label" "$line"
  if validate_run_mountinfo "$tmp/mount-$label" >/dev/null 2>&1; then test_fail "run_mount_accepted_$label"; fi
done
make_mountinfo "$tmp/mount-duplicate" "$valid_run"
printf '%s\n' '26 24 0:46 / /run ro,nosuid,nodev,noexec - tmpfs tmpfs rw,size=1024k' >>"$tmp/mount-duplicate"
if validate_run_mountinfo "$tmp/mount-duplicate" >/dev/null 2>&1; then test_fail run_mount_accepted_duplicate; fi
make_mountinfo "$tmp/mount-submount" "$valid_run"
printf '%s\n' '26 25 0:46 / /run/unexpected ro,nosuid,nodev,noexec - tmpfs tmpfs rw,size=1024k' >>"$tmp/mount-submount"
if validate_run_mountinfo "$tmp/mount-submount" >/dev/null 2>&1; then test_fail run_mount_accepted_submount; fi
printf '%s\n' 'malformed' >"$tmp/mount-malformed"
set +e; validate_run_mountinfo "$tmp/mount-malformed" >/dev/null; rc=$?; set -e
[[ "$rc" == 2 ]] || test_fail run_mount_malformed_not_inconclusive
set +e; validate_run_mountinfo "$tmp/missing-mountinfo" >/dev/null; rc=$?; set -e
[[ "$rc" == 2 ]] || test_fail run_mount_unavailable_not_inconclusive
test_pass run_mountinfo_closed_validation

# Validate the system-manager representation semantically and fail closed.
extract_marker_block RUN_PROPERTY_VALIDATOR_BEGIN RUN_PROPERTY_VALIDATOR_END "$tmp/controller.sh" "$tmp/run-property.sh"
source "$tmp/run-property.sh"
validate_run_tmpfs_property '/run:ro,nosuid,nodev,noexec,size=1M' || test_fail run_property_valid_rejected
validate_run_tmpfs_property '/run:size=1024K,noexec,nodev,nosuid,ro' || test_fail run_property_equivalent_rejected
set +e; validate_run_tmpfs_property '/run:ro,nodev,noexec,size=1M'; rc=$?; set -e
[[ "$rc" == 1 ]] || test_fail run_property_missing_option_not_rejected
set +e; validate_run_tmpfs_property ''; rc=$?; set -e
[[ "$rc" == 2 ]] || test_fail run_property_unavailable_not_inconclusive
set +e; validate_run_tmpfs_property '/run:ro,nosuid,nodev,noexec,size=1M,unknown'; rc=$?; set -e
[[ "$rc" == 1 ]] || test_fail run_property_extra_not_rejected
grep -Fq "show_value \"\$MAIN_UNIT\" TemporaryFileSystem" "$tmp/controller.sh" || test_fail run_property_not_queried
test_pass run_systemd_property_validation

extract_marker_block RUN_IDENTITY_VALIDATOR_BEGIN RUN_IDENTITY_VALIDATOR_END "$tmp/controller.sh" "$tmp/run-identity.sh"
source "$tmp/run-identity.sh"
[[ "$(run_mount_device "$tmp/mount-valid")" == 0:45 ]] || test_fail run_identity_valid_rejected
set +e; run_mount_device "$tmp/mount-duplicate" >/dev/null; rc=$?; set -e
[[ "$rc" == 1 ]] || test_fail run_identity_duplicate_not_rejected
grep -Fq 'host_device" != "$service_device' "$tmp/run-identity.sh" || test_fail run_identity_distinct_missing
grep -Fq 'current_pid" == "$pid' "$tmp/run-identity.sh" || test_fail run_identity_pid_stability_missing
test_pass run_mount_identity_validation

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
grep -Fq "readonly PROBE_PATH='/usr/local/sbin/ti0093-vm-preflight-probe'" "$workflow" || test_fail probe_path_controller_mismatch
grep -Fq "probe_installed='/usr/local/sbin/ti0093-vm-preflight-probe'" "$workflow" || test_fail probe_install_path_controller_mismatch
! grep -Fq '/usr/local/libexec/ti0093-vm-preflight-probe' "$workflow" || test_fail obsolete_probe_path_present
grep -Fq 'metadata="$(stat -Lc '\''%u:%g:%a:%F'\'' -- "$target_dir" 2>/dev/null)" || return 1' "$workflow" || test_fail probe_parent_directory_metadata_gate
grep -Fq '[[ "$metadata" == '\''0:0:755:directory'\'' ]]' "$workflow" || test_fail probe_parent_directory_ownership_gate
grep -Fq 'sudo ln -- "$install_temp_path" "$target_path" || return 1' "$workflow" || test_fail transactional_publication_gate
grep -Fq 'install_root_owned_script "$probe_stage" "$probe_installed" probe_installed_by_run probe_installed_identity || exit 86' "$workflow" || test_fail probe_guarded_install
grep -Fq 'RUN_OWNER_TAG="ti0093-${GITHUB_RUN_ID:-invalid}-${GITHUB_RUN_ATTEMPT:-invalid}-${GITHUB_SHA:-invalid}"' "$workflow" || test_fail unit_owner_tag
test_pass collision_gates

grep -Fq "REPOSITORY_IS_PRIVATE:-}" "$tmp/controller.sh" || test_fail repository_visibility_consumed
grep -Fq "WORKFLOW_SHA:-}" "$tmp/controller.sh" || test_fail immutable_sha_gate
grep -Fq "write_summary 'NO-GO'" "$tmp/controller.sh" || test_fail fail_closed_summary
grep -Fq 'exit 86' "$tmp/controller.sh" || test_fail fail_closed_exit
test_pass fail_closed_decision

printf 'RESULT offline_static_tests=%s status=PASS\n' "$pass_count"
