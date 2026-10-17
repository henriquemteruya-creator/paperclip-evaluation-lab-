# Paperclip TI-0093 — benign VM/systemd preflight runbook

## Status and scope

- Implementation status: prepared for independent review
- Execution status: not executed
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

## Files and execution model

The workflow is intentionally self-contained because it does not checkout the
repository. Its two embedded, repository-owned scripts are installed by the
trusted runner shell as root-owned, mode `0555` files:

- trusted controller: `/usr/local/sbin/ti0093-vm-preflight-controller`;
- benign probe: `/usr/local/libexec/ti0093-vm-preflight-probe`.

The controller creates a dedicated system UID/GID, private root-owned output
directory under `/run`, one explicitly writable work directory under
`/var/lib`, and a synthetic world-readable sentinel under `/home/runner/work`.
The sentinel contains no private data. It is deliberately readable by normal
Unix permissions so that a denied read demonstrates `ProtectHome`, rather than
the file mode alone.

A second directory under `/var/lib` is deliberately owned by the service UID
but omitted from `ReadWritePaths`. A denied write therefore exercises the
systemd filesystem namespace rather than ordinary ownership. `/tmp` and
`/var/tmp` are also required to be read-only inside the service.

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
- only the work directory in `ReadWritePaths`; `/tmp` and `/var/tmp` explicitly
  read-only;
- known host-control paths masked with `InaccessiblePaths`, including Docker,
  the private systemd manager socket, system D-Bus, containerd, snapd and udev;
- `MemoryMax=256M`, `CPUQuota=50%`, `TasksMax=64` and
  `RuntimeMaxSec=45s`;
- explicit minimal environment and removal of credential, token, proxy and
  GitHub file-command names;
- stdin from `/dev/null`; stdout/stderr appended to a pre-created root-owned
  mode `0600` file.

No `systemd-run --pipe` or live untrusted-output stream is used.

## Runtime evidence

The benign service checks effective behavior, not only declared properties:

1. non-root UID/GID and a single unprivileged group;
2. zero inheritable, permitted, effective, bounding and ambient capabilities;
3. `NoNewPrivs: 1` in `/proc/self/status`;
4. absence of privilege tools and sensitive/unexpected environment names;
5. no inherited socket or runner-control descriptors;
6. successful write only in the allowed work directory;
7. denied writes in an otherwise UID-owned directory, `/tmp` and `/var/tmp`;
8. inability to read/list the synthetic runner workspace sentinel;
9. inability to observe the controller directory and known host-control
   sockets;
10. loopback-only interfaces, no IPv4/IPv6 routes, and failed DNS, direct TCP
    and HTTPS probes;
11. exact `memory.max` and `pids.max`, plus semantic 50% `cpu.max`, read from
    the service's cgroup v2 path.

While the probe is alive, the controller independently queries the system
manager for the expected properties and compares the service network and mount
namespace identities with its own without publishing inode values.

## Private evidence protocol

The service may emit only these closed forms to the private file:

```text
RESULT id=<known_id> status=PASS code=ok
READY status=PASS records=22
FINAL status=PASS records=22
```

The controller rejects unknown/duplicate/missing IDs, failures, malformed
records, control characters, workflow-command syntax, oversized output,
missing final newline, symlinked logs, unexpected ownership/mode or absent
markers. It never echoes a rejected line. The GitHub step summary is generated
from controller-owned literals and aggregate counts only.

## Timeout and cleanup canary

After the main probe, the controller starts a second benign `sleep` service
with the same profile and `RuntimeMaxSec=3s`. Approval requires:

- systemd reports `Result=timeout`;
- `MainPID=0` after termination;
- the service cgroup has no processes;
- no process remains under the dedicated UID after both units are stopped;
- controller trap removes units, UID/GID, sentinels, scripts and private
  directories on every exit path.

## Objective verdict

GO requires all of the following:

- workflow shape is exactly manual-only, `permissions: {}`, standard
  `ubuntu-24.04`, no actions and no checkout;
- repository visibility is reported as public and workflow SHA is valid;
- system manager and cgroup v2 are available;
- every manager-property comparison passes;
- all 22 runtime records pass and both markers parse exactly;
- mount and network namespaces differ from the controller;
- main service exits zero with `Result=success` and an empty cgroup;
- timeout canary and cleanup checks pass;
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
boundary. Path-based socket masking covers a closed set of relevant sockets,
not every possible future host service. Negative probes demonstrate the tested
paths and moment, not mathematical absence of all communication channels.

The service shares the guest kernel and its UID exists in the host user
namespace; no separate user namespace is claimed. The design also does not yet
address Node, pnpm, dependency stores, build scripts or Paperclip. Those remain
separate future decisions after a dynamically reviewed GO.
