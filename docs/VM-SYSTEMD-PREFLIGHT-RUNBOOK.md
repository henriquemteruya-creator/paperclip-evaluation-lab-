# Paperclip TI-0093 — benign VM/systemd preflight runbook

## Status and scope

- Implementation status: offline corrections under independent review; NOT
  ready for execution
- Execution status: execution #8 ended NO-GO (exit 86). Execution #9 remains
  NO-GO until the timeout-canary cgroup observation gate (below) is resolved by a
  separate architecture decision; offline PASS never means runtime PASS
- Paperclip status: not downloaded, installed, or executed
- P01/P02/P04 status: `planned` / NO-GO
- Cost target: R$0 incremental, conditional on a public repository and the
  standard `ubuntu-24.04` GitHub-hosted runner

This preflight tests only the proposed guest-observable boundary for a benign
process. A GO does not authorize Paperclip, dependency acquisition, P01/P02/P04,
merge, deploy, or access to another repository.

The closed Docker preflight in PR #1 is not used or modified. This workflow
implements the control-only step required by ADR-002 and its independent
review.

## Publication-time workflow validation

The first publication divided neither embedded script from the surrounding
workflow step. GitHub created three automatic `push` validation records for the
three initial commits and rejected the workflow before scheduling any job with
`Exceeded max expression length 21000`. The records have no jobs and no runner
duration; the benign service, systemd and every workflow command remained
unexecuted.

Commit `c8a3012df2dd9e31ead4da7955157a1ca4dcaf48` split staging and execution into
three `run` blocks below the platform limit. The current revision uses four
bounded blocks so that the expanded controller remains below the same limit.
Publishing the original correction did not
create another run, consistent with the valid manual-only trigger. The offline
suite now calculates every real block length and rejects a regression at or
above 21,000 characters. The three failed validation records remain evidence
and must not be represented as preflight executions.

## Files and execution model

The workflow is intentionally self-contained because it does not checkout the
repository. Its two embedded, repository-owned scripts are installed by the
trusted runner shell as root-owned, mode `0555` files:

- trusted controller: `/usr/local/sbin/ti0093-vm-preflight-controller`;
- benign probe: `/usr/local/sbin/ti0093-vm-preflight-probe`.

Installation is transactional. Before reserving a temporary name, the runner
requires the installation directory to be a non-symlink `root:root` mode `0755`
directory. It creates a root-owned private temporary file in that directory,
records its device/inode identity, and installs the script there. Only after
the temporary file still has the recorded identity is the final, previously
absent path published using an atomic hard link. The final path must then be a
root-owned mode `0555` regular file with the same identity. On an installation
failure, cleanup removes only a temporary or final path whose recorded identity
is still present; an identity mismatch is a fail-closed error and is never
deleted. This prevents a partial `install` failure from being mistaken for a
preexisting resource while also preventing cleanup from removing an unproven
path.

## Continuity between workflow steps

The installation step writes a private, runner-owned manifest in the existing
mode-`0700` staging directory only after both root-owned executables have been
published. It binds the current run marker to each fixed artifact ID and stores
only its device/inode identity and SHA-256 digest. The following step validates
the staging directory, run marker and manifest ownership/modes, parses exactly
the expected three records, then rechecks each executable as a non-symlink
root-owned mode-`0555` regular file with the recorded identity and digest
before invoking the controller. A mismatch, unreadable metadata, absent hash
tool or malformed/extra manifest record is a fail-closed `NO-GO`.

Final cleanup repeats the same artifact checks before deletion. It also checks
the staging directory identity and owner/mode before recursive removal. An
unproven path is deliberately preserved and turns the run into `NO-GO`; the
workflow never treats inability to prove ownership as authorization to remove a
resource.

## Offline manifest-test evidence

The static suite extracts both the manifest writer and reader from the workflow
and exercises them end to end in a disposable directory: creation, private
publication, positive read/verification, collision preservation, a partial
writer failure with no published manifest, an altered manifest, and verified
cleanup refusal. For portability, the fixture simulates `root:root` metadata
only for its two disposable executable paths; the production functions remain
unchanged and still require actual `root:root` mode-`0555` files. The hash
regression changes a fixture file in place, restores mode `0555`, proves the
device/inode is unchanged, and then confirms rejection and cleanup refusal
caused by the SHA-256 mismatch.

