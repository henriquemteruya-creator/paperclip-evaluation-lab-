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
extract_heredoc CONTROLLER_LIFECYCLE "$tmp/controller-lifecycle.sh"
extract_heredoc CONTROLLER_B "$tmp/controller-b.sh"
extract_heredoc CONTROLLER_MAIN "$tmp/controller-main.sh"
cat "$tmp/controller-a.sh" "$tmp/controller-lifecycle.sh" "$tmp/controller-b.sh" "$tmp/controller-main.sh" >"$tmp/controller.sh"
extract_heredoc PROBE_A "$tmp/probe-a.sh"
extract_heredoc PROBE_B "$tmp/probe-b.sh"
cat "$tmp/probe-a.sh" "$tmp/probe-b.sh" >"$tmp/probe.sh"
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

# Exercise the actual writer and reader together.  Only metadata for the two
# disposable executable paths is simulated as root-owned, allowing this exact
# fixture to run under a normal non-root user while production still demands
# real root:root metadata.
extract_marker_block INSTALL_MANIFEST_WRITER_BEGIN INSTALL_MANIFEST_WRITER_END "$workflow" "$tmp/manifest-writer.sh"
extract_marker_block INSTALL_MANIFEST_READER_BEGIN INSTALL_MANIFEST_READER_END "$workflow" "$tmp/manifest-reader.sh"
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

stat() {
  local format='' arg last=''
  for arg in "$@"; do
    [[ "$arg" == -c || "$arg" == -Lc ]] && continue
    [[ -z "$format" && "$arg" == *%* ]] && format="$arg"
    last="$arg"
  done
  if [[ "$last" == "$controller_installed" || "$last" == "$probe_installed" ]]; then
    case "$format" in
      '%d:%i:%u:%g:%a:%F') printf '%s:0:0:%s:%s\n' "$(command stat -Lc '%d:%i' -- "$last")" "$(command stat -Lc '%a' -- "$last")" "$(command stat -Lc '%F' -- "$last")"; return 0 ;;
    esac
  fi
  command stat "$@"
}
sudo() { "$@"; }
source "$tmp/manifest-writer.sh"
source "$tmp/manifest-reader.sh"
controller_installed_identity="$(command stat -Lc '%d:%i' -- "$controller_installed")"
probe_installed_identity="$(command stat -Lc '%d:%i' -- "$probe_installed")"

# Real writer -> published manifest -> real reader -> real verifier.
write_install_manifest || test_fail continuity_manifest_write_rejected
[[ -f "$manifest" && ! -L "$manifest" && "$(command stat -Lc '%a' -- "$manifest")" == 400 ]] || test_fail continuity_manifest_not_private
verify_stage_manifest || test_fail continuity_manifest_valid_rejected
stage_owned=true
read_install_manifest || test_fail continuity_manifest_parse_valid_rejected
verify_installed_artifact "$controller_installed" "$controller_identity" "$controller_hash" || test_fail continuity_controller_valid_rejected
verify_installed_artifact "$probe_installed" "$probe_identity" "$probe_hash" || test_fail continuity_probe_valid_rejected

# Collisions and partial writer failures must not overwrite/publish a manifest.
manifest_before="$(sha256sum -- "$manifest" | awk '{print $1}')"
set +e; write_install_manifest; rc=$?; set -e
[[ "$rc" == 1 && "$(sha256sum -- "$manifest" | awk '{print $1}')" == "$manifest_before" ]] || test_fail continuity_manifest_collision_not_preserved
rm -f -- "$manifest"
sha256sum() {
  [[ "${TEST_MANIFEST_HASH_FAIL:-false}" != true || "${!#}" != "$probe_installed" ]] || return 97
  command sha256sum "$@"
}
TEST_MANIFEST_HASH_FAIL=true
set +e; write_install_manifest; rc=$?; set -e
unset TEST_MANIFEST_HASH_FAIL
[[ "$rc" == 1 && ! -e "$manifest" && ! -L "$manifest" ]] || test_fail continuity_manifest_partial_publish
rm -f -- "$stage"/.installed-manifest.*
unset -f sha256sum
write_install_manifest || test_fail continuity_manifest_rewrite_after_partial
read_install_manifest || test_fail continuity_manifest_reparse_after_partial

# A symlink, missing file or device/inode drift cannot pass.  The hash case
# changes bytes in place, proving the identity is retained and rejection is
# specifically due to the recorded SHA-256 digest.
rm -f -- "$probe_installed"
ln -s "$controller_installed" "$probe_installed"
set +e; verify_installed_artifact "$probe_installed" "$probe_identity" "$probe_hash"; rc=$?; set -e
[[ "$rc" == 1 && -L "$probe_installed" ]] || test_fail continuity_symlink_not_rejected
rm -f -- "$probe_installed"
set +e; verify_installed_artifact "$probe_installed" "$probe_identity" "$probe_hash"; rc=$?; set -e
[[ "$rc" == 1 ]] || test_fail continuity_missing_not_rejected
printf '%s\n' probe >"$probe_installed"
chmod 0555 -- "$probe_installed"
set +e; verify_installed_artifact "$probe_installed" '999999:999999' "$probe_hash"; rc=$?; set -e
[[ "$rc" == 1 ]] || test_fail continuity_identity_drift_not_rejected
controller_identity_before="$(command stat -Lc '%d:%i' -- "$controller_installed")"
chmod u+w -- "$controller_installed"
printf '%s\n' altered-in-place >"$controller_installed"
chmod 0555 -- "$controller_installed"
controller_identity_after="$(command stat -Lc '%d:%i' -- "$controller_installed")"
[[ "$controller_identity_after" == "$controller_identity_before" && "$(command stat -Lc '%a' -- "$controller_installed")" == 555 ]] || test_fail continuity_hash_fixture_changed_identity_or_mode
set +e; verify_installed_artifact "$controller_installed" "$controller_identity" "$controller_hash"; rc=$?; set -e
[[ "$rc" == 1 ]] || test_fail continuity_hash_drift_not_rejected
set +e; remove_verified_artifact "$controller_installed" "$controller_identity" "$controller_hash"; rc=$?; set -e
[[ "$rc" == 1 && -f "$controller_installed" ]] || test_fail continuity_cleanup_removed_hash_divergent

# Altering a published manifest is rejected before executable validation.
replacement_manifest="$continuity_root/replacement-manifest"
cat -- "$manifest" >"$replacement_manifest"
printf 'extra\tentry\n' >>"$replacement_manifest"
chmod 0400 -- "$replacement_manifest"
mv -- "$replacement_manifest" "$manifest"
set +e; read_install_manifest; rc=$?; set -e
[[ "$rc" == 1 ]] || test_fail continuity_manifest_extra_record_not_rejected
unset -f sudo stat installed_artifact_record write_install_manifest verify_stage_manifest read_install_manifest verify_installed_artifact remove_verified_artifact remove_verified_stage
test_pass continuity_manifest_writer_reader_and_verified_cleanup

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

if len(lengths) != 7 or any(length >= 21000 for length in lengths):
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
EXPECTED_RECORDS=26
# shellcheck disable=SC1090
source "$tmp/parser.sh"

make_valid_log() {
  local output="$1" phase="$2" id
  : >"$output"
  local ids=(
    identity groups privilege_tools capabilities nonewprivs environment
    descriptors workdir_write outside_write_denied tmp_write_denied
    vartmp_write_denied devshm_write_denied workspace_hidden controller_hidden sockets_hidden run_mount run_mount_diagnostic
    network_interfaces routes dns_blocked tcp_blocked https_blocked netlink_denied
    cgroup_memory cgroup_pids cgroup_cpu
  )
  for id in "${ids[@]}"; do printf 'RESULT id=%s status=PASS code=ok\n' "$id" >>"$output"; done
  printf 'READY status=PASS records=26\n' >>"$output"
  [[ "$phase" == final ]] && printf 'FINAL status=PASS records=26\n' >>"$output"
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

# READY FAIL is a terminal diagnostic state, not a delayed timeout or a PASS.
extract_marker_block PROBE_READY_WAITER_BEGIN PROBE_READY_WAITER_END "$tmp/controller.sh" "$tmp/probe-ready-waiter.sh"
source "$tmp/probe-ready-waiter.sh"
ready_pass="$tmp/ready-pass.log"; ready_fail="$tmp/ready-fail.log"
printf 'READY status=PASS records=26\n' >"$ready_pass"
printf 'READY status=FAIL records=26\n' >"$ready_fail"
wait_for_probe_ready "$ready_pass" || test_fail ready_pass_not_recognized
set +e; wait_for_probe_ready "$ready_fail"; rc=$?; set -e
[[ "$rc" == 1 ]] || test_fail ready_fail_not_recognized
sleep() { :; }
set +e; wait_for_probe_ready "$tmp/ready-absent.log"; rc=$?; set -e
unset -f sleep
[[ "$rc" == 2 ]] || test_fail ready_missing_not_inconclusive
test_pass ready_state_fail_closed
extract_marker_block PROBE_READY_GATE_BEGIN PROBE_READY_GATE_END "$tmp/controller.sh" "$tmp/probe-ready-gate.sh"
source "$tmp/probe-ready-gate.sh"
probe_ready_gate "$valid_ready" 0 || test_fail valid_ready_pass_not_released

ready_failure="$tmp/ready-failure.log"
cp "$valid_ready" "$ready_failure"
sed -i '1cRESULT id=identity status=FAIL code=mismatch' "$ready_failure"
sed -i 's/^READY status=PASS /READY status=FAIL /' "$ready_failure"
set +e; probe_ready_gate "$ready_failure" 1; rc=$?; set -e
[[ "$rc" == 1 ]] || test_fail valid_ready_fail_not_classified

# The raw waiter can observe the first marker, but no contradictory, duplicate
# or malformed log is allowed to produce the gate's release result.
for invalid_case in contradictory duplicate malformed; do
  invalid_log="$tmp/ready-$invalid_case.log"
  cp "$valid_ready" "$invalid_log"
  case "$invalid_case" in
    contradictory) printf 'READY status=FAIL records=26\n' >>"$invalid_log" ;;
    duplicate) printf 'READY status=PASS records=26\n' >>"$invalid_log" ;;
    malformed) printf 'untrusted=malformed\n' >>"$invalid_log" ;;
  esac
  wait_for_probe_ready "$invalid_log" || test_fail "raw_waiter_did_not_observe_${invalid_case}_pass"
  set +e; probe_ready_gate "$invalid_log" 0; rc=$?; set -e
  [[ "$rc" == 2 ]] || test_fail "invalid_ready_${invalid_case}_released"
done
unset -f probe_ready_gate
test_pass ready_release_requires_full_parser
grep -Fq 'probe_ready_gate "$main_log" "$probe_ready_rc"' "$tmp/controller.sh" || test_fail ready_gate_not_used_by_controller
grep -Fq "runtime_namespace_evidence_unavailable_after_probe_failure" "$tmp/controller.sh" || test_fail namespace_post_failure_not_guarded
grep -Fq "runtime_run_mount_evidence_unavailable_after_probe_failure" "$tmp/controller.sh" || test_fail run_mount_post_failure_not_guarded
grep -Fq "main_unit_dynamic_evidence_unavailable_after_probe_failure" "$tmp/controller.sh" || test_fail terminal_post_failure_not_guarded
! grep -Fq 'wait_for_log_marker "$main_log" "READY status=PASS' "$tmp/controller.sh" || test_fail pass_only_ready_wait_retained
test_pass ready_failure_causal_guards

# Every PATH entry is inspected directly. Any executable privilege tool or
# symlink is an exposure (or an inconclusive resolution) and therefore NO-GO.
extract_marker_block PRIVILEGE_TOOL_VALIDATOR_BEGIN PRIVILEGE_TOOL_VALIDATOR_END "$tmp/probe.sh" "$tmp/privilege-tools.sh"
source "$tmp/privilege-tools.sh"
privbin="$tmp/privbin"; mkdir "$privbin"
printf '%s\n' '#!/bin/sh' >"$privbin/sudo"; chmod 0644 "$privbin/sudo"
ok_calls=0; bad_calls=0
ok() { (( ++ok_calls )); }
bad() { (( ++bad_calls )); }
PATH="$privbin" check_privilege_tools
[[ "$ok_calls" == 1 && "$bad_calls" == 0 ]] || test_fail inaccessible_privilege_tool_rejected
chmod 0700 "$privbin/sudo"
ok_calls=0; bad_calls=0
PATH="$privbin" check_privilege_tools
[[ "$ok_calls" == 0 && "$bad_calls" == 1 ]] || test_fail executable_privilege_tool_accepted
rm -f -- "$privbin/sudo"
printf '%s\n' '#!/bin/sh' >"$privbin/real-sudo"; chmod 0700 "$privbin/real-sudo"
ln -s real-sudo "$privbin/sudo"
ok_calls=0; bad_calls=0
PATH="$privbin" check_privilege_tools
[[ "$ok_calls" == 0 && "$bad_calls" == 1 ]] || test_fail executable_privilege_tool_symlink_accepted
rm -f -- "$privbin/sudo"
ln -s missing-sudo "$privbin/sudo"
ok_calls=0; bad_calls=0
PATH="$privbin" check_privilege_tools
[[ "$ok_calls" == 0 && "$bad_calls" == 1 ]] || test_fail dangling_privilege_tool_symlink_accepted
for ambiguous_path in '' ":$privbin" "$privbin:" "$privbin::$tmp/other"; do
  ok_calls=0; bad_calls=0
  PATH="$ambiguous_path" check_privilege_tools
  [[ "$ok_calls" == 0 && "$bad_calls" == 1 ]] || test_fail privilege_tool_ambiguous_path_accepted
done
unset -f ok bad check_privilege_tools
test_pass privilege_tool_effective_access

# The real environment checker must reject controller-only inheritance, parser
# errors and a command that produces partial data before failing.
awk '/^[[:space:]]*check_environment\(\) \{/ {inside=1} inside {print} /# FD_VALIDATOR_BEGIN/ {exit}' "$tmp/probe.sh" >"$tmp/environment.sh"
source "$tmp/environment.sh"
environment_baseline=$'PATH=/usr/sbin:/usr/bin:/sbin:/bin\nLANG=C\nLC_ALL=C\nINVOCATION_ID=fixture\nSYSTEMD_EXEC_PID=123\nPWD=/var/lib/ti0093-vm-preflight/work\nSHLVL=1\n_=/usr/bin/env'
environment_fixture="$environment_baseline"
env() { printf '%s\n' "$environment_fixture"; }
ok_calls=0; bad_calls=0
ok() { (( ++ok_calls )); }
bad() { (( ++bad_calls )); }
check_environment
[[ "$ok_calls" == 1 && "$bad_calls" == 0 ]] || test_fail environment_systemd_owned_fixture_rejected
environment_fixture+=$'\nRUN_OWNER_TAG=not-for-service'
ok_calls=0; bad_calls=0
check_environment
[[ "$ok_calls" == 0 && "$bad_calls" == 1 ]] || test_fail environment_controller_inheritance_accepted
environment_fixture="$environment_baseline"$'\nGITHUB_TOKEN=not-published'
ok_calls=0; bad_calls=0
check_environment
[[ "$ok_calls" == 0 && "$bad_calls" == 1 ]] || test_fail environment_sensitive_name_accepted
env() { printf '%s\n' "$environment_fixture"; return 73; }
ok_calls=0; bad_calls=0
check_environment
[[ "$ok_calls" == 0 && "$bad_calls" == 1 ]] || test_fail environment_partial_collection_accepted
unset -f env ok bad check_environment
grep -Fq 'REPOSITORY_IS_PRIVATE WORKFLOW_SHA RUN_OWNER_TAG SUMMARY_PATH' "$tmp/controller.sh" || test_fail controller_environment_not_unset
grep -Fq '/usr/bin/env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin LANG=C LC_ALL=C "$PROBE_PATH" "$RELEASE_FILE"' "$tmp/controller.sh" || test_fail controller_probe_environment_not_scrubbed
grep -Fq '/usr/bin/env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin LANG=C LC_ALL=C /usr/bin/sleep 30' "$tmp/controller.sh" || test_fail controller_canary_environment_not_scrubbed
test_pass environment_collection_fail_closed

