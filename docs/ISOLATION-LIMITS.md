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
