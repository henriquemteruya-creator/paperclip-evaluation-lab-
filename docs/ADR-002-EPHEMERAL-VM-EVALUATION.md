# ADR-002: ephemeral-VM architecture for Paperclip evaluation

- Status: proposed
- Evaluation status: `planned`
- Date: 2026-10-17
- Scope: TI-0093 tests P01, P02 and P04
- Paperclip revision: `aa04c5c2a7044ca008aa0d16550dbfb394227247`
- Supersedes: no previous ADR; it does not reopen or modify the closed Docker
  preflight at commit `66025ae81c45d8f827dbf25bc88fd1bc90f30988`

## Decision

Use one fresh standard GitHub-hosted `ubuntu-24.04` virtual machine for each
test, with an additional host-controlled execution boundary inside the VM.
Paperclip must not run directly as the runner account. It may run only in a
transient system service under a dedicated unprivileged UID, with a clean
environment, cgroup limits, a private network namespace, a restricted
filesystem view, dropped capabilities, `no-new-privileges` and an independent
wall-clock timeout.

This is a conditional architectural decision, not authorization to execute.
Before Paperclip is downloaded or run, a separate implementation must prove
that the selected runner supports every required host control. Failure of any
control is a NO-GO and falls back to static analysis. Docker is not part of the
new execution boundary.

## Context

The previous design made a rootful Docker container the main process boundary.
It verified eight destination-specific masked mounts and several isolation
predicates, but it could not prove the provenance of the three Docker-managed
files under `/etc`. That host-side line was formally closed. Repeating it,
raising its timeout or relaxing its allowlist is outside this ADR.

GitHub documents standard Linux hosted runners as newly provisioned virtual
machines for each job. The public-repository `ubuntu-24.04` standard runner is
currently documented with 4 vCPUs, 16 GiB RAM and 14 GiB SSD; `ubuntu-slim` is
a container rather than a VM and is excluded. A fresh VM improves separation
between jobs, but is not sufficient alone: workflow steps run as a runner
account with passwordless `sudo`, outbound network is normally available, and
the guest kernel and GitHub/Azure control plane remain trusted.

Sources consulted:

