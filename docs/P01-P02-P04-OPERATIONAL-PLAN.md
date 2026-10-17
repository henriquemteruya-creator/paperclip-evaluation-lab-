# TI-0093 operational plan for P01, P02 and P04

- Plan status: `planned`
- Execution performed by this plan: no
- Paperclip revision: `aa04c5c2a7044ca008aa0d16550dbfb394227247`
- Governing decision: `docs/ADR-002-EPHEMERAL-VM-EVALUATION.md`

## Result vocabulary

- `planned`: commands, inputs and acceptance criteria have been reviewed, but
  the test has not executed under the approved boundary;
- `tested`: the documented command executed at the fixed revision and produced
  retained evidence, whether pass or fail;
- `verified`: a `tested` result was independently reproduced or its complete
  evidence was independently reviewed against the protocol.

No test in this document is currently `tested` or `verified`.

## Common procedure

Each test uses a separate manually dispatched job and fresh standard
`ubuntu-24.04` VM. There is no dependency, cache or artifact transfer between
jobs. Each job repeats the following stages:

1. **Control gate:** verify public repository, exact workflow/ref,
   `permissions: {}`, required host tools, cgroup v2 and systemd sandbox
   properties using a benign command only.
2. **Pinned acquisition:** anonymous fetch of the full Paperclip SHA; verify
   manifest/lock/script hashes and tool versions; run only frozen package fetch
   with lifecycle scripts disabled.
3. **Dependency gate:** produce and compare the lifecycle/native-binary
   inventory with the independently approved allowlist. No Paperclip script is
   run yet.
4. **Restricted setup:** create the dedicated UID and transient-service policy;
   prove clean environment, filesystem restrictions, resource ceilings,
   loopback-only network and negative DNS/TCP/HTTPS probes.
5. **Offline execution:** install from the prepared store with
   `--offline --frozen-lockfile --ignore-scripts`, then run only approved
   commands in the transient service.
6. **Evidence:** trusted host parser records immutable inputs, effective limits,
   exit statuses, bounded test counts/names, timings and hashes. Raw untrusted
   output is not streamed or retained after VM disposal.
7. **Cleanup:** stop the complete service cgroup and let GitHub discard the VM.

Any failure or unparseable observation stops the job. A stopped gate is not a
failed product test; it is NO-GO/infrastructure evidence and the test remains
`planned`.

## P01 — installation, build and upstream suite

### Purpose and status

Demonstrate that the fixed Paperclip revision can be installed from the frozen
store, built and run through its complete upstream test command inside the
approved boundary. Status: `planned`.

### Preconditions

- all common gates pass;
- Node.js satisfies the upstream `>=24.11.0` engine and is identified by exact
  version/hash or runner-image manifest;
- pnpm is exactly `9.15.4`;
- the fixed lockfile resolves completely during trusted acquisition;
- static review approves `scripts/link-plugin-dev-sdk.mjs`,
  `scripts/ensure-workspace-package-links.ts`,
  `scripts/run-vitest-stable.mjs` and every workspace script reachable from
  build/typecheck/test;
- dependency lifecycle scripts remain disabled. If a native dependency cannot
  work without one, P01 is NO-GO pending a separate script-specific review;
- one explicit authorization names the workflow commit and allows one run.

### Planned inputs and commands

The implementation may express these operations differently, but must preserve
their semantics and record each exit status:

```bash
git init "$SOURCE_DIR"
git -C "$SOURCE_DIR" remote add origin https://github.com/paperclipai/paperclip.git
git -C "$SOURCE_DIR" fetch --depth=1 origin aa04c5c2a7044ca008aa0d16550dbfb394227247
git -C "$SOURCE_DIR" checkout --detach FETCH_HEAD
test "$(git -C "$SOURCE_DIR" rev-parse HEAD)" = aa04c5c2a7044ca008aa0d16550dbfb394227247

# Trusted acquisition, before the restricted execution phase:
pnpm fetch --frozen-lockfile --ignore-scripts

# Restricted UID, private network, offline store:
pnpm install --offline --frozen-lockfile --ignore-scripts
node scripts/link-plugin-dev-sdk.mjs
pnpm run build
pnpm run typecheck
pnpm run test:run
```

The explicit root postinstall script is invoked only because installation was
performed with scripts disabled and only after its independent review. No
transitive lifecycle script is implicitly re-enabled. The final command must
remain the upstream complete suite; replacing it with a subset does not pass
P01.

### Limits and evidence

- MemoryMax 6 GiB, CPUQuota 200%, TasksMax 256;
- command deadline 35 minutes, job deadline 45 minutes;
- source SHA, manifest/lock/script hashes, Node/pnpm versions and runner image
  identifier;
- effective sandbox/cgroup/network observations and negative probes;
- install/build/typecheck/test exit codes and durations;
- total/passed/failed/skipped test counts and a bounded sanitized list of
  failures;
- raw-log SHA-256 and parser version, without publishing raw output.

### PASS / NO-GO

