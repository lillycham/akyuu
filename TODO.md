# TODO

Build order, from the bottom up. Each module depends only on the ones above it.

```
Id ✓ → Graph ✓ → Memory ✓ → Store ✓ → Refs ✓ → Cache ✓ → GC → Query → CLI → MCP
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
- [ ] Wrap `SupersedeError` (and the other module errors) in one `AkyuuError` in the CLI step.

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

- [ ] `plan :: Policy -> Roots -> Graph -> Set Id`: pure, so a dry run is free.
- [ ] `retains :: EdgeType -> Bool`: `Supersedes` does not keep the old memory alive. The other kinds do.
- [ ] Policy: keep the last N generations of a ref, and a grace period for new objects.
- [ ] `sweep`: two phases. Move to `trash/`, then delete after a TTL. Leave a tombstone, so a dangling link says "pruned".
- [ ] Roots: refs, pins, temp roots.
- [ ] Run it from outside (launchd or cron) with `akyuu gc`. No daemon.
- [ ] Tests: a superseded memory is collected, a retained one is not, a root survives, a dry run changes nothing.

### Query

- [ ] `search`: FTS hit, then `withinHops` to widen it to a neighbourhood.
- [ ] Show `neighbours` with the direction (`Out` or `In`) and the kind.
- [ ] Later: ranking, and embeddings as a derived index keyed by `Id`. They cache perfectly because objects never change.

### CLI (`app/Main.hs`)

- [ ] `add`, `get`, `supersede`, `ref set|get`, `search`, `neighbours`, `gc [--dry-run]`, `reindex`, `verify`.
- [ ] Friendly error text from `AkyuuError`, not `Show`.

### MCP server

- [ ] Wrap the same library functions. Do this after the CLI works.

## Open decisions

- [ ] **Smart constructor for `Memory`.** `memKind` and `memAgent` must be non-empty, one line, no spaces at the ends.
      Today this is a precondition on `renderMemory` that nothing checks. Consider `mkMemory :: … -> Either MemoryError Memory`.
- [ ] **Order of headers.** `parseMemory` accepts any order, so a hand-edited file can have a different `Id` from the memory it holds.
      Decide whether to accept only the canonical form.
- [ ] **Forks.** Two memories that supersede the same one are both `heads`. Choose a policy: latest by time, or keep both and flag it.
- [x] **Several agents in one store.** Decided: ref names are `agent/topic`. Memories keep `agent` as a plain header.
- [x] **`fsync`.** Done: `atomicWrite` flushes the temporary file before the rename and the directory after it.
      Not done: on macOS, `fsync` does not flush the drive cache. That needs `fcntl(F_FULLFSYNC)`, and `unix` has no wrapper for it.
      Add it through the FFI if the gap matters.
- [x] **Stale lock.** Done: the lock is an OS file lock (`flock`, from `filelock`) on `refs/.lock`. The OS releases it when the process ends.
      The lock file stays on disk. This is normal.
- [ ] **Dangling targets in `reachable`.** The result can include them. Decide whether GC may rely on that.
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
