# Docker-managed `/etc` mounts: host-side viability investigation closed

This document records the formal stop decision for the current host-side
observation design. It is an evidence record, not an authorization to change
the workflow, its allowlists, or to execute Paperclip.

## Final status

- `host_source_viability=unproven`
- `host_sources_proven_inaccessible=false`
- `limitation_class=timeout_ambiguous_stage`
- `private_protocol_status=blocked`
- `evidence_complete=false`
- `paperclip_tests=P01,P02,P04:NO-GO`
- `rerun_14=not_authorized`

The three destinations remain rejected by the runtime allowlist:

- `/etc/hosts`
- `/etc/hostname`
- `/etc/resolv.conf`

No private container-to-runner evidence protocol was implemented. The current
line of investigation is closed under the present GitHub-hosted runner design
and time limits.

## Positive evidence retained

Run #8 (`38834411994`, commit
`bf14ee642697715ae37f6919c4dc31c9114cca3e`) established the eight narrowly
scoped masked mounts without creating a generic exception:

- masked directories `proc_acpi`, `proc_scsi`, and `sys_firmware`: cardinality
  one, `tmpfs/tmpfs`, root `/`, per-mount read-only, no unexpected propagation
  or submounts, non-symlink directory objects, and empty contents;
- masked pseudo-files `proc_interrupts`, `proc_kcore`, `proc_keys`,
  `proc_latency_stats`, and `proc_timer_list`: cardinality one, `tmpfs/tmpfs`,
  root `/null`, the observed per-mount mode required by the closed rule, no
  unexpected propagation, non-symlink character-device objects, and `/dev/null`
  identity `1:3`.

The same run also produced positive evidence for the existing isolation
controls: UID/GID 10001, all five capability sets zero, `NoNewPrivs`, read-only
root filesystem, bounded tmpfs, CPU/memory/PID cgroups, loopback-only network,
no default IPv4 or IPv6 route, successful socket scan in its defined scope,
and negative DNS, TCP, TLS, and HTTPS egress probes. Later diagnostic runs
continued to preserve these controls. These results support only the tested
preflight predicates; they do not prove a complete sandbox.

## Run #13 result

Run #13 (`39050285747`) executed commit
`92fb8aa0838b5205334a0f462c8b0e91df21646d`. After `RUNTIME_READY`, all three
Docker-managed metadata fields reported `inspect_ok=true`,
`metadata_present=true`, and `phase_consistent=true`.

The host-side gate then reported exactly one sanitized result per known ID,
each with:

```text
accessible=false provenance_verified=false stable=false inspection_error=timeout
```

The workflow correctly remained fail-closed and ended with exit 86/NO-GO.
Paperclip was not downloaded, installed, or executed.

The gate did not identify which bounded operation expired. The elapsed time is
compatible with a shared operation such as a `DockerRootDir` observation
timing out in both samples, which would propagate `timeout` to all three IDs
before individual source inspection. It is also compatible with other bounded
operations. The public evidence cannot distinguish those cases.

Therefore, the three timeout records are not three independent proofs of
source-file inaccessibility. They do not establish EACCES, permission denial,
physical absence, or universal infeasibility. The correct conclusion is
**viability not proved by this design**, not **sources proved inaccessible**.

## Independent blockers

The host-side timeout does not resolve or replace these independent limits:

1. `.Mounts=unavailable` remains insufficient for `evidence_complete`. A
   future device/inode correlation would not automatically change that policy.
2. The trusted runner controls a rootful Docker daemon and shares the host
   kernel boundary. Related host and daemon observations are not independent
   attestation.
3. A user namespace distinct from the host user namespace has not been
   demonstrated.
4. No approved private channel exists to compare container-side and host-side
   evidence. Its design remains blocked rather than merely pending execution.

## Reopening conditions

No run #14, timeout increase, privilege increase, allowlist relaxation, private
protocol, or Paperclip test may follow from this result. Reconsideration first
requires a new, explicit architecture decision that:

1. states whether the GitHub-hosted/rootful-Docker boundary remains acceptable
   or replaces it with a different isolated environment;
2. identifies the exact observation stages and sets justified timing and
   timeout criteria before execution;
3. defines a privacy-preserving, strictly parsed trust boundary for any private
   container-to-runner evidence channel;
4. independently resolves the `.Mounts=unavailable` evidence policy;
5. addresses the unproven user-namespace boundary and shared-kernel risk;
6. receives independent review and explicit authorization for one bounded
   validation run.

Only after those conditions are satisfied and the laboratory preflight has a
separately reviewed GO could P01, P02, or P04 be reconsidered. This closure is
not a GO for Paperclip, merge, deploy, or infrastructure changes.