# The controller accepts only root-owned 0600 regular files; GNU stat names an
# empty regular file differently, so both exact GNU names are covered here.
extract_marker_block PRIVATE_LOG_VALIDATOR_BEGIN PRIVATE_LOG_VALIDATOR_END "$tmp/controller.sh" "$tmp/private-log-validator.sh"
source "$tmp/private-log-validator.sh"
empty_log="$tmp/empty-private.log"
full_log="$tmp/full-private.log"
: >"$empty_log"; printf '%s\n' data >"$full_log"; chmod 0600 "$empty_log" "$full_log"
log_stat() { command stat "$@"; }
# The disposable fixture is non-root, so simulate only the ownership prefix.
stat() {
  if [[ "${*: -1}" == "$empty_log" || "${*: -1}" == "$full_log" ]]; then
    local last="${*: -1}" type
    type="$(command stat -Lc '%F' -- "$last")"
    printf '0:0:%s:%s\n' "$(command stat -Lc '%a' -- "$last")" "$type"
  else command stat "$@"; fi
}
log_file_is_private "$empty_log" || test_fail private_empty_log_rejected
log_file_is_private "$full_log" || test_fail private_full_log_rejected
ln -s "$empty_log" "$tmp/private-log-link"
if log_file_is_private "$tmp/private-log-link"; then test_fail private_log_symlink_accepted; fi
chmod 0644 "$full_log"
if log_file_is_private "$full_log"; then test_fail private_log_bad_mode_accepted; fi
chmod 0600 "$full_log"
unset -f stat log_stat
test_pass private_log_gnu_stat_types

# Extract the actual finite-ID diagnostic helper. It may reveal only an
# allowlisted control ID, never a probe code, line, path, or environment value.
extract_marker_block PROBE_DIAGNOSTICS_BEGIN PROBE_DIAGNOSTICS_END "$tmp/controller.sh" "$tmp/probe-diagnostics.sh"
source "$tmp/probe-diagnostics.sh"
cp "$valid_ready" "$tmp/diagnostic-failure.log"
sed -i '1cRESULT id=identity status=FAIL code=untrusted_secret_path' "$tmp/diagnostic-failure.log"
set +e; parse_probe_log "$tmp/diagnostic-failure.log" ready; rc=$?; set -e
[[ "$rc" == 1 ]] || test_fail parser_reported_failure_not_distinct
[[ "$(probe_failure_ids "$tmp/diagnostic-failure.log" ready)" == identity ]] || test_fail probe_diagnostic_allowlisted_id
cp "$tmp/diagnostic-failure.log" "$tmp/diagnostic-multiple.log"
sed -i '2cRESULT id=groups status=FAIL code=another_internal_reason' "$tmp/diagnostic-multiple.log"
[[ "$(probe_failure_ids "$tmp/diagnostic-multiple.log" ready)" == identity,groups ]] || test_fail probe_diagnostic_multiple_failures
cp "$tmp/diagnostic-failure.log" "$tmp/diagnostic-unknown.log"
sed -i '2cRESULT id=private_path status=FAIL code=secret_value' "$tmp/diagnostic-unknown.log"
set +e; captured="$(probe_failure_ids "$tmp/diagnostic-unknown.log" ready)"; rc=$?; set -e
[[ "$rc" == 2 ]] || test_fail probe_diagnostic_unknown_id_not_rejected
[[ -z "$captured" ]] || test_fail probe_diagnostic_partial_output
cp "$tmp/diagnostic-failure.log" "$tmp/diagnostic-duplicate.log"
sed -n '1p' "$tmp/diagnostic-failure.log" >>"$tmp/diagnostic-duplicate.log"
set +e; captured="$(probe_failure_ids "$tmp/diagnostic-duplicate.log" ready)"; rc=$?; set -e
[[ "$rc" == 2 && -z "$captured" ]] || test_fail probe_diagnostic_duplicate_output
cp "$tmp/diagnostic-failure.log" "$tmp/diagnostic-truncated.log"
truncate -s -1 "$tmp/diagnostic-truncated.log"
set +e; captured="$(probe_failure_ids "$tmp/diagnostic-truncated.log" ready)"; rc=$?; set -e
[[ "$rc" == 2 && -z "$captured" ]] || test_fail probe_diagnostic_truncated_output
python3 - "$tmp/diagnostic-many.log" <<'PY'
from pathlib import Path
import sys
Path(sys.argv[1]).write_text(('RESULT id=identity status=FAIL code=x\n' * 400), encoding='ascii')
PY
set +e; captured="$(probe_failure_ids "$tmp/diagnostic-many.log" ready)"; rc=$?; set -e
[[ "$rc" == 2 && -z "$captured" ]] || test_fail probe_diagnostic_many_output
captured="$(probe_failure_ids "$tmp/diagnostic-failure.log" ready 2>&1 || true)"
[[ "$captured" != *untrusted_secret_path* && "$captured" != *private_path* && "$captured" == identity ]] || test_fail probe_diagnostic_leak
test_pass probe_diagnostics_allowlisted_and_sanitized

# The supplementary public categories use a separate closed vocabulary. They
# are emitted only after the complete private log has passed the same parser.
cp "$valid_ready" "$tmp/category-valid.log"
sed -i '17cRESULT id=run_mount_diagnostic status=FAIL code=private_root_restrictive' "$tmp/category-valid.log"
sed -i '19cRESULT id=routes status=FAIL code=ipv4_query_error' "$tmp/category-valid.log"
sed -i '21cRESULT id=tcp_blocked status=FAIL code=not_attempted_prerequisite' "$tmp/category-valid.log"
sed -i '22cRESULT id=https_blocked status=FAIL code=inconclusive' "$tmp/category-valid.log"
captured="$(probe_failure_categories "$tmp/category-valid.log" ready)" || test_fail probe_categories_valid_rejected
[[ "$captured" == 'run_mount_diagnostic=private_root_restrictive,routes=ipv4_query_error,tcp_blocked=not_attempted_prerequisite,https_blocked=inconclusive' ]] || test_fail probe_categories_wrong_pairs
cp "$tmp/category-valid.log" "$tmp/category-invalid-code.log"
sed -i '19cRESULT id=routes status=FAIL code=private_route_10_0_0_1' "$tmp/category-invalid-code.log"
set +e; captured="$(probe_failure_categories "$tmp/category-invalid-code.log" ready)"; rc=$?; set -e
[[ "$rc" == 2 && -z "$captured" ]] || test_fail probe_categories_unknown_code_output
cp "$tmp/category-valid.log" "$tmp/category-truncated.log"
truncate -s -1 "$tmp/category-truncated.log"
set +e; captured="$(probe_failure_categories "$tmp/category-truncated.log" ready)"; rc=$?; set -e
[[ "$rc" == 2 && -z "$captured" ]] || test_fail probe_categories_truncated_output
set +e; captured="$(probe_failure_categories "$valid_ready" ready)"; rc=$?; set -e
[[ "$rc" == 1 && -z "$captured" ]] || test_fail probe_categories_pass_log_output
[[ "$captured" != *private_route* && "$captured" != *10_0_0_1* ]] || test_fail probe_categories_sensitive_leak
test_pass probe_categories_closed_and_atomic

# The final public publisher is itself closed: even a simulated extractor that
# returns text cannot bypass syntax, cardinality, ID/category or label checks.
simulated_category_extractor() { printf '%s' "$1"; }
published="$(publish_failure_categories probe_ready_failure_categories "$(simulated_category_extractor 'routes=ipv4_query_error,tcp_blocked=inconclusive')")" || test_fail probe_category_publication_valid_rejected
[[ "$published" == 'INFO probe_ready_failure_categories=routes=ipv4_query_error,tcp_blocked=inconclusive' ]] || test_fail probe_category_publication_wrong_output
set +e; published="$(publish_failure_categories probe_ready_failure_categories "$(simulated_category_extractor 'routes=ipv4_query_error,private_id=secret')")"; rc=$?; set -e
[[ "$rc" != 0 && -z "$published" ]] || test_fail probe_category_publication_partial_invalid
set +e; published="$(publish_failure_categories probe_final_failure_categories "$(simulated_category_extractor 'routes=private_route_10_0_0_1')")"; rc=$?; set -e
[[ "$rc" != 0 && -z "$published" ]] || test_fail probe_category_publication_unknown_category
set +e; published="$(publish_failure_categories unexpected_label "$(simulated_category_extractor 'routes=present')")"; rc=$?; set -e
[[ "$rc" != 0 && -z "$published" ]] || test_fail probe_category_publication_bad_label
unset -f simulated_category_extractor
test_pass probe_category_publication_closed_and_atomic

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
sed -i '1iREADY status=PASS records=26' "$tmp/ready-early.log"
expect_reject "$tmp/ready-early.log" ready ready_before_results

cp "$valid_ready" "$tmp/result-after-ready.log"
sed -n '1p' "$valid_ready" >>"$tmp/result-after-ready.log"
expect_reject "$tmp/result-after-ready.log" ready result_after_ready

cp "$valid_final" "$tmp/after-final.log"
printf '%s\n' 'READY status=PASS records=26' >>"$tmp/after-final.log"
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

# ---------------------------------------------------------------------------
# Network isolation evidence.
#   Authority: the service's own network namespace listing only "lo"
#   (/proc/<pid>/net/dev, strict parser, read twice: by the probe from inside
#   and independently by the controller), plus effective unit properties,
#   a negative AF_NETLINK probe and negative connectivity probes.
#   /sys/class/net can only confirm or contradict that listing.
#   The route files are COMPLEMENTARY and PARTIAL (IPv4 main table only).
# Fixture provenance: samples were captured offline from a disposable
# unprivileged netns on a WSL2 6.18 kernel; they say nothing about the
# GitHub-hosted runner kernel.
# ---------------------------------------------------------------------------
extract_marker_block NETDEV_INSPECTOR_BEGIN NETDEV_INSPECTOR_END "$tmp/probe.sh" "$tmp/netdev-probe.sh"
extract_marker_block NETDEV_INSPECTOR_BEGIN NETDEV_INSPECTOR_END "$tmp/controller.sh" "$tmp/netdev-controller.sh"
cmp -s "$tmp/netdev-probe.sh" "$tmp/netdev-controller.sh" || test_fail netdev_inspector_probe_controller_drift
source "$tmp/netdev-probe.sh"
extract_marker_block ROUTE_INSPECTOR_BEGIN ROUTE_INSPECTOR_END "$tmp/probe.sh" "$tmp/route-inspector.sh"
source "$tmp/route-inspector.sh"
sf="$tmp/snapfx"; mkdir "$sf" "$sf/scratch"
mkbytes() { python3 -I -c 'import sys; open(sys.argv[1],"wb").write(eval(sys.argv[2]))' "$1" "$2"; }
snap_expect() { # name python-bytes-expression expected_rc
  local name="$1" rc=0
  mkbytes "$sf/$name" "$2"
  snapshot_proc_file "$sf/$name" "$sf/scratch/$name.snap" >/dev/null 2>&1 || rc=$?
  [[ "$rc" == "$3" ]] || test_fail "snapshot_${name}_got_${rc}_want_${3}"
  if [[ "$3" != 0 ]]; then [[ ! -e "$sf/scratch/$name.snap" ]] || test_fail "snapshot_${name}_left_residue"; fi
}
snap_expect ok 'b"abc\n"' 0
snap_expect empty 'b""' 3
snap_expect only_lf 'b"\n"' 0
snap_expect exactly_4096 'b"a"*4095+b"\n"' 0
snap_expect over_4096 'b"a"*4096+b"\n"' 2
snap_expect huge 'b"a"*1000000+b"\n"' 2
snap_expect nul_middle 'b"ab\x00cd\n"' 2
snap_expect nul_only 'b"\x00"' 2
snap_expect nul_before_lf 'b"abc\x00\n"' 2
snap_expect no_final_lf 'b"abc"' 2
snap_expect cr 'b"abc\r\n"' 2
snap_expect esc 'b"a\x1bb\n"' 2
snap_expect high_byte 'b"a\xffb\n"' 2
snap_expect vtab 'b"a\x0bb\n"' 2
snap_expect formfeed 'b"a\x0cb\n"' 2
snap_expect tab_ok 'b"a\tb\n"' 0
rc=0; snapshot_proc_file "$sf/missing" "$sf/scratch/missing.snap" >/dev/null 2>&1 || rc=$?; [[ "$rc" == 3 ]] || test_fail snapshot_missing
mkdir "$sf/adir"; rc=0; snapshot_proc_file "$sf/adir" "$sf/scratch/adir.snap" >/dev/null 2>&1 || rc=$?; [[ "$rc" == 3 ]] || test_fail snapshot_directory
ln -s ok "$sf/slink"; rc=0; snapshot_proc_file "$sf/slink" "$sf/scratch/slink.snap" >/dev/null 2>&1 || rc=$?; [[ "$rc" == 3 ]] || test_fail snapshot_symlink_source
rc=0; snapshot_proc_file "relative/path" "$sf/scratch/rel.snap" >/dev/null 2>&1 || rc=$?; [[ "$rc" == 3 ]] || test_fail snapshot_relative_source
rc=0; snapshot_proc_file "$sf/ok" "relative.snap" >/dev/null 2>&1 || rc=$?; [[ "$rc" == 3 ]] || test_fail snapshot_relative_dest
rc=0; snapshot_proc_file "$sf/../snapfx/ok" "$sf/scratch/dots.snap" >/dev/null 2>&1 || rc=$?; [[ "$rc" == 3 ]] || test_fail snapshot_dotdot_source
rc=0; snapshot_proc_file "$sf/ok" "$sf/scratch/../dots.snap" >/dev/null 2>&1 || rc=$?; [[ "$rc" == 3 ]] || test_fail snapshot_dotdot_dest
rc=0; snapshot_proc_file "$sf/ok" "$sf/no-such-dir/x.snap" >/dev/null 2>&1 || rc=$?; [[ "$rc" == 3 ]] || test_fail snapshot_missing_dest_dir
ln -s "$sf/scratch" "$sf/scratch-link"; rc=0; snapshot_proc_file "$sf/ok" "$sf/scratch-link/x.snap" >/dev/null 2>&1 || rc=$?; [[ "$rc" == 3 ]] || test_fail snapshot_symlinked_dest_dir
printf 'precious' >"$sf/scratch/exists.snap"; rc=0; snapshot_proc_file "$sf/ok" "$sf/scratch/exists.snap" >/dev/null 2>&1 || rc=$?
[[ "$rc" == 3 && "$(<"$sf/scratch/exists.snap")" == precious ]] || test_fail snapshot_overwrote_or_removed_existing_destination
ln -s "$sf/ok" "$sf/scratch/dlink.snap"; rc=0; snapshot_proc_file "$sf/ok" "$sf/scratch/dlink.snap" >/dev/null 2>&1 || rc=$?
[[ "$rc" == 3 && -L "$sf/scratch/dlink.snap" ]] || test_fail snapshot_followed_destination_symlink
if [[ "$(id -u)" != 0 ]]; then
  cp "$sf/ok" "$sf/unreadable"; chmod 000 "$sf/unreadable"
  rc=0; snapshot_proc_file "$sf/unreadable" "$sf/scratch/unreadable.snap" >/dev/null 2>&1 || rc=$?
  [[ "$rc" == 3 && ! -e "$sf/scratch/unreadable.snap" ]] || test_fail snapshot_unreadable_not_unavailable
  chmod 644 "$sf/unreadable"
