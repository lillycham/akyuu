# TODO

Build order, from the bottom up. Each module depends only on the ones above it.

```
Id ✓ → Graph ✓ → Memory ✓ → Store ✓ → Refs ✓ → Cache ✓ → GC ✓ → Query ✓ → CLI ✓ → MCP
```

## Modules

### Done

- [x] **`Akyuu.Id`**: SHA-256 content address. Raw 32-byte digest, hex text form `sha256-…`.
- [x] **`Akyuu.Graph`**: pure relation graph. A `Monoid`, built with `singleton` and `<>`.
      Queries, `reachable`, `withinHops`, `superseded`, `heads`, `dangling`.
- [x] **`Akyuu.Memory`**: parse and render the plaintext format. `memoryId`, `memoryGraph`.
- [x] **`Akyuu.Store`**: objects on disk at `store/<2 hex>/sha256-….md`, atomic `add`, `get`, `getVerified`,
      `list`, `verify`, `trash`. Errors are a `StoreError`, so callers never catch an exception.
      Not done: a test for a crash between the write and the rename, and `verify` carrying on after a vanished file.

### `Akyuu.Refs` and `Akyuu.Supersede`

The only mutable layer: `Name -> Id`. `supersede` joins it to the store, in `Akyuu.Supersede`. It is on `feat/supersede`.

Decided:

- A ref file holds one `Id` per line, newest first. The first line is the current value.
- A name has parts: `agent/topic`. Parts use `a-z 0-9 - _ .` only. A name cannot be the start of another name.
- Compare and set under a lock: `setRef … (Unchecked | MustBeAbsent | MustBe id)`.
- Pins and temp roots are not here. GC owns them.

To do, in this order:

- [x] `Akyuu.Fs.atomicWrite`: lift it out of `Store.add`, then make `add` call it.
- [x] Pure part: `mkName`, `advance`, `retained`, `renderRef`, `parseRef`.
- [x] `openRefs`, `refPath`, `getRef`, `listRefs`.
- [x] `setRef` with the lock (a `flock` on `refs/.lock`) and the `Expected` check.
- [x] `supersede :: Store -> Refs -> Name -> Memory -> IO (Either SupersedeError Id)`, in `Akyuu.Supersede`. It lives above `Store` and `Refs`.
      Order: read the ref, add the `Supersedes` edge, `Store.add`, then `setRef (MustBe old)`.
      `supersedeFrom` takes the `old` value that the caller read, so the check covers the time that an agent spends thinking.
      On `Stale`, the new object stays in the store and GC collects it later.
- [x] Wrap `SupersedeError` (and the other module errors) in one `AkyuuError` in the CLI step. Done: `Akyuu.Error`, with `fromSupersede`.

### `Akyuu.Cache`

SQLite index. It is never the source of truth, so it can be deleted and rebuilt.

- [x] Smoke-test FTS5 in the Nix build first. Done: `sqlite-simple` (with `direct-sqlite` 2.3.29) gives SQLite 3.45.0 with `ENABLE_FTS5`.
      `create virtual table … using fts5(…, tokenize='porter unicode61')`, `match`, `bm25` and `snippet` all work.

The module and its tests are on `feat/cache`. All 78 Cache tests pass. The hardening for several agents is done.

Decided:

- `sync` is the main entry point. It diffs `Store.list` against the cached ids. `Store` does not know about the cache.
- The cache file is `<root>/cache.sqlite`. A wrong `user_version`, or a file that is not a database, means delete and start again. No migrations.
- Tables: `memories`, `edges` (no foreign key on `dst`), and an FTS5 table that keeps a copy of each body.
- GC calls `sync` after a sweep. It does not call `forget` itself.
- `ftsQuery` quotes each word, so no input is an FTS5 syntax error. A NUL counts as white space.
- Errors: `CacheSQL`, `CacheIO`, `CacheLocked`, `CacheStore`, `CorruptCache`. `Akyuu.Fs.tryAs` catches the SQLite exception.
- `openCache` runs under an exclusive `flock` on `cache.sqlite.lock`. It tries without waiting and retries for about 5 seconds, like the lock of Refs.
- `reindex` reads the whole store first. Then it clears the tables and writes the new rows in one transaction.

