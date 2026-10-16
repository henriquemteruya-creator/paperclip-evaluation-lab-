# `/etc` Docker-managed mounts: pending correlation design

The three special destinations remain rejected by the runtime allowlist:

- `/etc/hosts`
- `/etc/hostname`
- `/etc/resolv.conf`

Runs through #8 established that `docker inspect .Mounts` may not expose
matching entries for these Docker-managed files.  This does not establish that
the files are absent at runtime, nor does it establish their effective origin.

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

## Current #9 evidence policy: `.Mounts=unavailable`

The runtime collector records an empty post-start `.Mounts` response as the
sanitized state `unavailable`; it does not treat it as a Docker inspection
error.  The independent kernel evidence (stable PID and mount namespace,
effective `mountinfo`, object type, source/destination device+inode identity,
and Docker-root provenance) is still collected so that a future review can
inspect which layer was conclusive.

The Docker-managed path metadata is separately sampled in `created` and again
after `RUNTIME_READY` in `running`.  A false `metadata_present_prestart` does
not block the runtime collector: a value may legitimately be materialized only
after start.  The public log contains only the known ID plus boolean
`inspect_ok`, `metadata_present`, and (at runtime) `phase_consistent`; it never
prints a metadata path.  A runtime absence, inspection error, or a conflict
between two present phase values is still diagnostic NO-GO.

For the current diagnostic, however, `unavailable` is **not** sufficient for
`evidence_complete`: the collector requires the structured post-start report
to be `consistent` as corroboration.  This is deliberately conservative for
two reasons:

1. the host-side kernel observation and Docker metadata are related through a
   rootful daemon controlled by the runner, so neither is an independent
   attestation of the other; and
2. no approved runtime-specific proof yet explains why Docker omits these
   three managed files from `.Mounts` on this runner/version.

Therefore an unavailable `.Mounts` report produces a per-ID diagnostic NO-GO
while retaining sanitized kernel observations.  This policy is not an
authorization to relax the runtime allowlist, and the final workflow verdict
remains NO-GO even if every auxiliary diagnostic is complete.  Changing this
requirement would require new runtime evidence and an independent review.