PASS requires every gate and command to return zero, the exact full suite to
complete inside the fixed limits, and no network/socket/policy violation. A
timeout, OOM, task limit, missing dependency, lifecycle requirement, flaky
retry, skipped build/typecheck or partial suite is not PASS. After a successful
run the status becomes `tested: pass`; independent evidence review is required
for `verified`.

## P02 — hierarchy, delegation and governance

### Purpose and status

Exercise agent reporting hierarchy, task delegation and authorization without
models or external providers. Status: `planned` and logically gated on a P01
pass/verification decision.

### Preconditions and fixtures

- all common gates repeat in a new VM;
- relevant upstream implementations and tests are reviewed, including
  `reportsTo`, `canCreateAgents`, `canAssignTasks`, company scoping and
  authorization routes;
- a small lab-owned deterministic fixture is independently reviewed before use;
- local database/service binds only to loopback inside the private namespace;
- provider credentials are absent and provider adapters are disabled/asserted
  uncalled.

The fixture will create synthetic identifiers for one company, a manager, two
direct reports and an unrelated agent. It will create a parent task and child
task, attempt permitted manager-to-report delegation, then attempt denied
cross-company, unrelated-agent and insufficient-permission operations. If the
implementation supports cycle prevention, a reporting-cycle attempt is also
required; absence of such a control is recorded as a product finding, not
silently treated as equivalent governance.

### Planned commands

First run the exact targeted upstream tests under the restricted service:

```bash
pnpm exec vitest run --no-file-parallelism --maxWorkers=1 \
  server/src/__tests__/agent-permissions-routes.test.ts \
  server/src/__tests__/authorization-service.test.ts
```

Then run the separately reviewed deterministic P02 fixture. Its final command
and hash must be fixed during implementation review; it is intentionally not
invented or executed by this planning document.

### Limits and evidence

- MemoryMax 4 GiB, CPUQuota 150%, TasksMax 128;
- command deadline 15 minutes, job deadline 25 minutes;
- sanitized topology by role IDs only, requested operations and boolean
  allow/deny outcomes;
- database/service binding evidence, zero external adapter calls and negative
  egress probes;
- upstream and fixture command hashes, exit codes, counts and duration.

### PASS / NO-GO

PASS requires the manager/report hierarchy to persist locally, permitted
delegation to succeed, every forbidden case to be denied without partial
mutation, and all upstream authorization tests to pass. Missing fixture,
ambiguous authorization, non-loopback listener, provider call or unreviewed
behavior is NO-GO. Passing P02 demonstrates only the tested synthetic cases;
it does not establish equivalence with AI City or production governance.

## P04 — synthetic budget limits and financial blocking

### Purpose and status

Exercise Paperclip budget accounting and blocking with synthetic cents only,
without a model, payment system or paid API. Status: `planned` and logically
gated on P01.

### Preconditions and fixtures

- all common gates repeat in a new VM;
- `server/src/services/budgets.ts` and
  `server/src/__tests__/budgets-service.test.ts` are reviewed at the fixed SHA;
- no provider key, billing credential, model endpoint or external adapter is
  configured;
- all monetary events are deterministic integer `costCents` fixtures;
- a spy/assertion proves no provider adapter was invoked.

### Planned commands and cases

Run the upstream budget service test under the restricted service:

```bash
pnpm exec vitest run --no-file-parallelism --maxWorkers=1 \
  server/src/__tests__/budgets-service.test.ts
```

A separately reviewed fixture, if needed to cover protocol gaps, will apply
synthetic events at zero, below the cap, exactly at the cap and above the cap.
It must verify accounting, hard-stop behavior and the expected pause/cancel
state without contacting a provider. The fixture command/hash is fixed only
after implementation review.

### Limits and evidence

- MemoryMax 4 GiB, CPUQuota 150%, TasksMax 128;
- command deadline 15 minutes, job deadline 25 minutes;
- synthetic input table and resulting state using IDs/integers only;
- exact cap comparison outcomes, blocked operation count and zero provider
  invocation count;
- effective isolation, exit codes, test counts, duration and output hash.

### PASS / NO-GO

PASS requires exact deterministic accounting and the documented block at the
cap/over-cap boundary for all approved cases, with zero provider calls and no
network violation. Float-dependent, externally billed, credential-dependent or
ambiguous outcomes are NO-GO. P04 cannot verify the accuracy of a real
provider's usage reporting because real providers are expressly excluded.

## Short implementation sequence

1. Obtain independent approval of ADR-002, this plan and the risk matrix.
2. In a new branch/PR, add only a control-plane preflight for the standard VM;
   run no Paperclip and prove systemd, namespace, cgroup, filesystem, logging
   and negative-network predicates.
3. After review of that evidence, add an acquisition-only stage fixed to the
   Paperclip SHA and produce the dependency/lifecycle inventory without
   executing package or project scripts.
4. Independently review the inventory and the exact P01 command wrapper.
5. Request authorization for one manual P01 run at an immutable workflow SHA.
6. Review and classify P01 evidence before implementing P02 or P04 fixtures.

The first concrete implementation step is therefore a new, control-only
workflow on a separate branch—not a modification or rerun of the closed Docker
preflight. PR #1 remains draft as the historical/design record until the owner
decides how to separate the later implementation.