The suite is designed to run under a non-root user. In the constrained review
environment used for this revision, an attempted `setpriv --reuid=65534` failed
with `setresuid: Invalid argument`, so a separate real non-root invocation was
not demonstrated there. That is an environment limitation, not evidence that
the non-root execution passed; the future GitHub-hosted runner remains the
place to observe that runtime identity after separate authorization.

Execution #4 (run `39075677975`, SHA
`45b70744fd7771e5a82c17e881cce62b343aafcb`) failed before the controller ran:
the GitHub-hosted image had no `/usr/local/libexec` directory, so the second
`install` could not create the old probe path. The controller installation in
`/usr/local/sbin` had already succeeded; no `systemd-run`, Docker, Paperclip,
or dynamic isolation check was reached. The PR branch now uses the distinct
probe path under that same existing directory and checks the destination
directory, path collision and symlink state before installation. The workflow
registered on `main` through PR #3 remains the earlier audited blob and does
not include this compatibility correction; any future branch execution must
use the newly reviewed PR #2 SHA.

Before creating anything, the controller rejects collisions in its directories,
sentinel, dedicated identity and both unit names. The workflow likewise rejects
preexisting staging or installed-script paths. Ownership flags are set only
after successful creation; cleanup stops or removes only flagged resources and
requires the transient unit's run-specific description tag to match. Partial
creation failures remain NO-GO while cleanup still attempts every owned item.

The controller source is intentionally assembled across two bounded workflow
blocks. The first writes the reviewed first fragment and closes both it and its
run marker at `0400`. The second validates the directory, regular-file type,
absence of symlinks, owner/mode and exact marker before opening a short,
owner-only `0600` append window. It appends only the second reviewed heredoc,
runs `bash -n`, and closes the final controller at `0500` before installation.
Any failure after ownership is established removes only this execution's stage;
a collision remains untouched. The offline suite exercises that exact two-step
transition as the ordinary non-root test identity; a constrained development
environment that cannot switch UID may use only a UID 0 identity with an empty
effective capability set, which remains subject to the owner write-bit check.
It covers bad modes, collisions, symlinks, marker mismatch, append failure and
cleanup.

The controller creates a dedicated system UID/GID, private root-owned output
directory under `/run`, one explicitly writable work directory under
`/var/lib`, and a synthetic world-readable sentinel under `/home/runner/work`.
The sentinel contains no private data. It is deliberately readable by normal
Unix permissions so that a denied read demonstrates `ProtectHome`, rather than
the file mode alone.

A second directory under `/var/lib` is deliberately owned by the service UID
but omitted from `ReadWritePaths`. A denied write therefore exercises the
systemd filesystem namespace rather than ordinary ownership. `/tmp`,
`/var/tmp` and `/dev/shm` are required to be read-only inside the service.
`/run` is replaced by a 1 MiB read-only `tmpfs` with
`nosuid,nodev,noexec`; it is not the host runtime directory.

## Required transient-service profile

The controller invokes the system manager explicitly with
`systemd-run --system`. The service has:

- dedicated `User` and `Group`, with no supplementary groups;
- empty capability bounding and ambient sets;
- `NoNewPrivileges=yes`;
- `PrivateNetwork=yes`, with only loopback observable;
- `ProtectSystem=strict`, `ProtectHome=yes`, `PrivateTmp=yes`,
  `PrivateDevices=yes`, protected kernel/control-group paths and restricted
  namespace creation;
- only the work directory in `ReadWritePaths`; `/tmp`, `/var/tmp` and
  `/dev/shm` explicitly read-only, plus a private read-only `/run`;
- known host-control paths masked with `InaccessiblePaths`, including Docker,
  the private systemd manager socket, system D-Bus, containerd, snapd and udev;
- `MemoryMax=256M`, `CPUQuota=50%`, `TasksMax=64` and
  `RuntimeMaxSec=45s`;
- explicit minimal environment: the probe and timeout canary are invoked through
  `env -i` with only fixed `PATH`, `LANG` and `LC_ALL`; credential, token,
  proxy and GitHub file-command names are also removed by systemd;
- stdin from `/dev/null`; stdout/stderr appended to a pre-created root-owned
  mode `0600` file.

No `systemd-run --pipe` or live untrusted-output stream is used.

## Runtime evidence