else
  inconclusive_count=$(( ${inconclusive_count:-0} + 1 )); printf '%s\n' 'INCONCLUSIVE snapshot_unreadable_running_as_root'
fi
test_pass proc_snapshot_binary_safe_and_bounded

# --- /proc/<pid>/net/dev strict parser ---------------------------------------
nd_h1='Inter-|   Receive                                                |  Transmit'
nd_h2=' face |bytes    packets errs drop fifo frame compressed multicast|bytes    packets errs drop fifo colls carrier compressed'
nd_cols='       0       0    0    0    0     0          0         0        0       0    0    0    0     0       0          0'
nd_row() { printf '%6s:%s\n' "$1" "$nd_cols"; }
nd="$tmp/netdevfx"; mkdir "$nd" "$nd/scratch"
mknd() { local name="$1"; shift; printf '%s' "$1" >"$nd/$name"; }
expect_nd() { local name="$1" want="$2" rc=0; inspect_net_dev "$nd/$name" "$nd/scratch" >/dev/null 2>&1 || rc=$?; [[ "$rc" == "$want" ]] || test_fail "net_dev_${name}_got_${rc}_want_${want}"; [[ -z "$(ls -A "$nd/scratch")" ]] || test_fail "net_dev_${name}_left_residue"; }
head_lines="$nd_h1"$'\n'"$nd_h2"$'\n'
mknd lo_only "$head_lines$(nd_row lo)"$'\n';                                   expect_nd lo_only 0        # kernel sample: new netns, lo only
mknd eth0_only "$head_lines$(nd_row eth0)"$'\n';                               expect_nd eth0_only 1
mknd lo_veth "$head_lines$(nd_row lo)"$'\n'"$(nd_row veth0)"$'\n';             expect_nd lo_veth 1        # kernel sample: lo + extra interface
mknd lo_tun "$head_lines$(nd_row lo)"$'\n'"$(nd_row tun0)"$'\n';               expect_nd lo_tun 1
mknd lo_tap "$head_lines$(nd_row lo)"$'\n'"$(nd_row tap0)"$'\n';               expect_nd lo_tap 1
mknd lo_docker "$head_lines$(nd_row lo)"$'\n'"$(nd_row docker0)"$'\n';         expect_nd lo_docker 1
mknd lo_alias "$head_lines$(nd_row lo)"$'\n'"$(nd_row 'eth0@if5')"$'\n';       expect_nd lo_alias 1
mknd extra_before_lo "$head_lines$(nd_row eth0)"$'\n'"$(nd_row lo)"$'\n';      expect_nd extra_before_lo 1
mknd two_lo "$head_lines$(nd_row lo)"$'\n'"$(nd_row lo)"$'\n';                 expect_nd two_lo 1
mknd lookalike_lo "$head_lines$(nd_row lo0)"$'\n';                             expect_nd lookalike_lo 1
mknd uppercase_lo "$head_lines$(nd_row LO)"$'\n';                              expect_nd uppercase_lo 1
mknd no_rows "$head_lines";                                                    expect_nd no_rows 2
mknd empty "";                                                                 expect_nd empty 3
expect_nd missing_file 3
mknd header_only_one_line "$nd_h1"$'\n';                                       expect_nd header_only_one_line 2
mknd wrong_header1 "Inter-|   Rx |  Transmit"$'\n'"$nd_h2"$'\n'"$(nd_row lo)"$'\n'; expect_nd wrong_header1 2
mknd wrong_header2 "$nd_h1"$'\n'" face |bogus"$'\n'"$(nd_row lo)"$'\n';       expect_nd wrong_header2 2
mknd no_final_newline "$head_lines$(nd_row lo)";                               expect_nd no_final_newline 2
mknd truncated_row "$head_lines    lo:       0       0    0"$'\n';             expect_nd truncated_row 2
mknd row_15_cols "$head_lines    lo:${nd_cols% 0}"$'\n';                        expect_nd row_15_cols 2
mknd row_17_cols "$head_lines    lo:${nd_cols} 0"$'\n';                         expect_nd row_17_cols 2
mknd non_numeric "$head_lines    lo:${nd_cols/  0    0/  x    0}"$'\n';        expect_nd non_numeric 2
mknd tab_in_row "$head_lines    lo:"$'\t'"${nd_cols}"$'\n';                     expect_nd tab_in_row 2
mknd long_name "$head_lines$(nd_row abcdefghijklmnop)"$'\n';                   expect_nd long_name 2
mknd colon_name "$head_lines$(nd_row 'l:o')"$'\n';                             expect_nd colon_name 2
mknd no_colon "$head_lines    lo ${nd_cols}"$'\n';                              expect_nd no_colon 2
mknd crlf "$head_lines$(nd_row lo)"$'\r\n';                                    expect_nd crlf 2
mknd trailing_blank "$head_lines$(nd_row lo)"$'\n\n';                          expect_nd trailing_blank 2
mknd trailing_blanks "$head_lines$(nd_row lo)"$'\n\n\n\n';                     expect_nd trailing_blanks 2
mknd blank_between "$head_lines$(nd_row lo)"$'\n\n'"$(nd_row eth0)"$'\n';      expect_nd blank_between 2
mknd many_rows "$head_lines$(for _ in $(seq 20); do nd_row lo; done)";         expect_nd many_rows 2
printf '%s' "$head_lines$(nd_row lo)"$'\n' >"$nd/nul_inside"; python3 -I -c 'import sys; p=sys.argv[1]; b=open(p,"rb").read(); open(p,"wb").write(b[:-5]+b"\x00"+b[-5:])' "$nd/nul_inside"; expect_nd nul_inside 2
printf '%s' "$head_lines$(nd_row lo)"$'\n' >"$nd/nul_tail"; python3 -I -c 'import sys; open(sys.argv[1],"ab").write(b"\x00")' "$nd/nul_tail"; expect_nd nul_tail 2
# The real kernel format on THIS host must always parse (verdict 0 or 1, never 2/3).
rc=0; inspect_net_dev /proc/self/net/dev "$nd/scratch" >/dev/null 2>&1 || rc=$?; [[ "$rc" == 0 || "$rc" == 1 ]] || test_fail net_dev_real_proc_format_not_parsed
ln -s lo_only "$nd/slink"; rc=0; inspect_net_dev "$nd/slink" "$nd/scratch" >/dev/null 2>&1 || rc=$?; [[ "$rc" == 3 ]] || test_fail net_dev_symlink_accepted
rc=0; inspect_net_dev "$nd/lo_only" "relative" >/dev/null 2>&1 || rc=$?; [[ "$rc" == 3 ]] || test_fail net_dev_relative_scratch
test_pass net_dev_strict_lo_only_fixtures

# --- complementary route inspectors (IPv4 main table only; IPv6 all tables) --
z32=00000000000000000000000000000000
r4_header=$'Iface\tDestination\tGateway \tFlags\tRefCnt\tUse\tMetric\tMask\t\tMTU\tWindow\tIRTT                                                       '
r6_null="$z32 00 $z32 00 $z32 ffffffff 00000001 00000000 00200200       lo"
r6_local="${z32:0:31}1 80 $z32 00 $z32 00000000 00000002 00000000 80200001       lo"
r6_default="$z32 00 $z32 00 fe800000000000000000000000000001 00000400 00000001 00000000 00000003     eth0"
fx="$tmp/routefx"; mkdir "$fx" "$fx/scratch"
mkfx() { local name="$1"; shift; printf '%s' "$1" >"$fx/$name"; }
expect_route() {
  local inspector="$1" name="$2" expected="$3" rc=0
  "$inspector" "$fx/$name" "$fx/scratch" >/dev/null 2>&1 || rc=$?
  [[ "$rc" == "$expected" ]] || test_fail "route_${inspector}_${name}_got_${rc}_want_${expected}"
  [[ -z "$(ls -A "$fx/scratch")" ]] || test_fail "route_${inspector}_${name}_left_residue"
}
row4=$'eth0\t00000000\t0100000A\t0003\t0\t0\t100\t00000000\t0\t0\t0\n'
mkfx v4_header_only "$r4_header"$'\n';                          expect_route inspect_ipv4_routes v4_header_only 0     # kernel sample: lo up, empty MAIN table
: >"$fx/v4_empty";                                               expect_route inspect_ipv4_routes v4_empty 3            # kernel sample: lo down => zero bytes
expect_route inspect_ipv4_routes v4_missing 3
mkdir "$fx/v4_dir"; expect_route inspect_ipv4_routes v4_dir 3
ln -s v4_header_only "$fx/v4_symlink"; expect_route inspect_ipv4_routes v4_symlink 3
mkfx v4_no_final_newline "$r4_header";                           expect_route inspect_ipv4_routes v4_no_final_newline 2
mkfx v4_default_route "$r4_header"$'\n'"$row4";                  expect_route inspect_ipv4_routes v4_default_route 1
mkfx v4_loopback_route "$r4_header"$'\n'$'lo\t0000007F\t00000000\t0001\t0\t0\t0\t000000FF\t0\t0\t0\n'; expect_route inspect_ipv4_routes v4_loopback_route 1
mkfx v4_blackhole "$r4_header"$'\n'$'*\t0000070A\t00000000\t0001\t0\t0\t0\t0000FFFF\t0\t0\t0\n'; expect_route inspect_ipv4_routes v4_blackhole 1
mkfx v4_route_after_blank "$r4_header"$'\n\n'"$row4";            expect_route inspect_ipv4_routes v4_route_after_blank 2
mkfx v4_trailing_blank "$r4_header"$'\n\n';                      expect_route inspect_ipv4_routes v4_trailing_blank 2   # B2 regression
mkfx v4_trailing_blanks "$r4_header"$'\n\n\n\n';                 expect_route inspect_ipv4_routes v4_trailing_blanks 2  # B2 regression
printf '%s' "$r4_header"$'\n' >"$fx/v4_nul"; python3 -I -c 'import sys; open(sys.argv[1],"ab").write(b"\x00")' "$fx/v4_nul"; expect_route inspect_ipv4_routes v4_nul 2   # B2 regression
printf '%s' "$r4_header"$'\n' >"$fx/v4_nul_in_header"; python3 -I -c 'import sys; p=sys.argv[1]; b=open(p,"rb").read(); open(p,"wb").write(b[:8]+b"\x00"+b[8:])' "$fx/v4_nul_in_header"; expect_route inspect_ipv4_routes v4_nul_in_header 2
mkfx v4_truncated_row "$r4_header"$'\n'$'eth0\t00000000\t0100000A\t00\n'; expect_route inspect_ipv4_routes v4_truncated_row 2
mkfx v4_lowercase_hex "$r4_header"$'\n'$'eth0\t0000000a\t0100000A\t0003\t0\t0\t100\t00000000\t0\t0\t0\n'; expect_route inspect_ipv4_routes v4_lowercase_hex 2
mkfx v4_extra_field "$r4_header"$'\n'"${row4%$'\n'}"$'\t9\n';     expect_route inspect_ipv4_routes v4_extra_field 2
mkfx v4_wrong_header $'Iface\tDestination\tGateway\tFlags\tRefCnt\tUse\tMetric\tMask\tMTU\tWindow\tBOGUS\n'; expect_route inspect_ipv4_routes v4_wrong_header 2
mkfx v4_blank_first_line $'\n';                                  expect_route inspect_ipv4_routes v4_blank_first_line 2
mkfx v4_duplicate_header "$r4_header"$'\n'"$r4_header"$'\n';     expect_route inspect_ipv4_routes v4_duplicate_header 2
mkfx v4_escape_in_iface "$r4_header"$'\n'$'e\033[0mth\t00000000\t0100000A\t0003\t0\t0\t100\t00000000\t0\t0\t0\n'; expect_route inspect_ipv4_routes v4_escape_in_iface 2
mkfx v4_long_iface "$r4_header"$'\n'$'abcdefghijklmnop\t00000000\t0100000A\t0003\t0\t0\t100\t00000000\t0\t0\t0\n'; expect_route inspect_ipv4_routes v4_long_iface 2
mkfx v4_crlf "$r4_header"$'\r\n';                                expect_route inspect_ipv4_routes v4_crlf 2
python3 -I -c "import sys; sys.stdout.write('Iface\tDestination\tGateway \tFlags\tRefCnt\tUse\tMetric\tMask\t\tMTU\tWindow\tIRTT\n' + 'x'*5000 + '\n')" >"$fx/v4_oversize"; expect_route inspect_ipv4_routes v4_oversize 2
mkfx v4_many_rows "$r4_header"$'\n'"$(for _ in $(seq 20); do printf '%s' "$row4"; done)"; expect_route inspect_ipv4_routes v4_many_rows 2
mkfx v6_kernel_lo_up "$r6_null"$'\n'"$r6_local"$'\n'"$r6_null"$'\n';  expect_route inspect_ipv6_routes v6_kernel_lo_up 0
mkfx v6_kernel_lo_down "$r6_null"$'\n'"$r6_null"$'\n';                expect_route inspect_ipv6_routes v6_kernel_lo_down 0
: >"$fx/v6_empty"; expect_route inspect_ipv6_routes v6_empty 3
expect_route inspect_ipv6_routes v6_missing 3
mkfx v6_local_only "$r6_local"$'\n';                                   expect_route inspect_ipv6_routes v6_local_only 3
mkfx v6_default_route "$r6_null"$'\n'"$r6_default"$'\n';               expect_route inspect_ipv6_routes v6_default_route 1
mkfx v6_nonmain_table_route "$r6_null"$'\n'"20010db8010000000000000000000000 40 $z32 00 $z32 00000400 00000001 00000000 00200200       lo"$'\n'; expect_route inspect_ipv6_routes v6_nonmain_table_route 1  # kernel sample: table 100 route is listed
mkfx v6_special_plus_real "$r6_null"$'\n'"$r6_local"$'\n'"$r6_default"$'\n'; expect_route inspect_ipv6_routes v6_special_plus_real 1
mkfx v6_null_wrong_iface "${r6_null%lo}eth0"$'\n';                     expect_route inspect_ipv6_routes v6_null_wrong_iface 1
mkfx v6_null_wrong_flags "${r6_null/00200200/00000200}"$'\n'"$r6_null"$'\n'; expect_route inspect_ipv6_routes v6_null_wrong_flags 1
mkfx v6_local_wrong_iface "$r6_null"$'\n'"${r6_local%lo}eth0"$'\n';    expect_route inspect_ipv6_routes v6_local_wrong_iface 1
mkfx v6_local_wrong_flags "$r6_null"$'\n'"${r6_local/80200001/80200003}"$'\n'; expect_route inspect_ipv6_routes v6_local_wrong_flags 1
mkfx v6_multicast_lo "$r6_null"$'\n'"ff000000000000000000000000000000 08 $z32 00 $z32 00000100 00000000 00000000 00200001       lo"$'\n'; expect_route inspect_ipv6_routes v6_multicast_lo 1
mkfx v6_linklocal_lo "$r6_null"$'\n'"fe800000000000000000000000000000 40 $z32 00 $z32 00000100 00000001 00000000 00000001       lo"$'\n'; expect_route inspect_ipv6_routes v6_linklocal_lo 1
mkfx v6_nine_fields "${r6_null% lo}"$'\n';                             expect_route inspect_ipv6_routes v6_nine_fields 2
mkfx v6_uppercase "${r6_null/ffffffff/FFFFFFFF}"$'\n';                 expect_route inspect_ipv6_routes v6_uppercase 2
mkfx v6_non_hex "${r6_null/ffffffff/ffffffzz}"$'\n';                   expect_route inspect_ipv6_routes v6_non_hex 2
mkfx v6_no_final_newline "$r6_null";                                   expect_route inspect_ipv6_routes v6_no_final_newline 2
mkfx v6_trailing_blank "$r6_null"$'\n'"$r6_null"$'\n\n';               expect_route inspect_ipv6_routes v6_trailing_blank 2   # B2 regression
mkfx v6_trailing_blanks "$r6_null"$'\n'"$r6_null"$'\n\n\n\n';          expect_route inspect_ipv6_routes v6_trailing_blanks 2  # B2 regression
printf '%s' "$r6_null"$'\n' >"$fx/v6_nul"; python3 -I -c 'import sys; open(sys.argv[1],"ab").write(b"\x00")' "$fx/v6_nul"; expect_route inspect_ipv6_routes v6_nul 2   # B2 regression
printf '%s' "$r6_null"$'\n' >"$fx/v6_nul_in_field"; python3 -I -c 'import sys; p=sys.argv[1]; b=open(p,"rb").read(); open(p,"wb").write(b[:40]+b"\x00"+b[40:])' "$fx/v6_nul_in_field"; expect_route inspect_ipv6_routes v6_nul_in_field 2
mkfx v6_truncated_row "$r6_null"$'\n'"${r6_null:0:50}"$'\n';           expect_route inspect_ipv6_routes v6_truncated_row 2
mkfx v6_many_rows "$(for _ in $(seq 20); do printf '%s\n' "$r6_null"; done)"; expect_route inspect_ipv6_routes v6_many_rows 2
mkfx v6_crlf "$r6_null"$'\r\n';                                        expect_route inspect_ipv6_routes v6_crlf 2
mkfx v6_escape_in_iface "${r6_null%lo}l"$'\033'"o"$'\n';              expect_route inspect_ipv6_routes v6_escape_in_iface 2
cp "$fx/v4_header_only" "$fx/cross4"; expect_route inspect_ipv6_routes cross4 2
cp "$fx/v6_kernel_lo_up" "$fx/cross6"; expect_route inspect_ipv4_routes cross6 2
rc=0; inspect_ipv4_routes "$fx/v4_header_only" "relative" >/dev/null 2>&1 || rc=$?; [[ "$rc" == 3 ]] || test_fail route_relative_scratch
[[ -z "$(inspect_ipv4_routes "$fx/v4_default_route" "$fx/scratch" 2>&1 || true)" && -z "$(inspect_ipv6_routes "$fx/v6_default_route" "$fx/scratch" 2>&1 || true)" ]] || test_fail route_inspector_emits_output
test_pass route_inspectors_closed_fixtures

