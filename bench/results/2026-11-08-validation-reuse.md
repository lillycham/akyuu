# Sync v2: reuse of validated values

This experiment compares `0566400` with the validation changes on
`codex/sync-v2-validation`. It reduces repeated event construction and retry
decoding. It does not change protocol bytes or introduce a persistent cache.

## Changes and safety boundary

Wire imports no longer reconstruct each event after the parser validates it.
Local writes and merges reuse events from private validated state. They still
check the complete combined causal graph. Incoming local events retain their
canonical construction checks, including record updates from callers.

A transaction retry reuses parsed events and memories from its previous attempt.
It still reads and hashes every inventory file. Missing and corrupt files remain
errors. New events receive wire checks. The combined graph, payload links and
residency receive full checks. A smaller event inventory forces fresh state
construction. The retry cache lasts for one transaction only.

## Method

The host reported Apple M4, 16 GiB RAM and aarch64-darwin. Both fixture drivers
used GHC 9.10.3, `-O2`, two RTS capabilities and a 2 GiB heap cap.
Libraries used Cabal development builds with `-O1`.
The baseline binary checksum matches the previous writer-preflight report.
The [raw record](2026-11-08-validation-reuse.json) contains both binary checksums
and every sample.

The existing `bench/lock-contention.cjs` harness ran unchanged. A separate
100-entry smoke test passed before the comparison. Each size then received
five direct-commit samples and five paired trials. Each pair used independent
refs, a shared start barrier and two writers in one process. The harness checked
equal initial checkpoint IDs and accepted event inventories.

Each revision used a separate disposable repository. The fixtures used the
compressible body profile. Samples accumulated accepted writes. Direct samples
ran baseline first. Paired trials alternated which revision ran first.
No build or other agent experiment overlapped the comparison. Normal system
activity was not controlled. Filesystem caches were not cleared. The experiment
used no live store or network remote.

## Results

Cells show baseline → candidate. All durations are milliseconds. Pair duration
is the later of the two outcomes in each trial.

| Base entries | Successful writes | Direct commit, median | Pair duration, median |
| --- | ---: | ---: | ---: |
| 100 | 10/10 → 10/10 | 22.9 → 16.1 | 71.5 → 46.1 |
| 1,000 | 10/10 → 10/10 | 222.9 → 163.5 | 743.4 → 558.1 |
| 5,000 | 10/10 → 10/10 | 1117.9 → 813.1 | 6376.9 → 4918.7 |

At 5,000 entries, median direct latency fell by 27.3%. Median pair duration
fell by 22.9%. Both revisions accepted every write at every size.

These small samples do not establish tail latency or confidence intervals.
The baseline pair median differs from the earlier report, which shows why
comparisons must use the same run. The harness does not measure CPU allocation,
retry counts or held lock duration. These results do not isolate the contribution
of each change. They do not establish cross-process or Linux performance.

## Verification and remaining work

All 1,568 development tests passed. Ten new cases cover construction equivalence,
incremental import errors, incoming record updates, checkpoint rollback, and
corrupt or missing inventory files between retry attempts. Existing GC,
acknowledgement, stale-writer, retry-limit and process-death tests remain active.
Native Nix `replica` and `format` checks also passed. These include packaged
CLI, MCP, HTTP, sync, join, GC, pin, conflict and migration smoke checks.

Whole-inventory reads, hashes and graph checks remain proportional to store size.
The measured contended latency remains too large for performance acceptance.
Ordinary agent integration, Linux and network acceptance remain open.
No merge, push, live-store migration or client restart occurred.
