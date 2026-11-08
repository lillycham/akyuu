# Sync prototype iteration 2: writer preflight

This iteration moves full inventory validation before the mutation lock.
The writer checks IDENTITY and CURRENT under the lock before it publishes.
A changed checkpoint releases the lock and triggers fresh validation.
The retry limit is three validated snapshots per operation.

Resource and policy dependency versions still require a match under the
lock. Immutable dependencies still become durable before CURRENT publication.
GC and publication acknowledgement change the checkpoint identity, so they
also force a retry. The protocol bytes and command names remain unchanged.

## Method

The baseline fixture driver came from the 2026-11-07 build at `8e7807e`.
Its repository transaction code is identical to rebased `119b93a`, before
this change. The latter also includes main `6225fe7` and its GC display fix.
The candidate driver uses writer preflight from commit `4a43d19`.
Both executable hashes are in
the raw record.

The host reported Apple M4, 16 GiB RAM and aarch64-darwin.
Both drivers used GHC 9.10.3, `-O2`, two RTS capabilities and a 2 GiB heap
cap. The libraries used Cabal development builds. Both fixtures used the
compressible body profile. The harness checked equal initial checkpoint IDs.

Each fixture size has five direct-commit samples and five paired trials.
Each pair starts two writers at a shared barrier in one Haskell process.
They write independent refs. The driver checks each result against accepted
event IDs. This does not measure separate CLI processes.

The two revisions use separate disposable repositories. Trials accumulate
their accepted writes. The harness alternates which revision runs first in
paired trials. Direct-commit samples run before paired trials, baseline first.
No build or other experiment overlapped the series. Normal system activity
was not controlled. Filesystem caches were not cleared. The fixtures used
no live store or network remote.

## Results

Each timing cell shows before → after. All durations are milliseconds.
The pair timer below is the later of its two reported outcomes. A busy
error counts as an outcome; it does not count as a successful write.

| Base entries | Successful writes | Time to both outcomes, median | Direct commit, median |
| --- | ---: | ---: | ---: |
| 100 | 10/10 → 10/10 | 55.7 → 63.1 | 22.2 → 21.9 |
| 1,000 | 10/10 → 10/10 | 443.6 → 771.7 | 220.1 → 230.8 |
| 5,000 | 6/10 → 10/10 | 1165.1 → 4624.0 | 1085.3 → 1145.2 |

At 5,000 entries, the baseline returned four busy errors in ten attempts.
The candidate accepted all ten writes. Every reported result agreed with
the final accepted event inventory.

This is progress on contention, not performance acceptance. At 5,000 entries,
the two variants usually report different outcomes, so their pair durations
are not equivalent completion-time measurements. At 100 and 1,000 entries,
both variants accepted every write, but the candidate still had higher
contended latency. The direct-commit measurements show no latency improvement.

Preflight can overlap another writer's validation. A changed checkpoint
can require another full validation pass. Both effects add work. The harness
did not measure CPU shares or count retries in these timed trials. It did
not measure the held lock duration separately. Small samples do not establish
tail latency or confidence intervals.

## Verification and limits

All 1,558 tests passed in development and the native aarch64-darwin Nix
sandbox. Every native flake check passed, including packaged CLI/MCP/HTTP,
browser-script, sync/join/GC/migration, format, manual and legacy checks.
Seven new deterministic cases cover an independent writer, a stale target,
continuous checkpoint changes, GC eviction, acknowledgement, identity changes
and pointer corruption between preflight and lock acquisition.

Retry exhaustion still returns RepositoryBusy. Large imports, GC and
publication acknowledgement retain other work under the lock. This change
does not guarantee freedom from busy results under a larger workload.

The next performance target is repeated validation and retry cost. Agent
consumer integration, context byte/topic limits, Linux performance and
network fault checks also remain open. The branch remains experimental.

## Reproduction

Build a fixture driver from each revision with the existing
[experiment instructions](../README.md), then run:

```sh
nix shell --inputs-from . nixpkgs#nodejs -c node bench/lock-contention.cjs \
  /tmp/before-driver /tmp/after-driver /tmp/contention.json 100 1000 5000
```

Each driver invocation has a 120-second inner deadline and a 125-second
outer limit. The harness saves progress after each trial and removes its
own temporary stores. See the [raw record](2026-11-08-writer-preflight.json).
