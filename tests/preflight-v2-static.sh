#!/usr/bin/env bash
# Offline checks for the fail-closed verifiers in .github/workflows/preflight.yml.
# This script never invokes Docker, GitHub Actions, or Paperclip.
set -Eeuo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
workflow="$root_dir/.github/workflows/preflight.yml"
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

mountinfo_verdict() {
  awk '
    function allowed_target(path) {
      return path == "/" || path == "/proc" || path ~ /^\/proc\// ||
             path == "/sys" || path ~ /^\/sys\// ||
             path == "/dev" || path ~ /^\/dev\// ||
             path == "/tmp" || path == "/run" ||
             path == "/etc/hosts" || path == "/etc/hostname" || path == "/etc/resolv.conf"
    }
    function has_option(options, wanted, n, values, i) {
      n = split(options, values, ",")
      for (i = 1; i <= n; i++) if (values[i] == wanted) return 1
      return 0
    }
    {
      if (NF < 7) { malformed = 1; next }
      separator = 0
      for (i = 7; i <= NF; i++) if ($i == "-") { separator = i; break }
      if (!separator || separator + 2 > NF) { malformed = 1; next }
      target = $5; options = $6; filesystem = $(separator + 1); source = $(separator + 2)
      if (!allowed_target(target)) forbidden = 1
      if ((target == "/tmp" || target == "/run") && (filesystem != "tmpfs" || !has_option(options, "rw"))) forbidden = 1
      if (target == "/" && !has_option(options, "ro")) forbidden = 1
      if (target ~ /(^|\/)(docker|containerd|podman)\.sock$/ ||
          target ~ /^\/(home\/runner|__w|github)(\/|$)/ ||
          source ~ /(docker\.sock|containerd\.sock|podman\.sock|\/home\/runner|\/__w|\/github)/) forbidden = 1
    }
    END { if (malformed) exit 2; if (forbidden) exit 1; exit 0 }
  ' "$1"
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
rg -Fq 'mountinfo_inspection_error_rc_' "$workflow"
rg -Fq 'verify_no_default_route 4' "$workflow"
rg -Fq 'verify_no_default_route 6' "$workflow"
rg -Fq 'docker_reported_mounts=' "$workflow"
if rg -Fq 'mount_count ==' "$workflow"; then
  printf 'FAIL workflow still assumes a fixed Docker .Mounts count\n' >&2
  exit 1
fi
printf 'PASS workflow_static_contract\n'

printf '%s\n' \
  '36 25 0:32 / / ro - overlay overlay ro' \
  '37 36 0:33 / /tmp rw,nosuid - tmpfs tmpfs rw' \
  '38 36 0:34 / /run rw,nosuid - tmpfs tmpfs rw' >"$tmpdir/mounts-allowed"
set +e; mountinfo_verdict "$tmpdir/mounts-allowed"; rc=$?; set -e
assert_rc 0 "$rc" mountinfo_allowed

printf '%s\n' '36 25 0:32 / /__w rw - ext4 /dev/sda1 rw' >"$tmpdir/mounts-forbidden"
set +e; mountinfo_verdict "$tmpdir/mounts-forbidden"; rc=$?; set -e
assert_rc 1 "$rc" mountinfo_forbidden_is_no_go

set +e; mountinfo_verdict "$tmpdir/does-not-exist"; rc=$?; set -e
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