# --- independent-oracle fuzz of all three parsers ----------------------------
cat >"$tmp/fuzz_oracle.py" <<'PY'
import os, random, re, subprocess, sys, pathlib
work = pathlib.Path(sys.argv[1]); inspector = sys.argv[2]; n = int(sys.argv[3]); random.seed(int(sys.argv[4]))
H4 = b"Iface\tDestination\tGateway \tFlags\tRefCnt\tUse\tMetric\tMask\t\tMTU\tWindow\tIRTT" + b" " * 55 + b"\n"
Z = b"0" * 32
NULL6 = Z + b" 00 " + Z + b" 00 " + Z + b" ffffffff 00000001 00000000 00200200       lo\n"
LOC6 = b"0" * 31 + b"1 80 " + Z + b" 00 " + Z + b" 00000000 00000002 00000000 80200001       lo\n"
ROW4 = b"eth0\t00000000\t0100000A\t0003\t0\t0\t100\t00000000\t0\t0\t0\n"
DEF6 = Z + b" 00 " + Z + b" 00 fe800000000000000000000000000001 00000400 00000001 00000000 00000003     eth0\n"
ND1 = b"Inter-|   Receive                                                |  Transmit\n"
ND2 = b" face |bytes    packets errs drop fifo frame compressed multicast|bytes    packets errs drop fifo colls carrier compressed\n"
COLS = b"       0       0    0    0    0     0          0         0        0       0    0    0    0     0       0          0\n"
def ndrow(n): return (b"%6s:" % n) + COLS
seeds = {4: [H4, H4 + ROW4, H4 + ROW4 + ROW4], 6: [NULL6 + NULL6, NULL6 + LOC6 + NULL6, NULL6 + LOC6 + NULL6 + DEF6, LOC6],
         7: [ND1 + ND2 + ndrow(b"lo"), ND1 + ND2 + ndrow(b"lo") + ndrow(b"eth0"), ND1 + ND2 + ndrow(b"eth0"), ND1 + ND2]}
ALPHA = [b"\t", b" ", b"\r", b"\x0b", b"\x0c", b"\x00", b"\n", b"\n\n", b"0", b"f", b"F", b"g", b"\xff", b"\x1b", b"-", b"x", b":", b"|"]
def mutate(b):
    b = bytearray(b)
    for _ in range(random.choice([1, 1, 2, 3])):
        op = random.choice("idrtn"); pos = random.randrange(len(b) + 1)
        if op == "i": b[pos:pos] = random.choice(ALPHA)
        elif op == "d" and b: del b[min(pos, len(b) - 1)]
        elif op == "r" and b: b[min(pos, len(b) - 1)] = random.choice(ALPHA)[0]
        elif op == "t" and b: del b[random.randrange(len(b)):]
        elif op == "n": b += b"\n" * random.choice([1, 2, 3])
    return bytes(b)
def toks(line): return [t for t in re.split(r"[ \t]+", line) if t != ""]
def printable(raw): return re.fullmatch(rb"[\t\n\x20-\x7e]*", raw) is not None
def pre(raw, maxlines):
    if len(raw) == 0: return 3
    if len(raw) > 4096 or not printable(raw) or not raw.endswith(b"\n"): return 2
    return None
H11 = "Iface Destination Gateway Flags RefCnt Use Metric Mask MTU Window IRTT".split()
def o4(raw):
    r = pre(raw, 17)
    if r: return r
    lines = raw.decode().split("\n")[:-1]
    if len(lines) > 17 or toks(lines[0]) != H11: return 2
    bad = False
    for l in lines[1:]:
        t = toks(l); ok = len(t) == 11 and (re.fullmatch(r"[A-Za-z0-9_.@-]{1,15}", t[0]) or t[0] == "*") and all(re.fullmatch(r"[0-9A-F]{8}", t[i]) for i in (1, 2, 7)) and re.fullmatch(r"[0-9A-F]{4}", t[3]) and all(re.fullmatch(r"[0-9]+", t[i]) for i in (4, 5, 6, 8, 9, 10))
        bad = bad or not ok
    return 2 if bad else (1 if len(lines) > 1 else 0)
def o6(raw):
    r = pre(raw, 16)
    if r: return r
    lines = raw.decode().split("\n")[:-1]
    if len(lines) > 16: return 2
    bad = unexp = nulls = 0; z = "0" * 32
    for l in lines:
        t = toks(l)
        ok = len(t) == 10 and re.fullmatch(r"[0-9a-f]{32}", t[0]) and re.fullmatch(r"[0-9a-f]{2}", t[1]) and re.fullmatch(r"[0-9a-f]{32}", t[2]) and re.fullmatch(r"[0-9a-f]{2}", t[3]) and re.fullmatch(r"[0-9a-f]{32}", t[4]) and all(re.fullmatch(r"[0-9a-f]{8}", t[i]) for i in (5, 6, 7, 8)) and re.fullmatch(r"[A-Za-z0-9_.@-]{1,15}", t[9])
        if not ok: bad = 1; continue
        if t[0] == z and t[1] == "00" and t[2] == z and t[3] == "00" and t[4] == z and t[5] == "ffffffff" and t[8] == "00200200" and t[9] == "lo": nulls += 1; continue
        if t[0] == "0" * 31 + "1" and t[1] == "80" and t[2] == z and t[3] == "00" and t[4] == z and t[5] == "00000000" and t[8] == "80200001" and t[9] == "lo": continue
        unexp = 1
    return 2 if bad else (1 if unexp else (0 if nulls else 3))
def o7(raw):
    r = pre(raw, 18)
    if r: return r
    lines = raw.decode().split("\n")[:-1]
    if len(lines) < 3 or len(lines) > 18: return 2
    if not re.fullmatch(r"Inter-\|   Receive +\|  Transmit", lines[0]): return 2
    if not re.fullmatch(r" face \|bytes +packets errs drop fifo frame compressed multicast\|bytes +packets errs drop fifo colls carrier compressed", lines[1]): return 2
    names = []
    for l in lines[2:]:
        m = re.fullmatch(r" *([A-Za-z0-9_.@-]+):( *[0-9]+(?: +[0-9]+)* *)", l)
        if not m or len(m.group(1)) > 15 or len(m.group(2).split()) != 16: return 2
        names.append(m.group(1))
    return 0 if names == ["lo"] else 1
cases = []
d = work / "cases"; d.mkdir()
for i in range(n):
    fam = random.choice([4, 6, 7]); raw = random.choice(seeds[fam]); raw = mutate(raw) if random.random() < 0.92 else raw
    (d / f"{i}.{fam}").write_bytes(raw); cases.append((i, fam, raw))
drv = work / "driver.sh"
drv.write_text('source "$1"; scratch="$2/scratch"; mkdir -p "$scratch"\nfor f in "$2"/cases/*; do case "$f" in *.4) fn=inspect_ipv4_routes;; *.6) fn=inspect_ipv6_routes;; *) fn=inspect_net_dev;; esac; rc=0; $fn "$f" "$scratch" >/dev/null 2>&1 || rc=$?; echo "${f##*/} $rc"; done\n')
res = dict(l.split() for l in subprocess.run(["bash", str(drv), inspector, str(work)], capture_output=True, text=True).stdout.splitlines())
oracle = {4: o4, 6: o6, 7: o7}; false_pass = mismatches = 0; seen = {}
for i, fam, raw in cases:
    got = int(res[f"{i}.{fam}"]); want = oracle[fam](raw); seen[(fam, want)] = seen.get((fam, want), 0) + 1
    if got != want:
        mismatches += 1
        if got == 0: false_pass += 1
        print("MISMATCH", fam, "got", got, "want", want, repr(raw[:160]))
print(f"fuzz cases={n} mismatches={mismatches} false_pass={false_pass} distribution={dict(sorted(seen.items()))}")
sys.exit(1 if mismatches else 0)
PY
cat "$tmp/netdev-probe.sh" "$tmp/route-inspector.sh" >"$tmp/fuzz-inspectors.sh"
mkdir "$tmp/fuzzdir"
python3 -I "$tmp/fuzz_oracle.py" "$tmp/fuzzdir" "$tmp/fuzz-inspectors.sh" 160 20260101 >"$tmp/fuzz.out" 2>&1 || { cat "$tmp/fuzz.out" >&2; test_fail parser_fuzz_oracle_mismatch; }
grep -q 'false_pass=0' "$tmp/fuzz.out" || test_fail parser_fuzz_false_pass
test_pass parsers_match_independent_oracle_fuzz

# --- netlink negative classifier ---------------------------------------------
extract_marker_block NETWORK_CLASSIFIERS_BEGIN NETWORK_CLASSIFIERS_END "$tmp/probe.sh" "$tmp/network-classifiers.sh"
source "$tmp/network-classifiers.sh"
nl="$tmp/netlinkfx"; mkdir "$nl"
nl_msg='Cannot open netlink socket: Address family not supported by protocol'
printf '%s\n' "$nl_msg" >"$nl/exact"; : >"$nl/empty"; printf '%s\n' 'RTNETLINK answers: Operation not permitted' >"$nl/other"; printf '%s\n%s\n' "$nl_msg" extra >"$nl/extra"; printf '%s' "$nl_msg" >"$nl/no_lf"
ln -s exact "$nl/link"
expect_nl() { local rc_in="$1" file="$2" want="$3" rc=0; classify_netlink_result "$rc_in" "$nl/$file" || rc=$?; [[ "$rc" == "$want" ]] || test_fail "netlink_classifier_${rc_in}_${file}_got_${rc}_want_${want}"; }
expect_nl 1 exact 0; expect_nl 0 exact 1; expect_nl 0 empty 1; expect_nl 1 empty 2; expect_nl 1 other 2; expect_nl 1 extra 2; expect_nl 1 no_lf 2
expect_nl 2 exact 2; expect_nl 127 exact 2; expect_nl 124 exact 2; expect_nl 1 link 2; expect_nl 1 missing 2
test_pass netlink_denial_classifier_fail_closed

# --- check_network orchestration (all collaborators mocked) -------------------
awk '/^[[:space:]]*check_network\(\) \{/ {inside=1} /^[[:space:]]*check_netlink_denied\(\)/ {exit} inside {print}' "$tmp/probe.sh" >"$tmp/network-check.sh"
! grep -Eq '(^|[^_[:alnum:]])ip[[:space:]]+-[46]|command -v ip|/sys/class/net/' "$tmp/network-check.sh" || test_fail network_check_uses_ip_or_hardcoded_sysfs
source "$tmp/network-check.sh"
network_ok_ids=''; network_bad_ids=''; network_work="$tmp/network-check-work"; mkdir "$network_work"
WORK="$network_work"; net_calls="$tmp/net-calls"
ok() { network_ok_ids+=" $1"; }
bad() { network_bad_ids+=" $1:$2"; }
enumerate_network_interfaces() { return "${NET_SYS_RC:-0}"; }
inspect_net_dev() { return "${NET_DEV_RC:-0}"; }
inspect_ipv4_routes() { return "${NET_R4_RC:-0}"; }
inspect_ipv6_routes() { return "${NET_R6_RC:-0}"; }
ip() { test_fail network_check_called_ip; }
getent() { return 0; }
timeout() {
  local seconds="$1" command="$2"; shift 2
  printf '%s\n' "$command" >>"$net_calls"
  case "$command" in
    getent) [[ "$1" == hosts ]] && return 0 || return 2 ;;
    bash) printf '%s\n' 'bash: connect: Network is unreachable' >"$WORK/tcp.error"; return 1 ;;
    curl) return 7 ;;
    *) return 127 ;;
  esac
}
run_network() { network_ok_ids=''; network_bad_ids=''; : >"$net_calls"; NET_DEV_RC="$1" NET_SYS_RC="$2" NET_R4_RC="$3" NET_R6_RC="$4" check_network; }
count_id() { local id="$1" n=0 w; for w in $network_ok_ids; do [[ "$w" == "$id" ]] && n=$((n+1)); done; for w in $network_bad_ids; do [[ "${w%%:*}" == "$id" ]] && n=$((n+1)); done; printf '%s' "$n"; }
run_network 0 0 0 0
[[ "$network_ok_ids" == *' network_interfaces'* && "$network_ok_ids" == *' routes'* && "$network_ok_ids" == *' tcp_blocked'* && "$network_ok_ids" == *' https_blocked'* && -z "$network_bad_ids" ]] || test_fail network_clean_not_accepted
grep -Fxq bash "$net_calls" && grep -Fxq curl "$net_calls" || test_fail network_clean_skips_tcp_https
# interface verdict matrix: proc dev is the authority; sysfs only confirms/contradicts
for combo in '1 0|proc_unexpected' '2 0|proc_malformed' '3 0|proc_unavailable' '9 0|proc_unavailable' '1 1|proc_unexpected' '3 2|proc_unavailable' '0 1|sysfs_disagrees' '0 2|sysfs_inspection_error' '0 3|sysfs_inspection_error'; do
  codes="${combo%%|*}"; want="${combo#*|}"; set -- $codes; run_network "$1" "$2" 0 0
  [[ "$network_bad_ids" == *"network_interfaces:$want"* && "$network_ok_ids" != *' network_interfaces'* ]] || test_fail "network_interfaces_${1}_${2}_not_${want}"
  [[ "$network_bad_ids" == *'tcp_blocked:not_attempted_prerequisite'* && "$network_bad_ids" == *'https_blocked:not_attempted_prerequisite'* ]] || test_fail "network_interfaces_${1}_${2}_not_causal"
  ! grep -Eq '^(bash|curl)$' "$net_calls" || test_fail "network_interfaces_${1}_${2}_attempted_network"
