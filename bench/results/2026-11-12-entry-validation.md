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

## What remained after the first change

The cost of a write still grew with the inventory. Each load opened, hashed
and decoded one file for each event. A separate trial made the causal graph
check incremental. It gave no measurable change at 5,000 entries (about
430 ms), so that trial is not part of this change. The remaining cost was the
event files, not the graph check or the payloads.

These small samples do not establish tail latency or confidence intervals.
They do not establish cross-process or Linux performance.

## Follow-up: event pack and one render for each decode

A micro-benchmark of the 5,191 event files of the 5,000-entry fixture gave
these costs for one load: about 146 ms to open and read the files, 5 ms to
hash them, and 174 ms to decode them. A decode rendered the canonical bytes
twice and escaped each string one character at a time.

Two changes followed. A decode now renders an event once, and a string with
no special character skips the escape step. The decode cost fell to about
80 ms. A load now takes event bytes from `events.pack`, one append-only file,
and checks each record by its hash against the manifest. The event files stay
the durable copy. A plain load at 5,000 entries fell from 358 ms to 139 ms.

The same harness compared three builds: `b6d66b1`, the entry-validation
change, and the pack with the decode change. Cells show the three medians in
that order, in milliseconds.

| Base entries | Direct commit, median | Pair duration, median |
| --- | ---: | ---: |
| 100 | 13.6 → 7.8 → 4.4 | 33.2 → 23.0 → 16.9 |
| 1,000 | 128.8 → 77.9 → 34.1 | 224.3 → 127.0 → 54.9 |
| 5,000 | 713.7 → 398.1 → 186.1 | 1138.6 → 699.2 → 315.8 |

Every build accepted every write. The cost still grows with the inventory.
The remainder is the decode of each event and the full checkpoint manifest,
which is 1.7 MB at 5,000 unpublished entries and is read, parsed and written
again for each write.
