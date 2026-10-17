# TI-0093 ephemeral-VM risk matrix

This matrix supports ADR-002. It records design-time decisions only. P01, P02
and P04 remain `planned`.

| ID | Threat or failure | Initial risk | Required control | Residual risk / limit | Decision |
|---|---|---|---|---|---|
| R01 | Paperclip runs as the GitHub runner account and invokes passwordless `sudo`. | Critical | Dedicated UID outside privileged groups; transient service with `NoNewPrivileges` and empty capability sets; never execute upstream code in the controller. | Guest-kernel/local privilege escalation remains possible. | Block unless effective identity and properties are proved. |
| R02 | A compromised job reaches AI City, another private repository or a secret. | Critical | Public lab only; no private checkout; `permissions: {}`; no secrets/OIDC/custom token; clean environment; restricted filesystem; no untrusted egress. | GitHub control plane and host job context remain trusted. | Block on any credential-like environment value exposed to the service. |
| R03 | Dependency or lifecycle script exfiltrates data during install. | Critical | Networked `pnpm fetch --ignore-scripts` only in trusted acquisition; offline install with scripts disabled; static lifecycle inventory; execute only separately reviewed project scripts after network isolation. | Package-manager parsing and package supply chain remain trusted inputs. | Block on any unreviewed script or online install. |
| R04 | Paperclip opens an external connection during build/test. | High | `PrivateNetwork=yes`; loopback-only interface/route checks; negative DNS, TCP and HTTPS probes under the same service profile. | Kernel/systemd defect could defeat the namespace. | Block if namespace or probes are inconclusive. |
| R05 | Paperclip escapes process limits or exhausts the VM. | High | Cgroup v2 `MemoryMax`, `CPUQuota`, `TasksMax`, service runtime and outer timeout; inspect effective values and terminal state. | Host-level transient pressure before enforcement and kernel bugs remain. | Limit violation is test failure; no automatic increase. |
| R06 | A test writes outside its work directory or reads unrelated runner files. | High | `ProtectSystem=strict`, `ProtectHome`, `PrivateTmp`, `PrivateDevices`, explicit writable path, dedicated UID, root-owned controller/logs. | Not a separate kernel boundary; permitted public system files remain readable. | Block if write/read restrictions cannot be demonstrated. |
| R07 | Malicious stdout injects Actions commands or corrupts evidence. | High | Redirect raw output to a root-owned private file; trusted strict parser emits bounded allowlisted fields only; no raw `tee`. | Parser bugs and terminal-control sequences in allowed fields. | Reject malformed/unbounded records; hash raw file before disposal. |
| R08 | Mutable source, dependency or tool version undermines reproducibility. | High | Full Paperclip SHA; frozen lockfile; exact pnpm version; runtime version and checksums; record runner image identifier and manifest hashes. | Hosted runner image changes weekly; upstream package archives could disappear. | Missing identity or drift is NO-GO. |
| R09 | Separate tests influence each other. | Medium | One independent hosted VM/job per P01/P02/P04; no cache or artifact imported from another test; repeat bootstrap. | Common upstream package sources and runner image remain shared dependencies. | No cross-job state accepted. |
| R10 | A public-fork or automatic event executes unreviewed workflow changes. | High | Only `workflow_dispatch`; draft review; explicit immutable SHA check; no PR/push trigger. | Authorized operator could select the wrong ref. | Manual pre-run SHA confirmation required. |
| R11 | `permissions: {}` is treated as proof that no token exists. | High | Do not reference `github.token`; no actions; scrub environment and GitHub file-command variables; filesystem isolation plus no egress. | Platform token context exists at the trusted control-plane layer. | Any token visible to restricted service is NO-GO. |
| R12 | Network isolation blocks Actions completion/logging. | Medium | Isolate only the transient service network namespace, not the Actions runner host. | Trusted host retains egress throughout the job. | Accept for controller only; Paperclip remains isolated. |
| R13 | Static review misses harmful code in a dependency. | High | Exact lockfile, no lifecycle scripts, network isolation, resource/filesystem controls, sanitized output and disposable VM. | Full dependency proof is infeasible; runtime and kernel escape risks remain. | Residual risk requires explicit acceptance before P01. |
| R14 | Hosted VM is assumed absolutely isolated. | High | State boundary accurately; verify observable guest controls; use fresh standard VM per job. | Hypervisor, GitHub/Azure control plane and guest kernel are not independently attested by the lab. | Accept only as documented platform trust, otherwise static-only. |
| R15 | Additional GitHub usage produces a charge. | Medium | Public repository, standard runner only, no larger runner/artifact/paid API; pre-start visibility and label checks. | GitHub pricing/policy can change. | Billing uncertainty or paid label is NO-GO. |
| R16 | Embedded database/server exposes a listening port. | High | Private namespace; bind local services to loopback; inspect listening sockets; terminate service cgroup as a unit. | In-namespace test processes can reach one another by design. | Accept loopback only; any non-loopback listener is NO-GO. |
| R17 | Full upstream suite exceeds proposed bounds and is silently reduced. | High | Run the exact root `test:run`; record command/hash/counts; timeout/OOM is a failed P01. | Suite may genuinely need adjusted resources. | A subset cannot be reported as P01; limit change needs new review. |
| R18 | P02/P04 accidentally call a real model or paid provider. | Critical | Network-off service; no provider credentials; deterministic local fixtures; synthetic cost events only; assert zero external adapter invocation. | A mock may not model provider behavior. | That limitation is explicit; real-provider behavior remains unverified. |

## Residual-risk acceptance boundary

The design can demonstrate guest-observable process identity, capabilities,
systemd sandbox properties, cgroup values, network namespace state, negative
egress probes, exact source/tool identities and command outcomes. It cannot
independently prove the GitHub/Azure hypervisor, runner image, guest kernel,
systemd implementation or complete dependency supply chain safe.

If that platform trust is unacceptable, the only zero-cost option currently
approved by this decision is static analysis. No result may then advance from
`planned` to `tested`.
