# TODO

Build order, from the bottom up. Each module depends only on the ones above it.

```
Id ✓ → Graph ✓ → Memory ✓ → Store ✓ → Refs → Cache → GC → Query → CLI → MCP
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

### `Akyuu.Refs` (next)

The only mutable layer: `Name -> Id`.

- [ ] Atomic update (temp file and rename).
- [ ] `supersede`: add a new memory with a `supersedes` edge, then move the ref.
- [ ] Keep a short history of each ref (generations), for GC retention.
- [ ] Pins, and temp roots for live agent sessions, so GC cannot race a session.

### `Akyuu.Cache`

SQLite index. It is never the source of truth, so it can be deleted and rebuilt.

- [ ] Smoke-test FTS5 in the Nix build first. If `sqlite-simple` links system SQLite, it may be missing.
- [ ] Tables: `edges (src, kind, dst)`, FTS5 over bodies.
- [ ] `reindex = foldMap memoryGraph` over the store, inside one transaction.
- [ ] `PRAGMA user_version`. On a mismatch, delete the database and reindex. No migrations.
- [ ] `PRAGMA journal_mode=WAL` if several agents share one store.
- [ ] Load edges into an in-memory `Graph` for GC and search. Keep the algorithms in Haskell, not in SQL.

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
- [ ] **Several agents in one store.** `agent` could be a namespace. Decide before the `Refs` layout is fixed.
- [ ] **Dangling targets in `reachable`.** The result can include them. Decide whether GC may rely on that.
- [ ] **Automatic supersession.** Today an agent says so explicitly. A consolidation pass that finds superseded memories is a separate layer that emits `supersede` operations.

## Clean-up

- [ ] Remove the commented-out `breakOn'` in `src/Akyuu/Memory.hs`, or use it in `splitBody` and `splitHeader`.
- [ ] `Backward` in `WalkMode` (`src/Akyuu/Graph.hs`) is never built. Remove it, or add a test that uses it.
- [ ] `Graph` now has `Eq`, so `observe` in `test/GraphTests.hs` can become plain `===`.
- [ ] Run `ormolu` over the whole tree so the style is the same everywhere.
- [ ] Pick one style for `Akyuu.Id` imports (`qualified` at the front or the back).