To do, in this order:

- [x] Pure part: `ftsQuery`.
- [x] `openCache` and `closeCache`: the schema, `PRAGMA user_version`, WAL and `busy_timeout`. Delete and recreate a bad file.
- [x] `index`, `forget`, `cachedIds`. Each one is one transaction.
- [x] `loadGraph`: one `singleton` for each `memories` row, joined with `<>`.
- [x] `sync`: read every new object first, then change the cache in one transaction. `reindex` is "empty it, then `sync`".
- [x] `search`: `bm25` order, `snippet` with `[` and `]`, and a limit.
- [x] Check that SQLite is built thread-safe, before several agents share one store. Done: a test checks that `PRAGMA compile_options` has `THREADSAFE=1` or `THREADSAFE=2`.

### `Akyuu.GC`

The module and its tests are on `feat/gc`. The suite has 426 tests, and all pass.

Decided:

- Liveness flows along an edge, from the source (newer) to the target (older). A live memory keeps a target alive if `retains` is true for the kind.
  It never flows backwards: a live old memory does not keep a newer memory that is `About` it.
- `plan` returns `nodes g` minus the live set. It never returns a root, a young object, or an `Id` that is not a node.
- Age is the modification time of the object file, not the `created` header. An agent writes `created`, and it can be old or wrong.
  The time comes into `plan` as data: `Observed` has `now` and `storedAt :: Map Id UTCTime`. An object with no known age, or a time in the future, is young.
- A young object is a root, so what it retains stays too. A new memory that points at an old one before its ref is set keeps its target.
- `Policy` holds the settings: `keepGenerations`, `gracePeriod` and `trashTTL`. `defaultPolicy`: 5 generations, one hour, seven days.
  `Observed` holds the facts of one run: `now` and `storedAt`. `sweep` and `sweepAndSync` take the time of the run as a `UTCTime`.
- `Roots` has one `Set Id` each for refs, pins and temp roots. `readRoots` reads the refs (`retained keepGenerations`) and the pins. Temp roots are set by the caller, and are not on disk.
  A corrupt ref stops GC (`GCRefs`): GC must not guess what it keeps.
- Pins are files in `pins/`, one empty file per pin, named by the `Id` (`pins/sha256-…`). `pin`, `unpin`, `listPins`.
- `snapshot` writes nothing. It runs `Cache.loadGraph`, then `extendGraph` (it reads only the objects that the cache does not have), then `storedTimes`.
  So the graph has every object, also if the cache is out of date. A memory that is in the cache but not in the store has no file time, so it counts as young. This is safe.
- `dryRun` is `snapshot`, `readRoots` and `plan`. It writes nothing: not the store, not the cache, not the lock. A test checks the files and `cachedIds`.
- `Store.add` of an object that is already there sets its file time to now (`touchFile`), and does not write the bytes. A re-added old object gets the grace period.
  The touch is the check: if the file is gone (GC moved it), `add` writes it again. The content does not change, so an object still never changes.
  This is safer than a fix in GC only, because GC cannot see an `add` that wrote nothing.
- `collect` is one whole run, under the lock: plan, then `recheck`, then `sweep` and `Cache.sync`. It returns a `RunReport`.
- `recheck` plans again just before the sweep. It adds the new objects of the store to the graph, reads the refs and pins again, and reads the file times of the planned objects only.
  It drops an object that is now pinned, under a ref, added again, or linked from a new memory.
- `sweep` phase 1 reads the file time of each object again just before the move, and skips an object that is young now.
  Then it calls `Store.trash`, and sets the file time of the trash file to the time of the run, because a rename keeps the old time.
  Phase 2 deletes trash files older than `trashTTL`, and writes the tombstone first. If the object is back in the store, it writes no tombstone.
