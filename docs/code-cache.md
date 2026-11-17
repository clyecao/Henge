# Code-cache recycling

The JIT region is divided into eight segments by default. With a 1536 MiB
region, each segment is 192 MiB. Once the region fills, the engine stops the
guest CPUs and reclaims the oldest segment, retaining translations elsewhere.
Incoming branches are detached before the segment is reused. Per-segment
epochs invalidate the CPUs' allocation chunks; branch and return caches are
cleared at the same barrier. Rewritten instructions are synchronized in a batch.

This integrates the cache changes from upstream [PR #186](https://github.com/Leviidev/Henge/pull/186):
`7fe1b573`, `cdf2d30e`, and `819e6048`. The sysreg and timer changes in that PR
are separate from this implementation.

## Comparing modes on iPad

Set one line in Henge's `Documents/henge-env.txt`, then fully shut down the VM
and start it again:

```text
HV_JIT_SEGMENTS=8
```

Use `4` to compare larger segments, or `1` for the previous full-cache mode.
Deleting the override restores the eight-segment default. The JIT allocation
size and guest RAM allocation do not change with the segment count; tracking
segments does require additional host bookkeeping memory. Start from a cold
boot when comparing modes, using the same CPU, RAM, display, and workload.

The statistics include segment evictions, time spent reclaiming blocks,
detaching exits and synchronizing instructions, and full flushes. Compare
pause time and translation work as well as counts: smaller segments can cause
more frequent reclamation. Guest-requested invalidations and reservations too
large for a segment can still require a full flush. An oversized reservation
temporarily uses the whole region so retrying can make progress.

## Validation

On an Apple Silicon Mac:

```sh
make test-engine test-vm-lifecycle
HV_JIT_SEGMENTS=1 build/test_jit
HV_JIT_SPLIT=1 HV_JIT_POISON=1 make test-code-cache
```

Tests cover concurrent allocation, segment boundaries and wraparound,
oversized fallback, native/JIT result comparison, and repeated reclamation
with 1, 2 and 5 guest CPUs. Poisoning reclaimed memory helps expose stale
branches. GitHub Actions runs these checks before packaging the iOS app.

Device testing is still needed to measure responsiveness and memory use.
Cache recycling is not a confirmed fix for the wallpaper panic or black
wallpaper reports.