done
# route verdict matrix (complementary evidence) with clean interfaces
for combo in '1 0|ipv4_present' '2 0|ipv4_malformed' '3 0|ipv4_query_error' '0 1|ipv6_unexpected' '0 2|ipv6_malformed' '0 3|ipv6_query_error' '1 1|ipv4_present' '3 3|ipv4_query_error' '2 1|ipv4_malformed' '0 9|ipv6_query_error'; do
  codes="${combo%%|*}"; want="${combo#*|}"; set -- $codes; run_network 0 0 "$1" "$2"
  [[ "$network_bad_ids" == *"routes:$want"* && "$network_ok_ids" != *' routes'* && "$network_ok_ids" == *' network_interfaces'* ]] || test_fail "network_routes_${1}_${2}_not_${want}"
  [[ "$network_bad_ids" == *'tcp_blocked:not_attempted_prerequisite'* && "$network_bad_ids" == *'https_blocked:not_attempted_prerequisite'* ]] || test_fail "network_routes_${1}_${2}_not_causal"
  ! grep -Eq '^(bash|curl)$' "$net_calls" || test_fail "network_routes_${1}_${2}_attempted_network"
done
# exactly one record per ID, whatever the evidence combination
for d in 0 1 2 3; do for s in 0 1 2; do for r4 in 0 1 3; do for r6 in 0 2; do
  run_network "$d" "$s" "$r4" "$r6"
  for id in network_interfaces routes dns_blocked tcp_blocked https_blocked; do [[ "$(count_id "$id")" == 1 ]] || test_fail "network_record_count_${id}_${d}_${s}_${r4}_${r6}"; done
done; done; done; done
# Routes only prove the IPv4 MAIN table: a route in another table is invisible to them,
# so the extra interface evidence is what keeps this NO-GO (and TCP/HTTPS unattempted).
run_network 1 0 0 0
[[ "$network_bad_ids" == *'network_interfaces:proc_unexpected'* && "$network_ok_ids" == *' routes'* && "$network_bad_ids" == *'tcp_blocked:not_attempted_prerequisite'* ]] || test_fail network_external_interface_not_gating
unset -f check_network enumerate_network_interfaces inspect_net_dev inspect_ipv4_routes inspect_ipv6_routes ip getent timeout ok bad run_network count_id
unset WORK
source "$tmp/netdev-probe.sh"; source "$tmp/route-inspector.sh"
test_pass network_orchestration_fail_closed

# --- check_netlink_denied (mocked collaborators) -----------------------------
awk '/^[[:space:]]*check_netlink_denied\(\) \{/ {inside=1} /^[[:space:]]*check_cgroups\(\)/ {exit} inside {print}' "$tmp/probe.sh" >"$tmp/netlink-check.sh"
[[ -s "$tmp/netlink-check.sh" ]] || test_fail check_netlink_denied_missing
source "$tmp/netlink-check.sh"
WORK="$tmp/netlink-work"; mkdir "$WORK"; nl_ids=''
ok() { nl_ids+=" ok:$1"; }; bad() { nl_ids+=" bad:$1:$2"; }
ip() { printf '%s\n' "$NL_STDERR" >&2; return "$NL_RC"; }
timeout() { shift; "$@"; }
NL_RC=1 NL_STDERR="$nl_msg"; nl_ids=''; check_netlink_denied; [[ "$nl_ids" == ' ok:netlink_denied' ]] || test_fail netlink_denied_not_ok
NL_RC=0 NL_STDERR=''; nl_ids=''; check_netlink_denied; [[ "$nl_ids" == ' bad:netlink_denied:allowed' ]] || test_fail netlink_allowed_not_flagged
NL_RC=1 NL_STDERR='something else'; nl_ids=''; check_netlink_denied; [[ "$nl_ids" == ' bad:netlink_denied:inconclusive' ]] || test_fail netlink_other_error_not_inconclusive
NL_RC=127 NL_STDERR=''; nl_ids=''; check_netlink_denied; [[ "$nl_ids" == ' bad:netlink_denied:inconclusive' ]] || test_fail netlink_exec_error_not_inconclusive
nl_ids=''; ( mkdir -p "$tmp/netlinkfx-empty-path"; PATH="$tmp/netlinkfx-empty-path"; unset -f ip; check_netlink_denied; [[ "$nl_ids" == ' bad:netlink_denied:tool_unavailable' ]] ) || test_fail netlink_missing_tool_not_flagged
unset -f ip timeout ok bad check_netlink_denied; unset WORK NL_RC NL_STDERR
test_pass netlink_denied_probe_fail_closed

# --- controller: effective AF restriction and independent net/dev view -------
extract_marker_block ADDRESS_FAMILY_VALIDATOR_BEGIN ADDRESS_FAMILY_VALIDATOR_END "$tmp/controller.sh" "$tmp/af-validator.sh"
source "$tmp/af-validator.sh"
af_expect() { local rc=0; validate_address_families_property "$1" >/dev/null 2>&1 || rc=$?; [[ "$rc" == "$2" ]] || test_fail "address_families_${3}_got_${rc}_want_${2}"; }
af_expect 'AF_UNIX AF_INET AF_INET6' 0 exact
af_expect 'AF_INET6 AF_UNIX AF_INET' 0 reordered
af_expect '  AF_UNIX   AF_INET AF_INET6 ' 0 extra_spaces
af_expect 'AF_UNIX AF_INET AF_INET6 AF_NETLINK' 1 plus_netlink
af_expect 'AF_UNIX AF_INET AF_NETLINK' 1 netlink_instead
af_expect '~AF_NETLINK' 1 deny_list
af_expect '~AF_UNIX AF_INET AF_INET6' 1 tilde_prefix
af_expect 'AF_UNIX AF_INET' 1 missing_one
af_expect 'AF_UNIX' 1 only_unix
af_expect '' 1 unrestricted_empty
af_expect 'AF_UNIX AF_UNIX AF_INET' 2 duplicate
af_expect 'AF_UNIX AF_INET AF_INET6 AF_PACKET' 1 plus_packet
af_expect 'AF_UNIX AF_INET AF_INET6'$'\n''AF_NETLINK' 2 multiline
af_expect 'af_unix af_inet af_inet6' 1 lowercase
af_expect 'none' 1 none
test_pass address_families_property_exact

extract_marker_block SERVICE_NET_DEV_VERIFIER_BEGIN SERVICE_NET_DEV_VERIFIER_END "$tmp/controller.sh" "$tmp/service-net-dev.sh"
source "$tmp/service-net-dev.sh"
pf="$tmp/procfx"; mkdir -p "$pf/self/ns" "$pf/123/ns" "$pf/123/net" "$pf/scratch"
ln -s 'net:[4026531840]' "$pf/self/ns/net"; ln -s 'net:[4026532999]' "$pf/123/ns/net"
printf '%s' "$head_lines$(nd_row lo)"$'\n' >"$pf/123/net/dev"
MAINPID_SEQ="$tmp/mainpid-seq"; printf '%s\n' 123 123 >"$MAINPID_SEQ"
show_value() { [[ "$2" == MainPID ]] || return 1; local first rest; first="$(head -n1 "$MAINPID_SEQ")"; printf '%s\n' "$first"; if [[ "$(wc -l <"$MAINPID_SEQ")" -gt 1 ]]; then tail -n +2 "$MAINPID_SEQ" >"$MAINPID_SEQ.next"; cat "$MAINPID_SEQ.next" >"$MAINPID_SEQ"; fi; }
svc_expect() { local rc=0; printf '%s\n' "${4:-123}" "${5:-123}" >"$MAINPID_SEQ"; verify_service_net_dev u "$1" "$pf" "$pf/scratch" >/dev/null 2>&1 || rc=$?; [[ "$rc" == "$2" ]] || test_fail "service_net_dev_${3}_got_${rc}_want_${2}"; }
svc_expect 123 0 lo_only
printf '%s' "$head_lines$(nd_row lo)"$'\n'"$(nd_row veth0)"$'\n' >"$pf/123/net/dev"; svc_expect 123 1 extra_interface
printf '%s' "$head_lines$(nd_row eth0)"$'\n' >"$pf/123/net/dev"; svc_expect 123 1 external_only
printf '%s' "$head_lines$(nd_row lo)"$'\n\n' >"$pf/123/net/dev"; svc_expect 123 2 trailing_blank
printf '%s' "$head_lines$(nd_row lo)" >"$pf/123/net/dev"; svc_expect 123 2 truncated
: >"$pf/123/net/dev"; svc_expect 123 2 empty
printf '%s' "$head_lines$(nd_row lo)"$'\n' >"$pf/123/net/dev"
svc_expect 124 2 pid_without_proc_entry
svc_expect abc 2 invalid_pid
svc_expect 123 2 mainpid_changed_before 456 123
svc_expect 123 2 mainpid_changed_after 123 456
svc_expect 123 2 mainpid_zero 0 0
ln -sfn 'net:[4026531840]' "$pf/123/ns/net"; svc_expect 123 2 same_namespace_as_controller
ln -sfn 'net:[4026532999]' "$pf/123/ns/net"
eval "real_inspect_net_dev() $(declare -f inspect_net_dev | tail -n +2)"
inspect_net_dev() { ln -sfn 'net:[4026533111]' "$pf/123/ns/net"; real_inspect_net_dev "$@"; }
svc_expect 123 2 namespace_changed_during_read
ln -sfn 'net:[4026532999]' "$pf/123/ns/net"; unset -f inspect_net_dev; eval "inspect_net_dev() $(declare -f real_inspect_net_dev | tail -n +2)"; unset -f real_inspect_net_dev
rm -f "$pf/123/ns/net"; svc_expect 123 2 namespace_link_missing
ln -s 'net:[4026532999]' "$pf/123/ns/net"
mv "$pf/123/net/dev" "$pf/123/net/dev.real"; ln -s dev.real "$pf/123/net/dev"; svc_expect 123 2 dev_is_symlink
unset -f show_value svc_expect
test_pass service_net_dev_independent_controller_view

# --- wiring: every new check is actually invoked and counted ----------------
probe_ids="$(grep -oE '(^|[^_[:alnum:]])(ok|bad) [a-z_0-9]+' "$tmp/probe.sh" | awk '{print $2}' | sort -u | tr '\n' ' ')"
parser_ids="$(sed -n '/local expected_ids=(/,/^[[:space:]]*)/p' "$tmp/controller.sh" | grep -v 'expected_ids=(\|^[[:space:]]*)' | tr -s ' \n' '\n' | grep -v '^$' | sort -u | tr '\n' ' ')"
[[ "$probe_ids" == "$parser_ids" ]] || test_fail "probe_record_ids_differ_from_controller_ids: [$probe_ids] vs [$parser_ids]"
parser_count="$(printf '%s\n' $parser_ids | grep -c .)"
[[ "$parser_count" == 26 && "$(grep -c 'readonly EXPECTED_RECORDS=26' "$tmp/controller.sh")" == 1 && "$(grep -c 'readonly EXPECTED_RECORDS=26' "$tmp/probe.sh")" == 1 ]] || test_fail record_count_not_consistent
grep -Fq 'inspect_net_dev /proc/self/net/dev "$WORK"' "$tmp/probe.sh" || test_fail probe_does_not_read_own_net_dev
grep -Fq 'inspect_ipv4_routes /proc/self/net/route "$WORK"' "$tmp/probe.sh" || test_fail probe_route4_wiring
grep -Fq 'inspect_ipv6_routes /proc/self/net/ipv6_route "$WORK"' "$tmp/probe.sh" || test_fail probe_route6_wiring
awk '/^[[:space:]]*check_network$/ {n=NR} /^[[:space:]]*check_netlink_denied$/ {d=NR} /^[[:space:]]*check_cgroups$/ {c=NR} END {exit !(n && d && c && n < d && d < c)}' "$tmp/probe.sh" || test_fail probe_call_order_network_netlink_cgroups
grep -Fq 'verify_service_net_dev "$MAIN_UNIT" "$main_pid" || net_dev_rc=$?' "$tmp/controller.sh" || test_fail controller_does_not_read_service_net_dev
for id in runtime_service_net_dev_lo_only runtime_service_net_dev_not_lo_only runtime_service_net_dev_verification_inconclusive runtime_service_net_dev_evidence_unavailable_after_probe_failure unit_address_families_effective unit_address_families_mismatch unit_address_families_inconclusive unit_address_families_query_error; do
  grep -Fq "'$id'" "$tmp/controller.sh" || test_fail "controller_missing_decision_$id"
done
grep -Fq 'validate_address_families_property "$address_families_property" || address_families_rc=$?' "$tmp/controller.sh" || test_fail controller_does_not_validate_address_families
grep -Fq 'show_value "$MAIN_UNIT" RestrictAddressFamilies' "$tmp/controller.sh" || test_fail controller_does_not_query_address_families
# a failed new decision must reach the NO-GO verdict: they use fail(), never a silent branch
! grep -E "^[[:space:]]*(0\)|1\)|\*\)).*(runtime_service_net_dev|unit_address_families)" "$tmp/controller.sh" | grep -v "pass '\|fail '" || test_fail controller_new_decision_without_pass_or_fail
# the netlink restriction is declared exactly once and in the effective profile
[[ "$(grep -c "RestrictAddressFamilies=" "$tmp/controller.sh")" == 1 ]] || test_fail address_families_declared_more_than_once
# no mention of any wider family in the profile
! grep -E "RestrictAddressFamilies=.*(NETLINK|PACKET|VSOCK|BLUETOOTH|ALG)" "$workflow" || test_fail wider_address_family
# the Part A hash covers the new parsers and both commitments agree with the staged text
for marker in NETDEV_INSPECTOR_BEGIN ROUTE_INSPECTOR_BEGIN RUN_MOUNT_DIAGNOSTIC_BEGIN; do grep -Fq "$marker" "$tmp/probe-a.sh" || test_fail "part_a_hash_does_not_cover_$marker"; done
# route files must stay documented as partial, and the runbook must not claim full table coverage
grep -Fq 'COMPLEMENTARY' "$tmp/route-inspector.sh" && grep -Fq 'IPv4 MAIN' "$tmp/route-inspector.sh" || test_fail route_inspector_scope_not_stated
grep -Fq 'Network isolation: proven versus inferred' "$repo_root/docs/VM-SYSTEMD-PREFLIGHT-RUNBOOK.md" || test_fail runbook_network_section_missing
! grep -Eiq 'every (IPv4|IPv6) row is a route|no IPv4/IPv6 routes' "$repo_root/docs/VM-SYSTEMD-PREFLIGHT-RUNBOOK.md" || test_fail runbook_overclaims_route_coverage
grep -Fq 'Known open gate: timeout canary cgroup observation (BLOCKING)' "$repo_root/docs/VM-SYSTEMD-PREFLIGHT-RUNBOOK.md" || test_fail runbook_cgroup_block_missing
test_pass probe_controller_wiring_and_documentation_guards

