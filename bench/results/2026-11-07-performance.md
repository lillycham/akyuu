# Replica performance: remove repeated work, 2026-11-07

The changes reduce repeated inventory reads and dependency writes. They also
remove duplicate work from unchanged sync. Performance acceptance remains
open because one independent writer still returned busy at 5,000 entries.

## Changes

- Transactions reuse the payload map from their verified snapshot. GC plans
  and incoming archive preparation use the same approach.
- Transactions save only new payloads, new events and required restorations.
  Accepted files were already durable before their earlier CURRENT publication.
  New but unaccepted preparations still receive a directory flush on retry.
- Unchanged sync validates its fetched Git bundle once. It does not read that
  same commit again as the previous tip.
- A verified incoming inventory already present locally needs no import.
  Concurrent writes cannot invalidate that subset check: accepted sets only grow.

Every new snapshot load still verifies the complete on-disk inventory.
The change adds no persistent validation cache. Corrupt accepted bytes still
cause an error, including on transactions and unchanged sync.

## Method

The baseline was commit `1dfd5bc`. The candidate is commit `8e7807e`.
Both used the same fixture driver, data profile, sizes and sample counts.

The host reported Apple M4, 16 GiB RAM and native
aarch64-darwin. The driver used GHC 9.10.3, `-O2`, two RTS capabilities and
a 2 GiB heap cap. The library and executable used Cabal development builds.
The body profile was `compressible`, as in the original experiment.

The baseline ran before the candidate. No build or other experiment ran
during the measured series. Normal system activity was not controlled.
Reads used ordinary filesystem caches. The runs used fresh disposable
repositories and local bare Git remotes. They used no live store.

Local metrics have five observations. Their clocks exclude process startup.
Unchanged sync has three observations; its clock includes CLI startup.
Initial publication and join each have one observation in the raw records.
These samples do not establish tail latency or statistical confidence.
No CPU profile or syscall trace was collected.

## Results

Each cell shows before → after. Commit and topic replacement use milliseconds.
Unchanged sync uses seconds. Values are medians.

| Base entries | Direct commit, ms | Topic replacement, ms | Unchanged sync, s |
| --- | ---: | ---: | ---: |
| 100 | 38 → 23 | 81 → 58 | 0.70 → 0.47 |
| 1,000 | 321 → 211 | 664 → 564 | 2.48 → 1.60 |
| 5,000 | 1721 → 1094 | 3651 → 3119 | 9.51 → 7.44 |

At 5,000 entries, median direct commit time fell by 36.4%, topic replacement
by 14.6% and unchanged sync by 21.8%.

The direct commit clock includes lock acquisition, the transaction and
release. It approximates an uncontended lock window. It does not measure
lock duration separately.

Two independent commits started at a shared barrier. Both succeeded at 100
and 1,000 entries in each build. At 5,000 entries, one returned busy in each
build. The successful commit took 1,879.749 ms before and 1,242.749 ms after.
The busy outcomes took 1,141.427 ms and 1,156.946 ms. Accepted state agreed
with every reported result. Contention is still an acceptance blocker.

The 5,000-entry snapshot median was 939 → 951 ms, configured context
1,285 → 1,294 ms, search 1,114 → 1,193 ms, and archive 2,660 → 2,562 ms.
These paths still perform full inventory work. The observations do not
establish a general read or archive speed improvement. Initial publication
was 8.16 → 8.13 s and join was 12.72 → 11.64 s, each with one observation.

## Validation and remaining work

All 1,550 tests passed in the development shell and native aarch64-darwin
Nix sandbox. Every native flake check passed, including packaged
CLI/MCP/HTTP, browser-script, sync/join/GC/migration, format, manual and
legacy compatibility checks.
The tests cover corruption after a previous successful load, unchanged-sync
corruption, remote rewrite refusal, pending exports, eviction/restoration,
concurrent writes and process death.

Full inventory work remains a large cost: the snapshot-only median was
951 ms at 5,000 entries. A future change could prepare verified state
outside the writer lock, then check
CURRENT under the lock before publication. It must handle concurrent writes,
GC and bounded retries. This experiment does not establish that design.

Linux performance, HTTPS/network fault tests, consumer integration and live
cutover remain open.

## Records and reproduction

- [Before](2026-11-07-performance/before.json)
- [After](2026-11-07-performance/after.json)

Use the existing [experiment guide](../README.md). Preserve an executable
and fixture driver for each revision, then run `bench/run-sync-v1.cjs` with
sizes `100 1000 5000`. Run the series sequentially. The driver uses its
existing deadlines and removes its own disposable fixtures.
