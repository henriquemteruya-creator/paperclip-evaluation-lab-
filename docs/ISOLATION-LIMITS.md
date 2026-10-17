# Isolation boundary and user-namespace limit

This laboratory workflow is a diagnostic gate, not a sandbox proof and not an
authorization to run Paperclip.

The GitHub-hosted runner is trusted infrastructure only.  It controls the
rootful Docker daemon used to create the diagnostic container.  The workflow
checks the container's non-root UID/GID, dropped capabilities,
`no-new-privileges`, read-only root filesystem, resource limits, closed network
and effective mounts.  Those controls reduce exposure inside the container;
they do not make the runner or Docker daemon untrusted-code safe.

In particular, the workflow has no evidence that the container uses a user
namespace distinct from the host user namespace.  It must therefore not claim
kernel-user-namespace isolation, and a later GO for this preflight must not be
interpreted as approval to execute Paperclip, P01, P02 or P04.

Any later execution proposal must be separately reviewed for its code,
inputs, network policy, image provenance and the remaining rootful-Docker
shared-kernel boundary.

## Closed host-source viability attempt

The host-side source gate executed in run #13 but returned the sanitized code
`timeout` for all three Docker-managed `/etc` IDs. The stage that timed out was
not identified. Consequently, the recorded status is
`host_source_viability=unproven`, not a finding that the backing files are
proven inaccessible.

This ambiguity does not erase the positive run #8 evidence for the eight
destination-specific masked mounts or for UID/GID, capabilities,
`no-new-privileges`, read-only root, resource bounds, socket scan, routes, and
negative egress probes. It also does not elevate those checks into proof of VM,
process, network, or kernel isolation beyond their tested predicates.

The private container-to-runner evidence protocol is blocked. The independent
`.Mounts=unavailable` policy still prevents `evidence_complete`; rootful Docker
still shares the runner kernel boundary; and a separate user namespace remains
unproved. A new architecture decision and independent review are mandatory
before another preflight run or any Paperclip P01/P02/P04 test. Increasing a
timeout or privilege and rerunning the same design is not authorized.