# --- negative controls under the real mechanisms (this kernel only) ----------
# A netlink-denying seccomp filter makes legacy `ip route` fail with the exact
# EAFNOSUPPORT message (classified "denied"), without the filter it succeeds
# (classified "allowed"); the new inspectors keep working under the filter, under
# hidepid + subset=pid /proc and in a namespace holding only lo (and see an extra
# dummy interface when one is added).  Needs unprivileged user/net/mount/pid
# namespaces; otherwise INCONCLUSIVE, never PASS.
cat >"$tmp/deny_netlink.py" <<'PY'
import ctypes, os, struct, sys
libc = ctypes.CDLL(None, use_errno=True)
def ins(code, jt, jf, k): return struct.pack("HBBI", code, jt, jf, k)
prog = b"".join([ins(0x20,0,0,4), ins(0x15,1,0,0xc000003e), ins(0x06,0,0,0x7fff0000),
                 ins(0x20,0,0,0), ins(0x15,0,3,41), ins(0x20,0,0,16), ins(0x15,0,1,16),
                 ins(0x06,0,0,0x00050000|97), ins(0x06,0,0,0x7fff0000)])
buf = ctypes.create_string_buffer(prog)
class Fprog(ctypes.Structure): _fields_ = [("len", ctypes.c_ushort), ("filter", ctypes.c_void_p)]
fp = Fprog(len(prog)//8, ctypes.addressof(buf))
assert libc.prctl(38, 1, 0, 0, 0) == 0 and libc.prctl(22, 2, ctypes.byref(fp)) == 0
os.execvp(sys.argv[1], sys.argv[1:])
PY
cat >"$tmp/ns_probe.sh" <<'NS'
set -u
source "$1"; scratch="$2"
rc4=0; inspect_ipv4_routes /proc/self/net/route "$scratch" || rc4=$?
rc6=0; inspect_ipv6_routes /proc/self/net/ipv6_route "$scratch" || rc6=$?
dev=0; inspect_net_dev /proc/self/net/dev "$scratch" || dev=$?
ip_rc=0; ip -4 route show >/dev/null 2>"$scratch/ip.err" || ip_rc=$?
nl=0; classify_netlink_result "$ip_rc" "$scratch/ip.err" || nl=$?
printf '%s %s %s %s\n' "$rc4" "$rc6" "$dev" "$nl"
NS
cat >"$tmp/ns_setup.sh" <<'NS'
set -u
ip link set lo up || exit 70
mount -t proc -o subset=pid,hidepid=invisible proc /proc || exit 71
[[ ! -e /proc/net/route ]] || exit 72
[[ "${3:-}" != extra ]] || ip link add dummy0 type dummy || exit 73
if [[ "${4:-}" == filter ]]; then exec python3 "$1" bash "$2" "$5" "$6"; fi
exec bash "$2" "$5" "$6"
NS
mkdir "$tmp/ns-scratch"
cat "$tmp/netdev-probe.sh" "$tmp/route-inspector.sh" "$tmp/network-classifiers.sh" >"$tmp/ns-inspectors.sh"
run_ns() { timeout 30 unshare -rnmpf bash "$tmp/ns_setup.sh" "$tmp/deny_netlink.py" "$tmp/ns_probe.sh" "$1" "$2" "$tmp/ns-inspectors.sh" "$tmp/ns-scratch" 2>/dev/null; }
ns_rc=0; ns_filtered="$(run_ns clean filter)" || ns_rc=$?
if [[ "$ns_rc" == 0 ]]; then
  [[ "$ns_filtered" == '0 0 0 0' ]] || test_fail "mechanism_filtered_unexpected_$ns_filtered"
  ns_open="$(run_ns clean nofilter)" || test_fail mechanism_unfiltered_failed
  [[ "$ns_open" == '0 0 0 1' ]] || test_fail "mechanism_unfiltered_unexpected_$ns_open"
  ns_extra="$(run_ns extra nofilter)" || test_fail mechanism_extra_failed
  [[ "$ns_extra" == '0 0 1 1' ]] || test_fail "mechanism_extra_interface_unexpected_$ns_extra"
  test_pass netlink_denial_and_lo_only_namespace_mechanisms_on_this_kernel
else
  inconclusive_count=$(( ${inconclusive_count:-0} + 1 ))
  printf 'INCONCLUSIVE mechanism_namespaces_unavailable rc=%s\n' "$ns_rc"
fi


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

# A path made inaccessible below /run can legitimately cause a runtime mount,
# but it remains NO-GO until its exact representation is independently proven.
make_mountinfo "$tmp/mount-known-inaccessible" "$valid_run"
printf '%s\n' '26 25 0:46 /run/systemd/inaccessible/reg /run/docker.sock ro,nosuid,nodev,noexec - tmpfs tmpfs ro,size=1024k' >>"$tmp/mount-known-inaccessible"
if validate_run_mountinfo "$tmp/mount-known-inaccessible" >/dev/null 2>&1; then test_fail run_mount_accepted_known_inaccessible_submount; fi
printf '%s\n' 'malformed' >"$tmp/mount-malformed"
set +e; validate_run_mountinfo "$tmp/mount-malformed" >/dev/null; rc=$?; set -e
[[ "$rc" == 2 ]] || test_fail run_mount_malformed_not_inconclusive
set +e; validate_run_mountinfo "$tmp/missing-mountinfo" >/dev/null; rc=$?; set -e
[[ "$rc" == 2 ]] || test_fail run_mount_unavailable_not_inconclusive
test_pass run_mountinfo_closed_validation

# The diagnostic is strictly informational: even a restrictive submount is not
# accepted by the approval validator, and nothing but "no submount" can PASS.
# Classification is derived from properties (target identity, filesystem type,
# mount source, root, flags, propagation, effective access), never from who
# probably created the mount.  Public codes are a closed grammar.
extract_marker_block RUN_MOUNT_DIAGNOSTIC_BEGIN RUN_MOUNT_DIAGNOSTIC_END "$tmp/probe.sh" "$tmp/run-mount-diagnostic.sh"
source "$tmp/run-mount-diagnostic.sh"
PRIVATE_ROOT=/run/ti0093-vm-preflight
mock_access() { case "${MOCK_ACCESS:-denied}" in denied) return 0 ;; open) return 1 ;; *) return 2 ;; esac; }
sub() { # sub ROOT TARGET OPTS FSTYPE SOURCE [OPTIONAL_FIELDS]
  printf '26 25 0:46 %s %s %s %s- %s %s ro,size=0k\n' "$1" "$2" "$3" "${6:+$6 }" "$4" "$5"
}
restrictive_opts='ro,nosuid,nodev,noexec,relatime'
diag_grammar='^(no_submount|(sockets|private_root|run_user|mixed_expected)_(restrictive|not_restrictive_[01]{9})|unexpected_target_(systemd|user_child|private_root_child|credentials|lock|other)|evidence_incomplete)$'
diag_case() { # name expected access mountline...
  local name="$1" expected="$2" access="$3" got line; shift 3
  make_mountinfo "$tmp/diag-$name" "$valid_run"
  for line in "$@"; do printf '%s\n' "$line" >>"$tmp/diag-$name"; done
  got="$(MOCK_ACCESS="$access" diagnose_run_mountinfo "$tmp/diag-$name" mock_access)" || test_fail "run_diag_${name}_rc"
  [[ "$got" == "$expected" ]] || test_fail "run_diag_${name}_got_${got}_want_${expected}"
  # Every submount, restrictive or not, stays NO-GO for the approval validator.
  if [[ "$expected" != no_submount ]] && validate_run_mountinfo "$tmp/diag-$name" >/dev/null 2>&1; then test_fail "run_validator_accepted_$name"; fi
  [[ "$got" =~ $diag_grammar ]] || test_fail "run_diag_${name}_outside_grammar"
  [[ "$got" != */* && "$got" != *ti0093* && ${#got} -le 48 ]] || test_fail "run_diag_${name}_leaks_or_oversize"
}
dir_root=/systemd/inaccessible/dir; sock_root=/systemd/inaccessible/sock
diag_case none no_submount denied
diag_case outside_run no_submount denied '27 24 0:50 / /var/lib/x rw - ext4 /dev/sda1 rw'
diag_case private_root private_root_restrictive denied "$(sub $dir_root $PRIVATE_ROOT $restrictive_opts tmpfs tmpfs)"
diag_case run_user run_user_restrictive denied "$(sub $dir_root /run/user $restrictive_opts tmpfs tmpfs)"
diag_case docker sockets_restrictive denied "$(sub $sock_root /run/docker.sock $restrictive_opts tmpfs tmpfs)"
diag_case all_six sockets_restrictive denied \
  "$(sub $sock_root /run/docker.sock $restrictive_opts tmpfs tmpfs)" "$(sub $sock_root /run/systemd/private $restrictive_opts tmpfs tmpfs)" \
  "$(sub $sock_root /run/dbus/system_bus_socket $restrictive_opts tmpfs tmpfs)" "$(sub $sock_root /run/containerd/containerd.sock $restrictive_opts tmpfs tmpfs)" \
  "$(sub $sock_root /run/snapd.socket $restrictive_opts tmpfs tmpfs)" "$(sub $sock_root /run/udev/control $restrictive_opts tmpfs tmpfs)"
diag_case mixed mixed_expected_restrictive denied "$(sub $dir_root $PRIVATE_ROOT $restrictive_opts tmpfs tmpfs)" "$(sub $dir_root /run/user $restrictive_opts tmpfs tmpfs)"
# One reason bit per observed property: b1 root "/", b2 wrong inaccessible kind, b3 root unrecognised,
# b4 fstype, b5 source, b6 flags, b7 propagation, b8 stacked, b9 accessible.
diag_case root_slash private_root_not_restrictive_100000000 denied "$(sub / $PRIVATE_ROOT $restrictive_opts tmpfs tmpfs)"
diag_case wrong_kind private_root_not_restrictive_010000000 denied "$(sub $sock_root $PRIVATE_ROOT $restrictive_opts tmpfs tmpfs)"
diag_case sock_as_dir sockets_not_restrictive_010000000 denied "$(sub $dir_root /run/docker.sock $restrictive_opts tmpfs tmpfs)"
diag_case other_inaccessible_kind run_user_not_restrictive_010000000 denied "$(sub /systemd/inaccessible/reg /run/user $restrictive_opts tmpfs tmpfs)"
diag_case root_unrecognised run_user_not_restrictive_001000000 denied "$(sub /x /run/user $restrictive_opts tmpfs tmpfs)"
diag_case no_ro run_user_not_restrictive_000001000 denied "$(sub $dir_root /run/user rw,nosuid,nodev,noexec tmpfs tmpfs)"
diag_case no_nosuid run_user_not_restrictive_000001000 denied "$(sub $dir_root /run/user ro,nodev,noexec tmpfs tmpfs)"
diag_case no_nodev run_user_not_restrictive_000001000 denied "$(sub $dir_root /run/user ro,nosuid,noexec tmpfs tmpfs)"
diag_case no_noexec run_user_not_restrictive_000001000 denied "$(sub $dir_root /run/user ro,nosuid,nodev tmpfs tmpfs)"
diag_case rw_and_ro run_user_not_restrictive_000001000 denied "$(sub $dir_root /run/user ro,rw,nosuid,nodev,noexec tmpfs tmpfs)"
diag_case ext4 run_user_not_restrictive_000100000 denied "$(sub $dir_root /run/user $restrictive_opts ext4 tmpfs)"
diag_case host_source run_user_not_restrictive_000010000 denied "$(sub $dir_root /run/user $restrictive_opts tmpfs /dev/sda1)"
diag_case propagation run_user_not_restrictive_000000100 denied "$(sub $dir_root /run/user $restrictive_opts tmpfs tmpfs shared:7)"
diag_case stacked run_user_not_restrictive_000000010 denied "$(sub $dir_root /run/user $restrictive_opts tmpfs tmpfs)" "$(sub $dir_root /run/user $restrictive_opts tmpfs tmpfs)"
diag_case access_open private_root_not_restrictive_000000001 open "$(sub $dir_root $PRIVATE_ROOT $restrictive_opts tmpfs tmpfs)"
diag_case combined private_root_not_restrictive_100100101 open "$(sub / $PRIVATE_ROOT ro,nosuid,nodev,noexec ext4 tmpfs shared:1)"
diag_case union_over_mounts mixed_expected_not_restrictive_100001000 denied "$(sub / $PRIVATE_ROOT $restrictive_opts tmpfs tmpfs)" "$(sub $dir_root /run/user rw tmpfs tmpfs)"
diag_case access_unproven evidence_incomplete inconclusive "$(sub $dir_root $PRIVATE_ROOT $restrictive_opts tmpfs tmpfs)"
diag_case property_beats_unproven private_root_not_restrictive_100000000 inconclusive "$(sub / $PRIVATE_ROOT $restrictive_opts tmpfs tmpfs)"
diag_case unproven_with_clean_other evidence_incomplete inconclusive "$(sub $dir_root $PRIVATE_ROOT $restrictive_opts tmpfs tmpfs)" "$(sub $dir_root /run/user $restrictive_opts tmpfs tmpfs)"
# Unknown targets and look-alikes are never reclassified as expected; the family is a static dictionary token.
unexpected_expect() { # target family
  local safe="${1//[^a-zA-Z0-9]/_}"
  diag_case "unexpected_$safe" "unexpected_target_$2" denied "$(sub $dir_root "$1" $restrictive_opts tmpfs tmpfs)"
  diag_case "unexpected_open_$safe" "unexpected_target_$2" open "$(sub $dir_root "$1" $restrictive_opts tmpfs tmpfs)"
}
unexpected_expect /run/foo other; unexpected_expect /run/user2 other; unexpected_expect /run/userx other; unexpected_expect /run/docker.sockx other
unexpected_expect /run/docker.sock/x other; unexpected_expect "${PRIVATE_ROOT}x" other; unexpected_expect '/run/user\040x' other; unexpected_expect '/run/../etc' other
unexpected_expect /run/user/1000 user_child; unexpected_expect /run/user/ user_child; unexpected_expect "$PRIVATE_ROOT/child" private_root_child
unexpected_expect /run/systemd systemd; unexpected_expect /run/systemd/private/x systemd; unexpected_expect /run/systemd/inaccessible systemd
unexpected_expect /run/credentials credentials; unexpected_expect /run/credentials/svc credentials; unexpected_expect /run/lock lock; unexpected_expect /run/lock/subsys lock
diag_case family_precedence unexpected_target_systemd denied "$(sub / /run/lock/x rw tmpfs tmpfs)" "$(sub / /run/systemd/x rw tmpfs tmpfs)" "$(sub / /run/foo rw tmpfs tmpfs)"
diag_case unexpected_beats_expected unexpected_target_other denied "$(sub $dir_root /run/user $restrictive_opts tmpfs tmpfs)" "$(sub / /run/foo rw tmpfs tmpfs)"
diag_case unexpected_beats_unproven unexpected_target_other inconclusive "$(sub $dir_root /run/user $restrictive_opts tmpfs tmpfs)" "$(sub / /run/foo rw tmpfs tmpfs)"
# Malformed or unreadable evidence is inconclusive, not a classification.
for bad in 'malformed' '26 25 x:1 / /run/user ro - tmpfs tmpfs ro' '26 25 0:46 / /run/user ro tmpfs tmpfs ro' '26 25 0:46 / /run/user'; do
  printf '%s\n' "$valid_run" "$bad" >"$tmp/diag-malformed"
  rc=0; out="$(diagnose_run_mountinfo "$tmp/diag-malformed" mock_access)" || rc=$?
  [[ "$rc" == 2 && -z "$out" ]] || test_fail run_diag_malformed_not_inconclusive
done
rc=0; diagnose_run_mountinfo "$tmp/missing-mountinfo" mock_access >/dev/null || rc=$?; [[ "$rc" == 2 ]] || test_fail run_diag_missing_not_inconclusive
ln -s "$tmp/diag-none" "$tmp/diag-symlink"; rc=0; diagnose_run_mountinfo "$tmp/diag-symlink" mock_access >/dev/null || rc=$?; [[ "$rc" == 2 ]] || test_fail run_diag_symlink_not_inconclusive

# Independent oracle (Python) for the whole classification, over random mountinfo.
cat >"$tmp/diag_oracle.py" <<'PY'
import random, re, subprocess, sys, pathlib
work = pathlib.Path(sys.argv[1]); script = sys.argv[2]; n = int(sys.argv[3]); random.seed(int(sys.argv[4]))
ROOT = "/run/ti0093-vm-preflight"
SOCK = {"/run/docker.sock", "/run/systemd/private", "/run/dbus/system_bus_socket", "/run/containerd/containerd.sock", "/run/snapd.socket", "/run/udev/control"}
targets = list(SOCK) + ["/run/user", "/run/user/", "/run/user/0", "/run/userx", ROOT, ROOT + "/x", ROOT + "x", "/run/foo", "/run/systemd", "/run/systemd/x", "/run/credentials/a", "/run/lock", "/run/lock/x", "/run", "/runx", "/run/", "/var/run/docker.sock", "/run/a\\040b", "/RUN/user", "/run//user", "/run/docker.sockx"]
roots = ["/", "/systemd/inaccessible/dir", "/systemd/inaccessible/sock", "/systemd/inaccessible/reg", "/x", "/systemd/inaccessible/dir/"]
optsets = ["ro,nosuid,nodev,noexec", "ro,nosuid,nodev,noexec,relatime", "rw,nosuid,nodev", "ro", "ro,nosuid,nodev,noexec,rw", "ro,nosuid,noexec", "rw"]
fs = ["tmpfs", "ext4", "overlay"]; srcs = ["tmpfs", "tmpfs", "/dev/sda1"]; opts_opt = ["", "", "", "shared:3 ", "master:2 ", "unbindable "]
def has(o, w): return w in o.split(",")
def expected(mounts, accesses):
    total = 0; fams = set(); sets = set(); agg = [0] * 9; seen = {}
    for (root, target, opts, f, src, opt) in mounts:
        if not target.startswith("/run/"): continue
        total += 1
        if target in SOCK: cls, kind = "sockets", "sock"
        elif target == ROOT: cls, kind = "private_root", "dir"
        elif target == "/run/user": cls, kind = "run_user", "dir"
        else:
            if target == "/run/systemd" or target.startswith("/run/systemd/"): fams.add("systemd")
            elif target.startswith("/run/user/"): fams.add("user_child")
            elif target.startswith(ROOT + "/"): fams.add("private_root_child")
            elif target == "/run/credentials" or target.startswith("/run/credentials/"): fams.add("credentials")
            elif target == "/run/lock" or target.startswith("/run/lock/"): fams.add("lock")
            else: fams.add("other")
            continue
        sets.add(cls); want = "/systemd/inaccessible/" + kind
        b = [root == "/", bool(re.fullmatch(r"/systemd/inaccessible/(reg|dir|sock|chr|blk|fifo)", root)) and root != want, False, f != "tmpfs", src != "tmpfs",
             not (has(opts, "ro") and has(opts, "nosuid") and has(opts, "nodev") and has(opts, "noexec")) or has(opts, "rw"), opt != "", False]
        b[2] = not (b[0] or b[1] or root == want)
        seen[target] = seen.get(target, 0) + 1; b[7] = seen[target] > 1
        for i, v in enumerate(b): agg[i] |= int(v)
        if accesses == "open": agg[8] = 1
    if total == 0: return "no_submount"
    for fam in ["systemd", "user_child", "private_root_child", "credentials", "lock", "other"]:
        if fam in fams: return "unexpected_target_" + fam
    name = "mixed_expected" if len(sets) > 1 else sorted(sets)[0]
    if any(agg): return name + "_not_restrictive_" + "".join(map(str, agg))
    if accesses == "inconclusive": return "evidence_incomplete"
    return name + "_restrictive"
d = work / "cases"; d.mkdir(); cases = []
for i in range(n):
    mounts = []; lines = ["24 1 0:20 / / rw,relatime - overlay overlay rw", "25 24 0:45 / /run ro,nosuid,nodev,noexec,relatime - tmpfs tmpfs rw,size=1024k"]
    for _ in range(random.choice([0, 1, 1, 2, 3, 4])):
        m = (random.choice(roots), random.choice(targets), random.choice(optsets), random.choice(fs), random.choice(srcs), random.choice(opts_opt)); mounts.append(m)
        lines.append(f"{random.randint(26,900)} 25 0:{random.randint(46,99)} {m[0]} {m[1]} {m[2]} {m[5]}- {m[3]} {m[4]} ro,size=0k")
    mounts = [m for m in mounts if not (m[1] in ("/run", "/runx", "/RUN/user", "/var/run/docker.sock", "/run//user", "/run/a\\040b") and not m[1].startswith("/run/"))]
    access = random.choice(["denied", "denied", "open", "inconclusive"])
    (d / f"{i}.{access}").write_text("\n".join(lines) + "\n"); cases.append((i, access, mounts))
drv = work / "driver.sh"
drv.write_text('source "$1"; PRIVATE_ROOT=/run/ti0093-vm-preflight\nmock_access() { case "$MOCK" in denied) return 0;; open) return 1;; *) return 2;; esac; }\nfor f in "$2"/cases/*; do MOCK="${f##*.}"; rc=0; out="$(diagnose_run_mountinfo "$f" mock_access)" || rc=$?; echo "${f##*/} $rc $out"; done\n')
res = {l.split()[0]: l.split()[1:] for l in subprocess.run(["bash", str(drv), script, str(work)], capture_output=True, text=True).stdout.splitlines()}
bad = 0; dist = {}
for i, access, mounts in cases:
    rc, *out = res[f"{i}.{access}"]; got = out[0] if out else ""; want = expected(mounts, access)
    dist[want.split("_not_restrictive")[0]] = dist.get(want.split("_not_restrictive")[0], 0) + 1
    if rc != "0" or got != want: bad += 1; print("MISMATCH", i, access, "rc", rc, "got", got, "want", want, mounts)
print(f"diag fuzz cases={n} mismatches={bad} distribution={dict(sorted(dist.items()))}")
sys.exit(1 if bad else 0)
PY
mkdir "$tmp/diagfuzz"
python3 -I "$tmp/diag_oracle.py" "$tmp/diagfuzz" "$tmp/run-mount-diagnostic.sh" 160 20260102 >"$tmp/diag-fuzz.out" 2>&1 || { cat "$tmp/diag-fuzz.out" >&2; test_fail run_diag_oracle_mismatch; }

# Effective-access probe: real permission bits on disposable paths.  Root
# bypasses mode bits, so this part is INCONCLUSIVE when run as root.
if [[ "$(id -u)" != 0 ]]; then
  access_fx="$tmp/accessfx"; mkdir "$access_fx" "$access_fx/d_denied" "$access_fx/d_open"
  chmod 000 "$access_fx/d_denied"; chmod 755 "$access_fx/d_open"
  : >"$access_fx/f_denied"; chmod 000 "$access_fx/f_denied"; : >"$access_fx/f_open"; chmod 644 "$access_fx/f_open"
  rc=0; run_access_denied dir "$access_fx/d_denied" || rc=$?; [[ "$rc" == 0 ]] || test_fail run_access_dir_denied
  rc=0; run_access_denied dir "$access_fx/d_open" || rc=$?; [[ "$rc" == 1 ]] || test_fail run_access_dir_open
  rc=0; run_access_denied sock "$access_fx/f_denied" || rc=$?; [[ "$rc" == 0 ]] || test_fail run_access_sock_denied
  rc=0; run_access_denied sock "$access_fx/f_open" || rc=$?; [[ "$rc" == 1 ]] || test_fail run_access_sock_open
  rc=0; run_access_denied dir "$access_fx/absent" || rc=$?; [[ "$rc" == 2 ]] || test_fail run_access_absent_not_inconclusive
  rc=0; run_access_denied other "$access_fx/f_open" || rc=$?; [[ "$rc" == 2 ]] || test_fail run_access_unknown_kind
  chmod 755 "$access_fx/d_denied"; chmod 644 "$access_fx/f_denied"
else
  inconclusive_count=$(( ${inconclusive_count:-0} + 1 ))
  printf '%s\n' 'INCONCLUSIVE run_access_permission_bits_running_as_root'
fi

# Mapping to the public record and to the controller's closed vocabulary.
awk '/^[[:space:]]*check_run_mount_diagnostic\(\) \{/ {inside=1} /^[[:space:]]*# INTERFACE_ENUMERATOR_BEGIN/ {exit} inside {print}' "$tmp/probe.sh" >"$tmp/check-run-diag.sh"
[[ -s "$tmp/check-run-diag.sh" ]] || test_fail check_run_mount_diagnostic_missing
source "$tmp/check-run-diag.sh"
diag_ok=''; diag_bad=''
ok() { diag_ok+=" $1"; }
bad() { diag_bad+=" $1:${2:-}"; }
sets=(sockets private_root run_user mixed_expected); valid_codes=(evidence_incomplete)
for s in "${sets[@]}"; do valid_codes+=("${s}_restrictive"); done
for s in "${sets[@]}"; do for ((n=1; n<512; n++)); do b=''; for ((i=8; i>=0; i--)); do b+=$(( (n >> i) & 1 )); done; valid_codes+=("${s}_not_restrictive_${b}"); done; done
for f in systemd user_child private_root_child credentials lock other; do valid_codes+=("unexpected_target_$f"); done
for code in "${valid_codes[@]}"; do
  diag_ok=''; diag_bad=''; diagnose_run_mountinfo() { printf '%s' "$code"; }
  check_run_mount_diagnostic
  [[ -z "$diag_ok" && "$diag_bad" == " run_mount_diagnostic:$code" ]] || test_fail "run_diag_mapping_$code"
  public_category_allowed run_mount_diagnostic "$code" || test_fail "run_diag_code_not_in_public_grammar_$code"
  case "$code" in *_not_restrictive_*) b="${code##*_}"; (( 2#$b == 511 || (2#$b & (2#$b - 1)) == 0 )) || continue ;; esac
  publish_failure_categories probe_ready_failure_categories "run_mount_diagnostic=$code" >/dev/null || test_fail "run_diag_code_not_in_public_vocabulary_$code"
done
diag_ok=''; diag_bad=''; diagnose_run_mountinfo() { printf no_submount; }; check_run_mount_diagnostic
[[ "$diag_ok" == ' run_mount_diagnostic' && -z "$diag_bad" ]] || test_fail run_diag_mapping_none
hostile=(unknown_code '/run/secret' known_submount_restrictive unexpected_submount unexpected_target sockets_not_restrictive private_root_not_restrictive_00000000 private_root_not_restrictive_0000000000 private_root_not_restrictive_00000000x run_user_not_restrictive_1 'private_root_restrictive extra' unexpected_target_systemd2 unexpected_target_ Unexpected_target_other '')
for h in "${hostile[@]}"; do
  diag_ok=''; diag_bad=''; diagnose_run_mountinfo() { printf '%s' "$h"; }; check_run_mount_diagnostic
  [[ -z "$diag_ok" && "$diag_bad" == ' run_mount_diagnostic:inspection_error' ]] || test_fail "run_diag_mapping_hostile_${h//[^a-z0-9]/_}"
  if publish_failure_categories probe_ready_failure_categories "run_mount_diagnostic=$h" >/dev/null 2>&1; then test_fail "hostile_category_publishable_${h//[^a-z0-9]/_}"; fi
done
diag_ok=''; diag_bad=''; diagnose_run_mountinfo() { return 2; }; check_run_mount_diagnostic
[[ -z "$diag_ok" && "$diag_bad" == ' run_mount_diagnostic:inspection_error' ]] || test_fail run_diag_mapping_rc2
unset -f ok bad diagnose_run_mountinfo
extract_marker_block RUN_MOUNT_DIAGNOSTIC_BEGIN RUN_MOUNT_DIAGNOSTIC_END "$tmp/probe.sh" "$tmp/run-mount-diagnostic.sh"; source "$tmp/run-mount-diagnostic.sh"
# Retired vocabulary, other ids and malformed pairs are never publishable.
for stale in run_mount_diagnostic=known_submount_restrictive run_mount_diagnostic=known_submount_incompatible run_mount_diagnostic=unexpected_submount routes=tool_unavailable routes=present network_interfaces=unexpected network_interfaces=inspection_error cgroup_memory=mismatch identity=secret; do
  if publish_failure_categories probe_ready_failure_categories "$stale" >/dev/null 2>&1; then test_fail "stale_category_publishable_${stale//[^a-z]/_}"; fi
done
for emitted in $(grep -o 'bad routes [a-z0-9_]*' "$tmp/probe.sh" | awk '{print $3}' | sort -u); do
  publish_failure_categories probe_ready_failure_categories "routes=$emitted" >/dev/null || test_fail "route_code_not_public_$emitted"
done
for emitted in $(grep -o 'bad network_interfaces [a-z0-9_]*' "$tmp/probe.sh" | awk '{print $3}' | sort -u); do
  publish_failure_categories probe_ready_failure_categories "network_interfaces=$emitted" >/dev/null || test_fail "network_interfaces_code_not_public_$emitted"
done
for emitted in $(grep -o 'bad netlink_denied [a-z0-9_]*' "$tmp/probe.sh" | awk '{print $3}' | sort -u); do
  publish_failure_categories probe_ready_failure_categories "netlink_denied=$emitted" >/dev/null || test_fail "netlink_code_not_public_$emitted"
done
# Cardinality: up to eight pairs, never nine; always <= 512 characters.
publish_failure_categories probe_final_failure_categories 'run_mount_diagnostic=mixed_expected_not_restrictive_111111111,network_interfaces=sysfs_inspection_error,routes=ipv4_query_error,netlink_denied=tool_unavailable,tcp_blocked=not_attempted_prerequisite,https_blocked=not_attempted_prerequisite' >/dev/null || test_fail category_six_pairs_rejected
if publish_failure_categories probe_final_failure_categories 'a=b,c=d' >/dev/null 2>&1; then test_fail category_unknown_ids_accepted; fi
test_pass run_mount_diagnostic_closed_classification

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

# Runtime observations are tri-state: a same namespace/mount or residual
# process is a failure, while a vanished PID or unavailable cgroup is an
# inconclusive NO-GO.  Neither condition can become a pass.
extract_marker_block RUNTIME_LIFECYCLE_VERIFIERS_BEGIN RUNTIME_LIFECYCLE_VERIFIERS_END "$tmp/controller.sh" "$tmp/runtime-lifecycle.sh"
source "$tmp/runtime-lifecycle.sh"
set +e; verify_runtime_namespaces 99999999; rc=$?; set -e
[[ "$rc" == 2 ]] || test_fail runtime_namespace_missing_pid_not_inconclusive
cgroup_empty="$tmp/cgroup-empty.procs"
cgroup_pids="$tmp/cgroup-pids.procs"
cgroup_bad="$tmp/cgroup-malformed.procs"
: >"$cgroup_empty"
printf '%s\n%s\n' 101 202 >"$cgroup_pids"
printf '%s\n' not-a-pid >"$cgroup_bad"
cgroup_procs_is_empty "$cgroup_empty" || test_fail cgroup_empty_rejected
# A cgroup-v2 pseudo-file can advertise size zero while yielding PIDs.  The
# real helper deliberately never calls stat; this fixture makes a fake zero
# size visible only to prove that metadata cannot influence the result.
stat() { [[ "${*: -1}" == "$cgroup_pids" ]] && { printf '0\n'; return 0; }; command stat "$@"; }
[[ "$(stat -Lc '%s' -- "$cgroup_pids")" == 0 ]] || test_fail cgroup_zero_size_fixture
set +e; cgroup_procs_is_empty "$cgroup_pids"; rc=$?; set -e
[[ "$rc" == 1 ]] || test_fail cgroup_zero_size_pids_accepted
unset -f stat
# The external parser's exit status is authoritative: no output (failure
# before any PID) and output followed by failure (partial read) are both NO-GO.
awk() { return 74; }
set +e; cgroup_procs_is_empty "$cgroup_empty"; rc=$?; set -e
[[ "$rc" == 2 ]] || test_fail cgroup_pre_pid_read_error_not_inconclusive
awk() { command awk "$@"; return 75; }
set +e; cgroup_procs_is_empty "$cgroup_pids"; rc=$?; set -e
[[ "$rc" == 2 ]] || test_fail cgroup_partial_read_error_not_inconclusive
unset -f awk
set +e; cgroup_procs_is_empty "$cgroup_bad"; rc=$?; set -e
[[ "$rc" == 2 ]] || test_fail cgroup_malformed_not_inconclusive
set +e; cgroup_procs_is_empty "$tmp/missing-cgroup.procs"; rc=$?; set -e
[[ "$rc" == 2 ]] || test_fail cgroup_missing_not_inconclusive
show_value() { printf '%s\n' '/invalid/../cgroup'; }
set +e; verify_unit_cgroup_empty synthetic.service; rc=$?; set -e
[[ "$rc" == 2 ]] || test_fail cgroup_malformed_not_inconclusive
show_value() { return 1; }
set +e; verify_unit_cgroup_empty synthetic.service; rc=$?; set -e
[[ "$rc" == 2 ]] || test_fail cgroup_query_error_not_inconclusive
unset -f show_value
# The observer accepts only a fully parsed transition from populated=1 while
# active to populated=0 on the same directory identity after timeout.
cgroup_events_live="$tmp/cgroup.events.live"
cgroup_events_empty="$tmp/cgroup.events.empty"
cgroup_events_bad="$tmp/cgroup.events.bad"
printf '%s\n%s\n' 'populated 1' 'frozen 0' >"$cgroup_events_live"
printf '%s\n%s\n' 'populated 0' 'frozen 0' >"$cgroup_events_empty"
printf '%s\n' 'populated unknown' >"$cgroup_events_bad"
set +e; cgroup_events_populated "$cgroup_events_live"; rc=$?; set -e
[[ "$rc" == 1 ]] || test_fail cgroup_events_live_not_observed
cgroup_events_populated "$cgroup_events_empty" || test_fail cgroup_events_empty_not_observed
set +e; cgroup_events_populated "$cgroup_events_bad"; rc=$?; set -e
[[ "$rc" == 2 ]] || test_fail cgroup_events_malformed_not_inconclusive
set +e; cgroup_events_populated "$tmp/missing-cgroup.events"; rc=$?; set -e
[[ "$rc" == 2 ]] || test_fail cgroup_events_missing_not_inconclusive
awk() { return 74; }
set +e; cgroup_events_populated "$cgroup_events_empty"; rc=$?; set -e
[[ "$rc" == 2 ]] || test_fail cgroup_events_read_error_not_inconclusive
unset -f awk
cgroup_proc_root="$tmp/cgroup-proc-root"
mkdir -p "$cgroup_proc_root/123"
printf '%s\n' '0::/synthetic' >"$cgroup_proc_root/123/cgroup"
cgroup_membership_matches 123 /synthetic "$cgroup_proc_root" || test_fail cgroup_membership_valid_rejected
set +e; cgroup_membership_matches 123 /other "$cgroup_proc_root"; rc=$?; set -e
[[ "$rc" == 1 ]] || test_fail cgroup_membership_mismatch_not_rejected
printf '%s\n%s\n' '0::/synthetic' '0::/other' >"$cgroup_proc_root/123/cgroup"
set +e; cgroup_membership_matches 123 /synthetic "$cgroup_proc_root"; rc=$?; set -e
[[ "$rc" == 2 ]] || test_fail cgroup_membership_ambiguous_not_inconclusive
printf '%s\n' '0::/synthetic' >"$cgroup_proc_root/123/cgroup"
TIMEOUT_UNIT=synthetic.service
owner_tag='ti0093:synthetic-owner'
timeout_cgroup_path=''; timeout_cgroup_identity=''; timeout_cgroup_pid=''
show_value() { case "$2" in ActiveState) printf '%s\n' active ;; MainPID) printf '%s\n' 123 ;; ControlGroup) printf '%s\n' /synthetic ;; Description) printf '%s\n' "$owner_tag" ;; Result) printf '%s\n' timeout ;; *) return 1 ;; esac; }
cgroup_directory_identity() { [[ "$1" == /sys/fs/cgroup/synthetic ]] || return 2; printf '%s\n' "${CGROUP_IDENTITY:-9:9:directory}"; }
cgroup_membership_matches() { [[ "$1:$2" == '123:/synthetic' ]] || return 2; return 0; }
cgroup_events_populated() { [[ "$1" == /sys/fs/cgroup/synthetic/cgroup.events ]] || return 2; return "${CGROUP_EVENTS_RC:-1}"; }
cgroup_procs_is_empty() { [[ "$1" == /sys/fs/cgroup/synthetic/cgroup.procs ]] || return 2; return "${CGROUP_PROCS_RC:-0}"; }
capture_timeout_cgroup_live || test_fail cgroup_observer_live_capture_rejected
[[ "$timeout_cgroup_path" == /sys/fs/cgroup/synthetic && "$timeout_cgroup_identity" == '9:9:directory' && "$timeout_cgroup_pid" == 123 ]] || test_fail cgroup_observer_identity_not_captured
CGROUP_EVENTS_RC=0; CGROUP_PROCS_RC=0
verify_timeout_cgroup_quiescent || test_fail cgroup_observer_quiescent_rejected
CGROUP_EVENTS_RC=1
set +e; verify_timeout_cgroup_quiescent; rc=$?; set -e
[[ "$rc" == 1 ]] || test_fail cgroup_observer_residual_not_rejected
CGROUP_EVENTS_RC=0
CGROUP_IDENTITY='10:10:directory'
set +e; verify_timeout_cgroup_quiescent; rc=$?; set -e
[[ "$rc" == 2 ]] || test_fail cgroup_observer_identity_change_not_inconclusive
unset CGROUP_IDENTITY
cgroup_directory_identity() { return 2; }
set +e; verify_timeout_cgroup_quiescent; rc=$?; set -e
[[ "$rc" == 2 ]] || test_fail cgroup_observer_disappeared_not_inconclusive