The benign service checks effective behavior, not only declared properties:

1. non-root UID/GID and a single unprivileged group;
2. zero inheritable, permitted, effective, bounding and ambient capabilities;
3. `NoNewPrivs: 1` in `/proc/self/status`;
4. absence of privilege tools and sensitive/unexpected environment names;
5. exactly descriptors 0, 1, 2 and Bash's script descriptor 255, with verified
   types and identities; any extra or inconclusive descriptor is rejected;
6. successful write only in the allowed work directory;
7. denied writes in an otherwise UID-owned directory, `/tmp`, `/var/tmp` and
   `/dev/shm`;
8. inability to read/list the synthetic runner workspace sentinel;
9. a unique `/run` tmpfs mount with expected identity, filesystem, mount-level
   `ro,nosuid,nodev,noexec`, no propagation/submount and an observable 1 MiB
   size; the controller also requires a distinct device from the host `/run`
   and validates the system manager's effective `TemporaryFileSystem` value.
   A separate sanitized diagnostic classifies each submount below `/run` from
   its properties, never from who probably created it (see "Meaning of the
   `/run` diagnostic codes"). The only PASS is "no submount"; every other
   outcome stays NO-GO, a restrictive classification does not authorize any
   submount, and detailed mount data is never published;
10. inability to observe the controller directory and known host-control
   sockets, plus a fail-closed filesystem scan for pathname AF_UNIX sockets
   below the service's `/run`, `/dev`, `/tmp` and `/var/tmp`;
11. network isolation, established by combined evidence rather than by route
    tables (see "Network isolation: proven versus inferred"): an own network
    namespace listing only `lo` in `/proc/self/net/dev` (strict parser), the
    system manager's effective `PrivateNetwork`, an exact
    `RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6` allow-list, a negative
    `AF_NETLINK` probe, empty capability sets, host-socket masks and the
    DNS/TCP/HTTPS negative probes. TCP and HTTPS are attempted only when the
    interface listing and the complementary route files are both verified
    clean; otherwise a sanitized prerequisite failure is reported, not
    "blocked". Missing tools, timeouts and unrecognized failures are NO-GO;
12. exact `memory.max` and `pids.max`, plus semantic 50% `cpu.max`, read from
    the service's cgroup v2 path.

While the probe is alive, the controller independently queries the system
manager for the expected properties (including the exact address-family
allow-list) and compares the service network and mount namespace identities with
its own without publishing inode values. It also reads `/proc/<MainPID>/net/dev`
itself, bound to the unit (MainPID unchanged before and after) and to one
network namespace (same link before and after, different from its own), with the
same strict parser as the probe.

## Network isolation: proven versus inferred

Property under test: the service runs in a network namespace of its own that
contains only the loopback interface, and cannot reach the network.

Verified by the preflight (each a separate NO-GO when absent or inconclusive):

- the system manager reports `PrivateNetwork=yes` and the exact address-family
  allow-list; AF_NETLINK is not in it;
- the service's network and mount namespaces differ from the controller's;
- the interface listing of the service's own namespace (`/proc/self/net/dev`
  from inside, `/proc/<MainPID>/net/dev` from the controller) is exactly `lo`;
  the parser demands the kernel header, a bounded row count, 16 numeric columns
  per row, a final newline and printable ASCII, and refuses empty, truncated,
  NUL-bearing or otherwise malformed input;
- `/sys/class/net` must agree, but it is never an authority on its own: sysfs
  follows the mount that created it, and in an unshared namespace it lists the
  host's interfaces;
- a negative probe: creating a netlink socket (through `ip`) must fail with the
  exact EAFNOSUPPORT message; success or any other failure is NO-GO;
- empty capability bounding/ambient sets, host-socket masks and the negative
  DNS, TCP and HTTPS probes.

Inferred, not demonstrated at runtime:

- that no interface other than `lo` can exist is inferred from the listing at two
  instants plus the absence of capabilities and of netlink; it is not a
  continuous guarantee;
- that no route can lead outside is inferred from the absence of an external
  interface. Route files are only COMPLEMENTARY and PARTIAL: `/proc/<pid>/net/route`
  lists the IPv4 main table only (not the local table, policy-routing tables or
  rules, which have no procfs file); `ipv6_route` lists all IPv6 tables but only
  the kernel's reject entry and the loopback `::1/128` entry are tolerated. They
  are not evidence of an empty routing configuration;
