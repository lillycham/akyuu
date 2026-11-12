# Sync v2: validation at entry

This experiment compares `b6d66b1` with the change that checks data when it
enters the repository. A load reads the manifest and every event. It does not
read payloads. A transaction checks the events and payloads that it adds, and
their links into the accepted inventory. `replica verify` keeps the complete
check. The change does not alter protocol bytes or repository files.

## Method

The host reported Apple M4, 16 GiB RAM and aarch64-darwin. Both fixture drivers
used GHC 9.10.3, `-O2`, two RTS capabilities and a 2 GiB heap cap. Libraries
used Cabal development builds with `-O1`.

The existing `bench/lock-contention.cjs` harness ran unchanged. Each size
received five direct-commit samples and five paired trials for each revision.
Each revision used a separate disposable repository with the compressible body
profile. Filesystem caches were not cleared. Normal system activity was not
controlled. The experiment used no live store or network remote.

## Results

Cells show baseline → candidate. All durations are milliseconds. Pair duration
is the later of the two outcomes in each trial.

| Base entries | Successful writes | Direct commit, median | Pair duration, median |
| --- | ---: | ---: | ---: |
| 100 | 10/10 → 10/10 | 13.7 → 8.1 | 31.5 → 23.8 |
| 1,000 | 10/10 → 10/10 | 122.2 → 88.4 | 241.5 → 139.7 |
| 5,000 | 10/10 → 10/10 | 736.7 → 405.0 | 1146.8 → 676.1 |

At 5,000 entries, median direct latency fell by 45%. Median pair duration fell
by 41%. Both revisions accepted every write at every size.

## What remains

The cost of a write still grows with the inventory. Each load opens, hashes
and decodes one file for each event. A separate trial made the causal graph
check incremental. It gave no measurable change at 5,000 entries (about
430 ms), so that trial is not part of this change. The remaining cost is the
event files, not the graph check or the payloads.

These small samples do not establish tail latency or confidence intervals.
They do not establish cross-process or Linux performance.