# Bound reads must re-check the directory identity around every file access.
# These fixtures model replacement before the read, during cgroup.events, and
# during cgroup.procs; none may retain a PASS result.
cgroup_directory_identity() { [[ "$1" == /sys/fs/cgroup/synthetic ]] || return 2; printf '%s\n' "${CGROUP_IDENTITY:-9:9:directory}"; }
cgroup_events_populated() { [[ "$1" == /sys/fs/cgroup/synthetic/cgroup.events ]] || return 2; return 0; }
cgroup_procs_is_empty() { [[ "$1" == /sys/fs/cgroup/synthetic/cgroup.procs ]] || return 2; return 0; }
CGROUP_IDENTITY='10:10:directory'
set +e; verify_timeout_cgroup_quiescent; rc=$?; set -e
[[ "$rc" == 2 ]] || test_fail cgroup_bound_read_identity_changed_before
CGROUP_IDENTITY='9:9:directory'
cgroup_events_populated() { CGROUP_IDENTITY='10:10:directory'; return 0; }
set +e; verify_timeout_cgroup_quiescent; rc=$?; set -e
[[ "$rc" == 2 ]] || test_fail cgroup_bound_read_identity_changed_during_events
CGROUP_IDENTITY='9:9:directory'
cgroup_events_populated() { return 0; }
cgroup_procs_is_empty() { CGROUP_IDENTITY='10:10:directory'; return 0; }
set +e; verify_timeout_cgroup_quiescent; rc=$?; set -e
[[ "$rc" == 2 ]] || test_fail cgroup_bound_read_identity_changed_during_procs
unset CGROUP_IDENTITY

