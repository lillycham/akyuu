# Sync v2 latency profile

Follow-up: the [production fix](2026-11-08-sized-reads.md) implements the bounded
reader with boundary tests. The observations below describe the earlier experiment.

## Finding

Oversized temporary read buffers cause most of the concurrent latency increase.
The existing `boundedRead` asks `ByteString.hGet` for the maximum permitted size,
plus one byte. For memories, that request is 16 MiB, even for small files.
The profile records about 87.7 GB of cumulative allocation in memory reads
per 5,000-entry validation pass. This is allocation churn, not resident memory.

A diagnostic control sizes the first read from the open file's size. It retains
the maximum bound and reads further bounded chunks if the file grows.
Every inventory file still receives its existing hash and validation checks.
No other validation logic changes.

This control reduces median paired-write latency from 4.80 s to 1.27 s.
It reduces median direct-write latency from 870 ms to 669 ms.
The original production source is restored. The control remains an experiment,
not a production fix or a performance acceptance result.

## Phase measurements

The table gives medians from three direct commits, in milliseconds.
Individual phase medians need not sum to the median total.

| Phase | Original buffers | Size-aware buffers |
| --- | ---: | ---: |
| Read and hash events | 148.6 | 149.4 |
| Decode events and check graph | 202.4 | 194.0 |
| Read, hash and parse memories | 422.0 | 250.7 |
| Complete preflight | 822.4 | 623.9 |
| Hold mutation lock | 48.9 | 47.3 |
| Complete direct commit | 870.3 | 669.3 |

The baseline spends about 94% of direct-write latency before the lock.
Lock acquisition adds about 0.1 ms in the direct samples. The object and event
save phases each take less than 1 ms. Checkpoint save and publication include
encoding and hash work, so they are not isolated measurements of disk flushes.

Preflight allocation falls from 89.6 GB to 2.14 GB per pass. Memory read, hash
and parse allocation falls from 87.7 GB to 644 MB. Event decode and graph
checks still allocate about 1.20 GB. These are decimal units and cumulative
allocation counters, not physical memory use.

## Concurrent writes

Each trial starts two writers on independent refs at a shared barrier.
All six writes succeeded in each variant. Each trial required one retry.

| Metric | Original buffers | Size-aware buffers |
| --- | ---: | ---: |
| Median time to both outcomes | 4799.2 ms | 1269.8 ms |
| Whole-command GC elapsed time, median | 3.503 s | 0.212 s |

The whole-command GC totals include repository setup and final verification.
The phase traces also place about three seconds of GC inside the overlapping
baseline memory-read intervals. They do not place that delay in the mutation lock.
Two simultaneous inventory passes increase allocation pressure. The second
writer then repeats inventory reads after the checkpoint changes.

The size-aware control cuts paired latency by 73.5% and direct latency by 23.1%.
The experiment strongly supports oversized allocation and GC as the main cause
of the concurrency increase. It does not isolate syscall time from hash time,
or parsing from other allocation within each phase.

## Runtime controls

An earlier run tested the unchanged read path with four RTS configurations.
Each configuration received three direct samples and three paired trials.

| RTS options | Direct median, ms | Pair median, ms |
| --- | ---: | ---: |
| `-N2` | 881.8 | 4868.2 |
| `-N1` | 769.4 | 9111.6 |
| `-N2 -A16m` | 891.5 | 4455.3 |
| `-N2 -qg` | 816.0 | 5964.0 |

Fewer capabilities or serial GC did not solve the concurrent cost. A larger
allocation area gave a modest improvement in these samples. Fix allocation
before a broader RTS tuning exercise.

The first logger allowed concurrent phase lines to interleave. Only command
timings and complete RTS summaries from that run support the runtime table.
Both final variants use atomic trace output. The summary parser checks trace
field counts and numeric fields. The final runs contain complete phase traces.

## Method and evidence

Base revision: `b7ac5ae`. Host: Apple M4, 16 GiB RAM, aarch64-darwin.
The library uses the Cabal development `-O1` build. Drivers use GHC 9.10.3
with `-O2`, `-T`, `-s` and a 2 GiB heap cap. Final comparisons use `-N2`.
Fixtures contain 5,000 base entries with the existing compressible body profile.
Each driver checks accepted events against reported outcomes.

Small smoke tests passed before large runs. Each subprocess has a 125-second
outer deadline; the driver has its existing 120-second deadline. Trials use
disposable synthetic stores. No live store, model or network remote was used.
No build overlapped the measurements. Normal system activity was not controlled.

The final baseline ran first, then the control. Each used its own seeded store.
Within each variant, direct samples preceded paired trials. Filesystem caches
were not cleared. These small samples do not establish tail latency or Linux
performance. The instrumented baseline matches the earlier uninstrumented
latency range, but timer and logger overhead was not independently quantified.

RTS counters are process-wide. Concurrent intervals overlap, so their GC and
allocation deltas must not be added as if each worker owned them. Allocation
counters update at GC boundaries. Lazy work belongs to the phase that forces
it; these are operational phases, not cost-centre profiles.

Raw records:

- [Final baseline](2026-11-08-profile-baseline.json)
- [Size-aware control](2026-11-08-profile-sized.json)
- [Initial runtime controls](2026-11-08-profile-runtime-controls.json)

Reproduction tools:

- [Harness](../profile-latency.cjs)
- [Trace summary](../profile-summary.cjs)
- [Baseline timer patch](../profiling/phase-timers.patch)
- [Timer and size-aware control patch](../profiling/sized-read-control.patch)

Apply one patch to a clean checkout of `b7ac5ae`; do not apply both together.
Build a separate driver for each patch with the commands in `bench/README.md`.
Use an uninstrumented `b7ac5ae` driver to seed the fixtures. Through Nix Node, run:

```sh
node bench/profile-latency.cjs SEED_DRIVER PROFILE_DRIVER OUTPUT.json 5000 N2
node bench/profile-summary.cjs OUTPUT.json > SUMMARY.json
```

Omit `N2` to run all four runtime configurations. Patches are diagnostic assets;
production source does not include the timers or the size-aware read control.

## Next work

First, make bounded reads allocate in proportion to actual input. Add focused
tests for empty files, size limits, truncation and growth before production use.
Then profile the remaining event decode and memory parse allocation. Avoid
duplicate full loads in agent operations where the snapshot contract permits it.
Further improvements require less work per inventory, not weaker corruption checks.

No merge, push, migration, application restart or production behaviour change
occurred during this profiling work.