- negative connectivity probes are point-in-time and do not prove the absence of
  every kernel communication channel.

Offline evidence is limited to fixtures, an independent-oracle fuzz and
mechanism checks on one disposable namespace of a WSL2 6.18 kernel, with GNU awk
and mawk and Bash 5.3. It is not evidence about the GitHub-hosted runner.

## Meaning of the `/run` diagnostic codes

The record `run_mount_diagnostic` publishes one code from a closed grammar:

- `no_submount`: the only PASS.
- `sockets_|private_root_|run_user_|mixed_expected_` followed by `restrictive`:
  every submount below `/run` targets an expected, exactly matched path and all
  observed properties are restrictive. Still NO-GO.
- the same prefixes followed by `not_restrictive_` and nine flags `b1..b9`
  (`1` = observed): `b1` root is `/`; `b2` root is an inaccessible node of the
  wrong kind; `b3` root unrecognised; `b4` filesystem type is not tmpfs; `b5`
  mount source is not tmpfs; `b6` flags are not exactly `ro,nosuid,nodev,noexec`
  (or `rw` present); `b7` a propagation field is present; `b8` another mount is
  stacked on the same target; `b9` the target is accessible to the service.
- `unexpected_target_<family>` with `systemd`, `user_child`,
  `private_root_child`, `credentials`, `lock` or `other`: at least one submount
  targets a path that is not an expected one. The family comes from a fixed
  dictionary; look-alikes, children and escaped names are never matched as
  expected. When several families occur the first in the listed order is shown.
- `evidence_incomplete`: no property violation was observed but effective
  access could not be proven.
- `inspection_error`: the evidence was malformed or unreadable.

Precedence: unexpected target, then observed property flags, then incomplete
evidence. Only static tokens and bits are published; no path, identity, device
number or raw mountinfo ever is. The grammar is validated by the probe and again
by the controller, which publishes at most eight pairs and 512 characters.
Retaining detailed evidence would need a separate, reviewed mechanism and is not
implemented.

## Private evidence protocol

The service may emit only these closed forms to the private file:

```text
RESULT id=<known_id> status=PASS code=ok
READY status=PASS records=26
FINAL status=PASS records=26
```

The controller rejects unknown/duplicate/missing IDs, failures, malformed
records, control characters, workflow-command syntax, oversized output,
missing final newline, symlinked logs, unexpected ownership/mode or absent
markers. Results must precede READY; FINAL must follow READY and be the final
record. It never echoes a rejected line. For a fully valid failing log it may
publish at most eight `id=category` pairs, limited to the reviewed diagnostic
IDs `run_mount_diagnostic`, `network_interfaces`, `routes`, `netlink_denied`,
`tcp_blocked` and `https_blocked` and their closed category grammar. A second closed publisher revalidates the
label, cardinality, syntax, IDs and categories immediately before `printf`.
Unknown categories, duplicates, truncation or any parser error suppress those
pairs entirely. The GitHub step summary is generated from controller-owned
literals and aggregate counts only.

## Timeout and cleanup canary

After the main probe, the controller starts a second benign `sleep` service
with the same profile and `RuntimeMaxSec=3s`. Approval requires:

- systemd reports `Result=timeout`;
- `MainPID=0` after termination;
- while active, the controller captures the cgroup's private path and
  device/inode identity, the canary MainPID membership and
  `cgroup.events populated=1`. It then polls from outside that cgroup. A pass
  requires, in one post-terminal observation, the same `Description` owner
  tag, stable path/device/inode, `Result=timeout`, `MainPID=0`,
  `populated=0`, and a completed empty `cgroup.procs` read. A vanished,
  unreadable or changed cgroup, PID, identity, description or incomplete read
  is inconclusive NO-GO, never evidence of emptiness. Directory identity is
  revalidated immediately before and after *each* `cgroup.events` and
  `cgroup.procs` read, and once more after both reads; a replacement race is
  therefore not accepted. During `deactivating`, `MainPID=0` is only treated
  as an expected intermediate condition—the final evidence is still required
  in `inactive` or `failed`;
