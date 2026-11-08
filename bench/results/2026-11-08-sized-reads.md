# Size-aware bounded reads

The production implementation now sizes its first read from the open file's
size. Small memories no longer request a temporary 16 MiB buffer.
This addresses the allocation problem in the
[latency profile](2026-11-08-latency-profile.md).

## Read contract

`Akyuu.Fs.hGetBounded` accepts a byte cap and a size hint. The hint controls
only the first allocation. A full read continues in chunks of at most 64 KiB
until EOF or the cap. The repository requests its existing limit plus one byte,
so oversized input still fails before hash verification.

The open handle supplies the size hint. Path replacement cannot switch that
handle to another file. An underestimated hint does not stop the read early.
Growth cannot bypass the byte cap. Truncation stops at EOF. Existing hash, canonical-format,
graph and residency checks remain unchanged. The reader uses no persistent cache.

## Comparison

Baseline code: `b7ac5ae`, also unchanged in profiling commit `a4782f4`.
The candidate contains the production helper and repository integration, without
phase timers. Both drivers use GHC 9.10.3, `-O2`, two capabilities and a
2 GiB heap cap. Libraries use Cabal development `-O1` builds.
The host reports Apple M4, 16 GiB RAM and aarch64-darwin.

The unchanged `bench/lock-contention.cjs` harness runs five direct samples and
five paired trials per size. Initial fixture checkpoints match. Every reported
outcome agrees with accepted events. A separate 100-entry smoke test passed first.
The [raw record](2026-11-08-sized-reads.json) includes binary checksums and all samples.

Cells show baseline → candidate. Durations are milliseconds. Pair duration is
the later of the two outcomes in each trial.

| Base entries | Successful writes | Direct median | Pair median |
| --- | ---: | ---: | ---: |
| 100 | 10/10 → 10/10 | 21.6 → 12.4 | 46.0 → 33.1 |
| 1,000 | 10/10 → 10/10 | 154.0 → 127.1 | 496.7 → 222.3 |
| 5,000 | 10/10 → 10/10 | 830.7 → 663.1 | 3690.2 → 1201.5 |

At 5,000 entries, direct latency falls by 20.2% and paired latency by 67.4%.
All writes succeed at every size in both variants.

Each revision uses a separate disposable synthetic store with compressible bodies.
Direct samples run baseline first. Paired trials alternate the first revision.
Accepted writes accumulate. No build overlaps the comparison. Normal system
activity is not controlled, and filesystem caches are not cleared. The experiment
uses no live store or network remote.

These small samples do not establish tail latency or Linux performance. The
baseline differs from earlier runs; compare variants within this run. Whole
inventory reads and decoding remain substantial costs. Performance acceptance
and ordinary agent integration remain open.

## Validation

All 1,582 development tests passed. Fourteen new cases cover empty files, zero
and negative bounds, short and exact-size input, oversized input, stale hints,
multi-chunk growth, growth after size observation, truncation and repository limits.
The repository cases cover memories, events and checkpoints. Existing corruption,
retry, GC, stale-writer and process-death tests also pass.

Native Nix `replica` and `format` checks passed. Packaged checks cover CLI, MCP,
HTTP, sync, join, GC, pin, conflicts and migration.

No merge, push, live-store migration or client restart occurred.