- GitHub, [GitHub-hosted runners reference](https://docs.github.com/actions/reference/runners/github-hosted-runners).
- GitHub, [Choosing the runner for a job](https://docs.github.com/actions/using-jobs/choosing-the-runner-for-a-job).
- GitHub, [Automatic token authentication](https://docs.github.com/actions/security-for-github-actions/security-guides/automatic-token-authentication).
- GitHub, [Actions billing](https://docs.github.com/billing/managing-billing-for-your-products/managing-billing-for-github-actions/about-billing-for-github-actions).
- Paperclip, [fixed commit](https://github.com/paperclipai/paperclip/commit/aa04c5c2a7044ca008aa0d16550dbfb394227247).
- Paperclip files at that commit: `package.json`, `pnpm-lock.yaml`,
  `doc/DEVELOPING.md`, `scripts/link-plugin-dev-sdk.mjs`,
  `scripts/ensure-workspace-package-links.ts`,
  `scripts/run-vitest-stable.mjs`,
  `server/src/__tests__/agent-permissions-routes.test.ts`,
  `server/src/__tests__/authorization-service.test.ts`, and
  `server/src/__tests__/budgets-service.test.ts`.

The upstream root manifest requires Node.js `>=24.11.0`, identifies
`pnpm@9.15.4`, runs `node scripts/link-plugin-dev-sdk.mjs` as `postinstall`,
and defines the full test command through `scripts/run-vitest-stable.mjs`.
Those scripts were inspected for planning, but neither they nor their
dependencies have been executed in this laboratory.

## Alternatives

| Alternative | Isolation | Network and credentials | Reproducibility | Cost | Complexity | Decision |
|---|---|---|---|---|---|---|
| A. Fresh hosted VM per test, no inner boundary | A new VM separates jobs, but Paperclip would share the privileged runner account and could invoke passwordless `sudo`. | `permissions: {}` reduces repository-token permissions, but ordinary egress and the runner filesystem remain reachable. | Good VM image traceability; weak containment of third-party code. | R$0 on a public repository and standard runner. | Low. | NO-GO. VM ephemerality alone is insufficient. |
| B. Fresh hosted VM plus host-controlled process boundary | Job-level VM separation plus dedicated UID, systemd sandbox properties, cgroups, private network namespace and timeout. No Docker/shared container mount problem. | Acquisition occurs only in trusted bootstrap; Paperclip receives no token or secret and runs loopback-only. | Exact commit, lockfile, tool versions, commands and sanitized outcomes are recorded per independent job. | R$0 under the conditions below. | Moderate and bounded. | Recommended, conditional on a control-only preflight. |
| C. Static analysis only | No third-party execution risk. | No runtime egress or credentials. | Highly reproducible for source facts, but cannot establish behavioral results. | R$0. | Low. | Mandatory fallback if any B gate fails. P01/P02/P04 remain `planned`. |

Nested virtualization, larger runners and a new container-based sandbox are
not selected. Nested virtualization is not a documented security guarantee on
standard hosted runners, larger runners can be billable, and another Docker
boundary would reintroduce the mechanism just closed.

## Trust boundaries and phases

### Trusted control plane

The GitHub-hosted VM, its kernel, systemd, the Actions runner and a small
repository-owned shell controller are trusted infrastructure. The controller:

1. verifies that the repository is public, the label is exactly
   `ubuntu-24.04`, the workflow has only `workflow_dispatch`, and
   `permissions: {}` is present;
2. performs anonymous source and package acquisition without checkout actions;
3. creates the dedicated UID and root-owned execution policy;
4. starts, monitors and stops the transient service;
5. parses private output and emits only a bounded sanitized report.

The controller must never source or execute a file from Paperclip. Paperclip,
all package content and all lifecycle/build/test scripts are untrusted.

### Acquisition phase (network available only to the controller)

- initialize an empty Git repository and fetch only commit
  `aa04c5c2a7044ca008aa0d16550dbfb394227247` anonymously from the public
  upstream;
- require `HEAD` to equal that full SHA and a clean detached worktree;
- record hashes for `package.json`, `pnpm-lock.yaml` and reviewed scripts;
- obtain an exact Node.js 24.11-or-newer runtime and `pnpm@9.15.4` only through
  a separately reviewed, checksum-verifying path if the runner image does not
  already provide them;
- execute only `pnpm fetch --frozen-lockfile --ignore-scripts` as the trusted
  package-acquisition operation;
- inventory workspace and dependency lifecycle scripts without running them.

The implementation review must define the exact allowed hosts and checksum
sources. Any unpinned tool, lockfile drift, lifecycle execution, git submodule,
Git LFS object, private package, authentication challenge or unexpected host is
a NO-GO.

### Untrusted execution phase

The source tree and prepared package store are handed to a dedicated UID that
is not the runner account, is not in `sudo` or Docker-related groups, and owns
only its bounded work directory. The transient service must enforce at least:

- `NoNewPrivileges=yes` and an empty capability bounding/ambient set;
- `PrivateNetwork=yes`, allowing loopback only;
- `ProtectSystem=strict`, `ProtectHome=yes`, `PrivateTmp=yes`,
  `PrivateDevices=yes`, kernel/control-group protections and an explicit
  writable-path allowlist for the work directory;
- namespace creation restricted for the untrusted process;
- cgroup v2 limits for memory, CPU and tasks;
- a service runtime limit plus an outer trusted `timeout`;
- `env -i` with an explicit minimal environment and no GitHub file-command
  paths, token, credential, proxy or cloud variables.

Before Paperclip runs, a benign control-only invocation under the exact same
unit properties must prove the UID/GID, zero effective capabilities,
`NoNewPrivs`, cgroup values, filesystem restrictions and loopback-only network.
Negative DNS, direct TCP and HTTPS probes must fail. Parsing errors or
inconclusive observations are NO-GO.

The untrusted process writes stdout/stderr to a root-owned private file, not to
the live Actions stream. This prevents workflow-command injection. A trusted
parser emits only an allowlisted summary, bounded test identifiers/counts,
exit codes, duration and cryptographic hashes. Raw logs are destroyed with the
VM and are not uploaded in the initial design.

## Resource limits

Initial ceilings proposed for the implementation review are:

| Test | MemoryMax | CPUQuota | TasksMax | Command limit | Job limit |
|---|---:|---:|---:|---:|---:|
| P01 | 6 GiB | 200% | 256 | 35 min | 45 min |
| P02 | 4 GiB | 150% | 128 | 15 min | 25 min |
| P04 | 4 GiB | 150% | 128 | 15 min | 25 min |

Both configured values and observed cgroup files must match. OOM, task-limit,
timeout or inability to read the effective limits is a test failure/NO-GO, not
a reason to silently increase a limit. A limit change requires a new review.

## Network policy

Network use is phase-separated rather than assumed absent:

- trusted acquisition: outbound access only for the fixed public Paperclip
  repository, exact runtime/checksum source if needed, and packages referenced
  by the fixed lockfile;
- untrusted installation/build/test: private network namespace with loopback
  only; no DNS route and no non-loopback interface;
- local services required by tests must bind only to loopback and terminate
  with the transient service.

This design can prove the effective namespace, interfaces, routes and negative
probes observed in the guest. It cannot prove the absence of a GitHub/Azure
control-plane defect, guest-kernel escape, or a flaw in systemd itself. If the
runner cannot create the private network namespace, no firewall-only fallback
is automatically authorized; the result is static-analysis-only pending a new
decision.

## Token, secret and private-data policy

- workflow-level `permissions: {}`;
- only `workflow_dispatch`; no `pull_request`, `push`, schedule or reusable
  workflow trigger;
- no secrets block, OIDC permission, custom token, cloud credential, paid
  provider, private checkout, artifact transfer from a private repository or
  link to AI City/Tool Intelligence/Catálogo Mestre;
- no marketplace action in the first implementation; anonymous `git` and
  locally installed standard tools avoid passing `github.token` to an action;
- the restricted service receives an explicit empty credential environment and
  has no egress even if an unexpected value existed on the host.

`permissions: {}` is necessary but not sufficient: GitHub creates a job token
context even when it is not deliberately exported. The design therefore also
uses environment separation, filesystem restrictions and network isolation.

## Cost decision

Estimated incremental cost is R$0 only while all of these remain true:

- the laboratory repository remains public;
- only a standard `ubuntu-24.04` hosted runner is used;
- no larger runner, self-hosted VM, paid storage, paid API, model provider or
  external service is introduced;
- no retained artifact is uploaded by the initial design.

GitHub currently documents standard hosted runners as free for public
repositories. Any visibility change, paid runner label, billing prompt or
uncertain quota is a pre-start NO-GO. The estimate is not a billing guarantee.

## Global GO/NO-GO criteria

Implementation may proceed to a single authorized P01 only when all are true:

1. independent review approves the workflow and every controller script by
   immutable blob/commit SHA;
2. control-only preflight proves the effective UID, capability, filesystem,
   namespace, network, cgroup, timeout and log-channel properties;
3. exact source commit, lockfile and toolchain identities are verified;
4. all workspace and dependency lifecycle scripts are inventoried; offline
   installation succeeds with scripts disabled, and each later project script
   is explicitly reviewed;
5. no secret/private data/action token is passed to the transient service;
6. the repository is public and the standard runner incurs no additional fee;
7. the owner gives explicit authorization for exactly one manual P01 run.

Any false, missing or inconclusive predicate is NO-GO. It does not authorize a
retry with weaker controls or larger limits.

## Consequences

The selected design avoids the unresolved Docker-managed `/etc` provenance
question by treating the whole fresh VM as the job boundary and systemd as a
defense-in-depth process boundary. It preserves zero incremental cost and
provides per-test disposal. It also accepts, explicitly, residual trust in the
GitHub-hosted VM image, Azure hypervisor, guest kernel, systemd, anonymous
package acquisition tools and reviewed dependency supply chain.

P01, P02 and P04 remain `planned`. No result is `tested` or `verified` under
this ADR.