- no process remains under the dedicated UID after both units are stopped;
- controller cleanup removes only units, UID/GID, sentinel and directories
  proven to have been created by this execution; the trusted workflow step
  removes only its installed scripts and staging directory and verifies their
  absence. Preexisting resources are never stopped, overwritten or removed.

## Objective verdict

GO requires all of the following:

- workflow shape is exactly manual-only, `permissions: {}`, standard
  `ubuntu-24.04`, no actions and no checkout;
- repository visibility is reported as public and workflow SHA is valid;
- system manager and cgroup v2 are available;
- every manager-property comparison passes;
- all 26 runtime records pass and both markers parse in exact order;
- mount and network namespaces differ from the controller;
- `/run` mountinfo, device separation and effective systemd property all pass;
- main service exits zero with `Result=success` and an empty cgroup;
- timeout canary passes, every owned resource is removed and post-cleanup
  absence checks pass;
- private log and sanitized summary checks pass.

Anything absent, incompatible, failed or inconclusive is NO-GO with exit 86.
The workflow does not retry with relaxed properties or higher limits.

## Evidence review after an authorized run

Reviewers should record:

1. run URL, selected branch and exact workflow SHA;
2. repository visibility and standard-runner identity shown by GitHub;
3. every published `PASS`/`NO-GO` identifier and the final sanitized verdict;
4. job exit status and timeout behavior;
5. confirmation that no artifact, cache, checkout, download, Docker command or
   Paperclip operation occurred;
6. whether any platform representation differed from the static expectations.

Do not infer the content of the private log from aggregate output. If a parser
or representation fails, preserve NO-GO and review the code before considering
any change or rerun.

## Conditions for one manual execution

No execution is authorized by this document. A single benign run may be
considered only after:

1. an independent reviewer approves the immutable workflow commit and verifies
   that both embedded scripts match the reviewed source;
2. offline tests pass independently;
3. the repository is still public, both PRs remain draft, and the selected
   runner label remains the standard free `ubuntu-24.04` runner;
4. the owner gives explicit approval naming the commit and authorizing exactly
   one `workflow_dispatch` run;
5. the operator selects the new preflight branch, not PR #1's Docker workflow,
   and does not use “Re-run jobs” from an older SHA.

## Isolation limits and residual risk

This is defense in depth inside a GitHub-hosted VM, not an independently
attested sandbox. It cannot prove the GitHub/Azure hypervisor, runner image,
guest kernel or systemd implementation safe. The trusted controller remains
root in the guest. A kernel or systemd vulnerability could bypass the tested
boundary. A private `/run`, explicit masks and pathname-socket scan cover the
inspected filesystem namespace at one moment; they do not prove absence of
every kernel communication channel. Network failures are accepted only when
their return code is consistent with the independently observed route
evidence and direct unreachable result. Negative probes remain point-in-time
evidence, not mathematical proof of non-connectivity.

The service shares the guest kernel and its UID exists in the host user
namespace; no separate user namespace is claimed. The design also does not yet
address Node, pnpm, dependency stores, build scripts or Paperclip. Those remain
separate future decisions after a dynamically reviewed GO.

## Known open gate: timeout canary cgroup observation (BLOCKING)

The original criterion is unchanged: `populated=1` while running, then
`Result=timeout`, `MainPID=0`, a valid `populated=0` observation, an empty
`cgroup.procs` read, the same cgroup identity and no residual processes.
Disappearance of the cgroup is never accepted in place of an observation of
emptiness. The system manager removes the unit's cgroup as part of the
transition to inactive/failed, so the current observer cannot succeed and stays
inconclusive (NO-GO); this gate is therefore STOP for the present architecture.
No observer was changed. A dedicated-slice ancestor is NOT accepted as a
substitute; it would be a different requirement and needs its own architecture
decision. Future, separate investigation would have to establish: a dedicated
slice with verifiable ownership, its persistence after the timeout, recursive
`populated` behavior, exclusive membership of the service's processes,
prevention of process migration, a stable identity and safe cleanup.

## Conditions still missing for GO

- a resolved architecture for the timeout-canary cgroup observation (above);
- runtime evidence, never obtained, that the network, mount and cgroup
  observations work on the GitHub-hosted runner;
- the real representation of `/run` submounts, learned only from the sanitized
  diagnostic codes, followed by an independent review before anything is
  allowed;
- independent review of the final immutable commit and explicit owner approval
  of exactly one manual run.
