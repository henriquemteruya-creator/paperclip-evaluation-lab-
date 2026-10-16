# `/etc` Docker-managed mounts: pending correlation design

The three special destinations remain rejected by the runtime allowlist:

- `/etc/hosts`
- `/etc/hostname`
- `/etc/resolv.conf`

Run #6 established only that `docker inspect .Mounts` did not expose matching
entries while the container was in the pre-start state.  It did not establish
that the files were absent at runtime, nor did it establish their effective
origin.

## What is not sufficient

The following are evidence inputs only and cannot authorize these mounts on
their own:

- a matching string between `.Mounts[].Source` and `HostsPath`,
  `HostnamePath`, or `ResolvConfPath`;
- `ReadonlyRootfs=true`;
- a destination name, filesystem category, or an empty pre-start `.Mounts`
  collection.

## Minimum additional diagnostic for separate review

A future diagnostic, if approved separately, must collect while the container
is running and emit only known IDs and booleans.  For each of the three
destinations it must independently establish:

1. exactly one effective runtime mount at the known destination;
2. the runtime mount's read/write mode and object type;
3. whether the trusted runner can correlate the runtime mount to Docker's
   container-specific metadata without logging the source path; and
4. whether the correlation is complete, rather than merely string-equal.

That design crosses the runner/container observation boundary and needs its
own review before implementation.  Until it has reproducible evidence, the
preflight records an inconclusive diagnostic and returns NO-GO.  This document
does not authorize changing the `/etc` allowlist or executing run #7.