- One run at a time: `collect`, `sweep` and `sweepAndSync` take an exclusive `flock` on `<root>/gc.lock`. It tries without waiting, like the locks of Refs and Cache.
  It retries for about one second, then returns `GCLocked`, and the run changes nothing. A second run does not wait for the first. The lock is not re-entrant.
- A tombstone is `tombstones/sha256-…` with one line: `pruned: 2026-10-10T12:00:00Z`. `lookupTombstone` reads it.
- `sweepAndSync` runs `sweep`, then `Cache.sync`, also if the sweep failed. GC does not call `forget`.
- `Store` now exports `trashPath`, and `trash` returns `StoreIO` if it cannot make the `trash` directory (it threw before).

- [x] `plan :: Policy -> Observed -> Roots -> Graph -> Set Id`: pure, so a dry run is free.
- [x] `retains :: EdgeType -> Bool`: `Supersedes` does not keep the old memory alive. The other kinds do.
- [x] Policy: keep the last N generations of a ref, and a grace period for new objects.
- [x] `sweep`: two phases. Move to `trash/`, then delete after a TTL. Leave a tombstone, so a dangling link says "pruned".
- [x] Roots: refs, pins, temp roots.
- [ ] Run it from outside (launchd or cron) with `akyuu gc`. No daemon.
- [x] Tests: a superseded memory is collected, a retained one is not, a root survives, a dry run changes nothing.
      Also: a young object survives, the sweep is two-phase, a tombstone is left, and properties of `plan`.
- [x] A re-added old object gets the grace period (`Store.add` touches the file).
- [x] A lock around a run (`gc.lock`, `GCLocked`). Tests: a run returns `GCLocked` while another thread holds the lock, and two runs at once trash each object once.
- [x] A dry run writes nothing, also not the cache.
- [x] Make the race window small: `recheck` before the sweep, and a new file time check before each move.

Not done:

- The race window is small, but it is not closed. GC and the agents share no lock. An old, unrooted object `O` in the plan still goes to `trash` in two cases:
  - Between the `Store.list` of `recheck` and the move of `O`, an agent writes a memory with a retaining edge to `O`, moves a ref to `O`, or pins `O`.
  - Between the file time check of `O` in `sweep` and its move, an agent adds `O` again.
  In both cases `O` stays in `trash` for `trashTTL`, so a person can put it back. After that, a link to it says "pruned".
  To close it, `add`, `setRef` and `pin` would have to take a shared lock that GC takes exclusively.
- The test of two runs at once does not prove that the lock excludes. Without the lock, it would also pass, because `Store.trash` skips a missing file.
  The `GCLocked` test proves the exclusion.
- Temp roots on disk, for an agent in another process.

### Query

Decided:

- The pure part is `searchResult :: SearchOptions -> Graph -> [Hit] -> SearchResult` and `neighbourList :: Id -> Graph -> [Neighbour]`.
  `search` and `neighbours` only read the cache and call them.
- The results are data (`SearchResult`, `Match`, `Neighbour`). Query makes no text. The CLI and the MCP server render the same values.
- `SearchOptions` holds the limit, the hops (default 1) and the kinds to follow as a `Set EdgeType`, so it has `Eq` and `Show`.
- The context is the neighbourhood minus the hits. It can hold a dangling target.
- Each `Match` holds `matchSupersededBy`: the memories with a `Supersedes` edge to it. Two or more is a fork. Query does not choose (see "Forks" below).
- Query does not call `Cache.sync`. The caller decides when the cache must match the store.

- [x] `search`: FTS hit, then `withinHops` to widen it to a neighbourhood.
- [x] Show `neighbours` with the direction (`Out` or `In`) and the kind. `Out` edges come first.
- [ ] Later: ranking, and embeddings as a derived index keyed by `Id`. They cache perfectly because objects never change.