# The real transition observer samples the same cgroup identity while active
# and accepts emptiness only in an iteration that has already observed the
# terminal state, Result=timeout and MainPID=0.
cgroup_directory_identity() { [[ "$1" == /sys/fs/cgroup/synthetic ]] || return 2; printf '%s\n' '9:9:directory'; }
cgroup_membership_matches() { [[ "$1:$2" == '123:/synthetic' ]] || return 2; return 0; }
cgroup_procs_is_empty() { [[ "$1" == /sys/fs/cgroup/synthetic/cgroup.procs ]] || return 2; return "${CGROUP_PROCS_RC:-0}"; }
transition_file="$tmp/transition-step"
printf '%s\n' 0 >"$transition_file"
show_value() {
  local step
  case "$2" in
    Description) printf '%s\n' "${TEST_DESCRIPTION:-$owner_tag}" ;;
    ActiveState) step="$(<"$transition_file")"; step=$(( step + 1 )); printf '%s\n' "$step" >"$transition_file"; case "$step" in 1) printf '%s\n' active ;; 2) printf '%s\n' deactivating ;; *) printf '%s\n' failed ;; esac ;;
    MainPID) step="$(<"$transition_file")"; [[ "$step" -le 1 ]] && printf '%s\n' 123 || printf '%s\n' 0 ;;
    ControlGroup) printf '%s\n' /synthetic ;;
    Result) printf '%s\n' timeout ;;
    *) return 1 ;;
  esac
}
cgroup_events_populated() { local step; [[ "$1" == /sys/fs/cgroup/synthetic/cgroup.events ]] || return 2; step="$(<"$transition_file")"; (( step < 3 )) && return 1 || return "${CGROUP_EVENTS_RC:-0}"; }
sleep() { :; }
timeout_cgroup_path=/sys/fs/cgroup/synthetic; timeout_cgroup_identity='9:9:directory'; timeout_cgroup_pid=123
CGROUP_EVENTS_RC=0; CGROUP_PROCS_RC=0
observe_timeout_cgroup_transition || test_fail cgroup_transition_terminal_empty_rejected
[[ "$(<"$transition_file")" == 3 ]] || test_fail cgroup_transition_intermediate_accepted
printf '%s\n' 0 >"$transition_file"; CGROUP_EVENTS_RC=1
set +e; observe_timeout_cgroup_transition; rc=$?; set -e
[[ "$rc" == 1 ]] || test_fail cgroup_transition_terminal_populated_not_rejected
printf '%s\n' 0 >"$transition_file"; CGROUP_EVENTS_RC=0; TEST_DESCRIPTION='other-owner'
set +e; observe_timeout_cgroup_transition; rc=$?; set -e
[[ "$rc" == 2 ]] || test_fail cgroup_transition_description_change_not_inconclusive
unset TEST_DESCRIPTION
printf '%s\n' 0 >"$transition_file"
cgroup_directory_identity() { return 2; }
set +e; observe_timeout_cgroup_transition; rc=$?; set -e
[[ "$rc" == 2 ]] || test_fail cgroup_transition_disappearance_not_inconclusive
unset -f show_value cgroup_directory_identity cgroup_membership_matches cgroup_events_populated cgroup_procs_is_empty sleep

grep -Fq "runtime_namespace_verification_inconclusive" "$tmp/controller.sh" || test_fail runtime_namespace_inconclusive_not_reported
grep -Fq "runtime_run_mount_verification_inconclusive" "$tmp/controller.sh" || test_fail runtime_mount_inconclusive_not_reported
grep -Fq "main_unit_cgroup_verification_inconclusive" "$tmp/controller.sh" || test_fail main_cgroup_inconclusive_not_reported
grep -Fq "timeout_canary_cgroup_verification_inconclusive" "$tmp/controller.sh" || test_fail timeout_cgroup_inconclusive_not_reported
! grep -Fq '[[ ! -s ' "$tmp/runtime-lifecycle.sh" || test_fail cgroup_uses_st_size
test_pass runtime_lifecycle_fail_closed_classification

# The split probe has a private read-only first fragment. The writer step
# rechecks ownership and owner marker before a temporary write transition.
grep -Fq "# PROBE_HEREDOC_PART_A_BEGIN" "$workflow" || test_fail probe_part_a_missing
grep -Fq "# PROBE_HEREDOC_PART_B_BEGIN" "$workflow" || test_fail probe_part_b_missing
grep -Fq 'chmod 0400 "$probe_stage"' "$workflow" || test_fail probe_part_a_identity_missing
grep -Fq 'chmod 0600 "$probe_stage"' "$workflow" || test_fail probe_part_append_write_transition_missing
grep -Fq 'cat >>"$probe_stage" <<' "$workflow" || test_fail probe_part_append_missing
probe_part_a_hash="$(sha256sum -- "$tmp/probe-a.sh")" || test_fail probe_part_hash_unavailable
probe_part_a_hash="${probe_part_a_hash%% *}"
[[ "$(grep -Fc "EXPECTED_PROBE_PART_A_SHA256='$probe_part_a_hash'" "$workflow")" == 2 ]] || test_fail probe_part_hash_commitment_mismatch
test_pass probe_source_split_integrity

# Every controller fragment used across steps is extracted from the published
# YAML and parsed as one script. The staging hand-offs remain restricted to a
# verified owner marker and a 0400-to-0600 controlled append transition.
for fragment in controller-a.sh controller-lifecycle.sh controller-b.sh controller-main.sh; do
  [[ -s "$tmp/$fragment" ]] || test_fail "controller_fragment_missing_${fragment%.sh}"
done
[[ "$(grep -Fc 'expected_owner="${GITHUB_RUN_ID:-invalid}:${GITHUB_RUN_ATTEMPT:-invalid}:${GITHUB_SHA:-invalid}"' "$workflow")" -ge 3 ]] || test_fail controller_fragment_owner_marker_guards
[[ "$(grep -Fc 'chmod 0600 "$controller_stage"' "$workflow")" == 3 ]] || test_fail controller_fragment_append_transitions
[[ "$(grep -Fc 'chmod 0400 "$controller_stage"' "$workflow")" -ge 3 ]] || test_fail controller_fragment_restricted_handoffs
test_pass controller_source_split_integrity


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
grep -Fq 'capture_timeout_cgroup_live' "$tmp/controller.sh" || test_fail timeout_live_capture
grep -Fq 'verify_timeout_cgroup_quiescent' "$tmp/controller.sh" || test_fail timeout_quiescent_verification
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

printf 'RESULT offline_static_tests=%s inconclusive=%s status=PASS\n' "$pass_count" "${inconclusive_count:-0}"