### CLI (`app/Main.hs`)

The parser and the runner are in `Akyuu.CLI`, so the tests can call them. `app/Main.hs` only calls `Akyuu.CLI.main`.
The operations are in `Akyuu.Ops`, and the text of the results is in `Akyuu.Render`. The MCP server uses both, so the two front ends do the same thing.

Decided:

- `AkyuuError` is in `Akyuu.Error`. It wraps `StoreError`, `RefError`, `CacheError` and `GCError`, and has its own cases for bad input.
  `fromSupersede` turns a `SupersedeError` into `RefFailed` or `StoreFailed`, so it needs no case of its own.
  `describe` gives the text. The CLI never shows `Show`.
- The root is `--root DIR`, then `AKYUU_ROOT`. An empty value counts as none. With neither, the CLI stops with exit code 2. There is no default directory.
- The root directory must exist (`RootMissing`, exit code 1). A typo then gives an error and not a new, empty store.
  The directories inside it (`store`, `trash`, `refs`) and `cache.sqlite` are made when they are not there.
- Exit codes: 0 success, 1 a failed operation, 2 bad usage. A bad `Id`, ref name, kind or agent in the arguments is bad usage.
  `verify` exits with 1 when it finds a problem.
- `kind` and `agent` are checked at the input (`Ops.checkField`): not empty, one line, no white space at either end.
  `Akyuu.Memory` does not change. The open decision about `mkMemory` stays open (see below).
- `buildMemory` cuts the `created` time to whole seconds, because `renderMemory` keeps whole seconds only.
- `search` and `neighbours` call `Cache.sync` first. On a cache that is up to date, `sync` reads only file names.
- `get` uses `getVerified`, so it checks the hash. `get ID` prints the stored file exactly, with no line feed added.
  An `Id` that GC deleted gives "GC deleted it at …" from its tombstone.
- `ref set NAME ID` is `Unchecked` by default, as for a person who sets a ref by hand. `--new` is `MustBeAbsent`. `--expect ID` is `MustBe`.
  `Ops.setRefTo` checks that the `Id` is in the store first, so no ref points at nothing. `Akyuu.Refs` still does not look at the store.
- `supersede NAME` reads the ref. `supersede NAME --expect ID` uses `supersedeFrom`.
- `add` allows `--supersedes ID` as a plain edge. It does not move a ref.
- `neighbours` of an `Id` that is not a memory and has no edges is an error, not an empty list. A dangling target shows its edges.
- `gc` uses `defaultPolicy` and no temp roots. There are no flags for the policy yet.
- `verify` reads and hashes every object itself, and builds the graph from them, not from the cache. It reports corrupt and unreadable objects,
  missing edge targets, bad refs, and refs to a missing object. A target with a tombstone is "pruned". That is normal, so it is not a problem.
- `optparse-applicative` is a new library dependency. The Nix shell already had it. `akyuu.nix` is edited by hand to add it.
  A new run of `cabal2nix` would also add the test dependencies, and `nix build` would then run the tests. Lilly should decide that.

- [x] `add`, `get`, `supersede`, `ref set|get|list`, `search`, `neighbours`, `gc [--dry-run]`, `reindex`, `verify`.
- [x] Friendly error text from `AkyuuError`, not `Show`.
- [x] Unit tests for the parser, the error text and `Akyuu.Ops`. `test/smoke-cli.sh` runs the executable against a temp store.

Not done:

- No `pin`, `unpin` or `init` commands, and no flags for the GC policy.
- The smoke script is not part of `cabal test`. Run it by hand: `nix develop -c bash test/smoke-cli.sh`.
- `get` does not show the edges of a memory in a separate form. Use `neighbours`.

### MCP server

- [ ] Wrap the same library functions. Do this after the CLI works.

## Open decisions

- [ ] **Smart constructor for `Memory`.** `memKind` and `memAgent` must be non-empty, one line, no spaces at the ends.
      Today this is a precondition on `renderMemory` that nothing checks. Consider `mkMemory :: … -> Either MemoryError Memory`.
      For now the CLI and the MCP server check `kind` and `agent` at the input, with `Ops.checkField`.
- [ ] **Order of headers.** `parseMemory` accepts any order, so a hand-edited file can have a different `Id` from the memory it holds.
      Decide whether to accept only the canonical form.
- [ ] **Forks.** Two memories that supersede the same one are both `heads`. Choose a policy: latest by time, or keep both and flag it.
- [x] **Several agents in one store.** Decided: ref names are `agent/topic`. Memories keep `agent` as a plain header.
- [x] **`fsync`.** Done: `atomicWrite` flushes the temporary file before the rename and the directory after it.
      Not done: on macOS, `fsync` does not flush the drive cache. That needs `fcntl(F_FULLFSYNC)`, and `unix` has no wrapper for it.
      Add it through the FFI if the gap matters.
- [x] **Stale lock.** Done: the lock is an OS file lock (`flock`, from `filelock`) on `refs/.lock`. The OS releases it when the process ends.
      The lock file stays on disk. This is normal.
- [x] **Dangling targets in `reachable`.** The result can include them. Decided: GC does not rely on it either way.
      `plan` takes the live set away from `nodes g`, so a dangling target in the live set has no effect. A test and a property check this.
- [ ] **Automatic supersession.** Today an agent says so explicitly. A consolidation pass that finds superseded memories is a separate layer that emits `supersede` operations.

## Clean-up

- [ ] Remove the commented-out `breakOn'` in `src/Akyuu/Memory.hs`, or use it in `splitBody` and `splitHeader`.
- [ ] `Backward` in `WalkMode` (`src/Akyuu/Graph.hs`) is never built. Remove it, or add a test that uses it.
- [ ] `Graph` now has `Eq`, so `observe` in `test/GraphTests.hs` can become plain `===`.
- [ ] Run `ormolu` over the whole tree so the style is the same everywhere.
- [x] Cache: `tryExisting` treats every `SQLError` as "not usable", and `openCache` then deletes the file.
      A busy or locked database (`ErrorBusy`, `ErrorLocked`) must not do that. Match only `ErrorNotADatabase` and `ErrorCorrupt`.
- [x] Cache: set `PRAGMA busy_timeout` right after `open`, before `tryExisting` reads the version.
- [x] Cache: use `withImmediateTransaction` in `index`, `forget`, `sync` and `reindex`. A deferred transaction that reads and then writes can fail with `BUSY`, and the timeout does not help.
- [x] Cache: `sync` fails if GC sweeps an object between `Store.list` and `Store.get` (`NotFound`). Skip that object. Add a test.
- [x] Cache: remove `tryIO` (unused) and the `CacheIO` constructor (nothing builds it), or give it a job.
- [x] Cache: `cachedIds` has its own `toId`. Use `parseCached`.
- [x] Cache: two processes that find a bad cache at the same time can each delete the file that the other made. Done: a lock file around `openCache`, with a test that fails without it.
- [ ] Pick one style for `Akyuu.Id` imports (`qualified` at the front or the back).
- [ ] Add `-Wprepositive-qualified-module` and `-Wmissing-import-lists` to `shared` in `akyuu.cabal`, and fix what they flag.
- [ ] `Store.add`: wrap `removeFile tmp` in the cleanup with `ignoreIO`, so a cleanup error cannot hide the real one.
- [x] Move `ignoreIO` and a generic `tryWith` from `Akyuu.Store` to `Akyuu.Fs`.
- [ ] Do the same for `orNotFound` once `getRef` shows what it needs.
- [x] Add `-threaded` to the test suite, so the race test with `MustBe` can really run threads in parallel.
      Done, with `-N`. Check that the `MustBe` race test now runs threads in parallel: it is not changed yet.
