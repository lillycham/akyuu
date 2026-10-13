# TODO

Build order, from the bottom up. Each module depends only on the ones above it.

```
Id ✓ → Graph ✓ → Memory ✓ → Store ✓ → Refs ✓ → Cache ✓ → GC ✓ → Query ✓ → CLI ✓ → MCP ✓ → Web UI ✓
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
- A snippet marks a match with U+0001 and U+0002 (`snippetOpen`, `snippetClose`), and not with brackets, so a bracket in a body is never a mark.
  The index holds U+FFFD in place of these two characters of a body, so a mark in a snippet always comes from `search`. `schemaVersion` is 2, so an old cache is made again.
  `Render.snippetText` makes the text of the CLI and the MCP server: `[word]` for a match, and `\[` and `\]` for a bracket of the body.
  The JSON of `/api/search` and the page keep the control characters: `snippetParts` of the page splits at them.
- Errors: `CacheSQL`, `CacheIO`, `CacheLocked`, `CacheStore`, `CorruptCache`. `Akyuu.Fs.tryAs` catches the SQLite exception.
- `openCache` runs under an exclusive `flock` on `cache.sqlite.lock`. It tries without waiting and retries for about 5 seconds, like the lock of Refs.
- `reindex` reads the whole store first. Then it clears the tables and writes the new rows in one transaction.

To do, in this order:

- [x] Pure part: `ftsQuery`.
- [x] `openCache` and `closeCache`: the schema, `PRAGMA user_version`, WAL and `busy_timeout`. Delete and recreate a bad file.
- [x] `index`, `forget`, `cachedIds`. Each one is one transaction.
- [x] `loadGraph`: one `singleton` for each `memories` row, joined with `<>`.
- [x] `sync`: read every new object first, then change the cache in one transaction. `reindex` is "empty it, then `sync`".
- [x] `search`: `bm25` order, `snippet` with the marks U+0001 and U+0002 (see "Decided"), and a limit.
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
- [x] Run it from outside (launchd or cron) with `akyuu gc`. No daemon. The home-manager module runs it under launchd, with the policy flags.
      Not done: Linux timers (the module writes launchd agents only), and a test on a real switch.
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
- `search` puts the current memories before the old versions (`headsFirst`). An old version is a hit that a memory supersedes.
  The order inside each group does not change. The text index does not know the graph, so `search` reads `4 * limit` hits, orders them,
  and keeps `limit`. An old version stays in the result if there are not enough current memories to fill it.
  A person who asks for 1 hit then gets the current memory. A fork lists both newer memories in `matchSupersededBy`, as before.

- [x] `search`: FTS hit, then `withinHops` to widen it to a neighbourhood.
- [x] Show `neighbours` with the direction (`Out` or `In`) and the kind. `Out` edges come first.
- [x] `resolve :: Id -> Graph -> Set Id`: the heads that replace an `Id`, also for one that GC deleted.
- [x] **Fuzzy search**, steps 1 and 2: a query word that the index does not have is searched as the start of a word, or as the
      near terms of the index (`Akyuu.Fuzzy`, `fts5vocab`, `Cache.searchFuzzy`). The result says what it did (`note: no word 'haksell', so it was
      searched as 'haskel'.`). A word that exists is never changed. Step 3 (trigram) is not done. The plan was:
      1. Prefix match on the last word of the query (`hask` finds `Haskell`): FTS5 `word*`.
      2. Spelling tolerance from the index itself. `fts5vocab` lists every term of the text index, so a query word that is not
         a term (or has few hits) can be replaced by the terms within edit distance 1 (2 for long words), by Damerau-Levenshtein
         in Haskell. The query becomes an OR of the variants, and the result says what it used (`hsakell -> haskell`), so nothing is silent.
      3. Only if 1 and 2 are not enough: a second FTS5 table with `tokenize='trigram'` (about three times the size of the text index).
      Keep exact matches first (bm25 on the original words), and put fuzzy hits after them. Needs no new dependency and no schema break
      for 1 and 2 (the vocabulary is a view of the existing table).
- [ ] **Search by meaning (embeddings).** Feasible and cheap at this size, and it fits the design: an embedding is a derived index
      keyed by `Id`, so it never needs invalidating. Sketch:
      - Akyuu does not run or name a model. A configured command (`AKYUU_EMBED_COMMAND`, or `--embed-command`) reads a text on stdin and
        writes a JSON vector. A local server (llama.cpp `llama-server --embeddings`, MLX, Ollama) or a script can sit behind it.
      - A table `embeddings(id, model, dim, vector BLOB)` in the cache, filled by `sync` for new memories and by `akyuu embed` for the
        rest. The `model` string is part of the key, so a new model gives new vectors and the old ones are dropped, not mixed.
      - Search: embed the query with the same command, brute-force cosine over the vectors (10,000 memories of 768 floats is 30 MB and a few
        milliseconds), and merge with the text hits by reciprocal rank fusion. Plain text search stays the default and the fallback,
        so a missing model server never breaks `search`.
      - Also useful for `check`: near duplicates that share meaning and not words. Keep it an optional detector, because `check` must stay
        deterministic and model-free by default.
      - Costs: a model server must be running for a query, a query takes one model call (tens of milliseconds), and the vectors depend on the model.
      - Do first: an experiment, not a feature. Embed the store with one small local model, write 20 real queries, and compare the top 5 of
        the text search with the top 5 of the vector search. At a few dozen memories, text search with stemming may already be enough.
- [x] Ranking of the text hits (`Query.rankHits`, `searchWith`): a memory that a ref holds and a newer memory move up about one place each, and
      both together can pass the best match from the next place. The text index order stays the main signal. Not done: a boost for
      "recently confirmed", and a learned weight.
- [x] Episodic memory: `akyuu append` and `akyuu log`, and the MCP tools `append` and `log`. See `docs/episodes.md`. Not done: a `check` finding for a
      very long log, and a retention setting for each log.

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
- `get` uses `getVerified`, so it checks the hash. `get ID` prints the stored file exactly, to a pipe or a file.
  If stdout is a terminal, it adds one line feed when the body does not end with one (`terminalBytes`, `Output.outEndLine`).
  The prompt of the shell then does not end up on the last line of the body, and scripts still get the exact bytes.
  An `Id` that GC deleted gives "GC deleted it at …" from its tombstone, and the memories that replace it (`Query.resolve`).
- An id on the command line can be the start of one (`IdSpec`, `Ops.parseIdSpec`). `sha256-` is optional, the case does not matter,
  and at least 4 hex digits are needed. A whole id (`sha256-` and 64 digits) is used as it is, with no look at the store.
  A prefix is matched against the memories in the store now (`Ops.resolveId`). No match gives `NoSuchPrefix`.
  More than one match gives `AmbiguousPrefix`, with the first five. This holds for every id argument: `get`, `neighbours`, `ref set`,
  `--expect` and the edge options. The MCP server does not take prefixes: an agent gets whole ids from the tools.
  A prefix of a memory that GC deleted finds nothing, because the file is gone.
- `Command` has a type parameter for the ids. The parser gives `Command IdSpec`, `resolveCommand` gives `Command Id`, and `runCommand` runs that.
- `ref list` prints the name, two spaces and the id of each ref (`Ops.listRefValues`, `Render.refListLines`). The MCP tool `ref_list` does the same.
  A damaged ref is an error for the whole list, like `ref get`.
- `ref set NAME ID` is `Unchecked` by default, as for a person who sets a ref by hand. `--new` is `MustBeAbsent`. `--expect ID` is `MustBe`.
  `Ops.setRefTo` checks that the `Id` is in the store first, so no ref points at nothing. `Akyuu.Refs` still does not look at the store.
- `supersede NAME` reads the ref. `supersede NAME --expect ID` uses `supersedeFrom`.
- `add` allows `--supersedes ID` as a plain edge. It does not move a ref.
- `neighbours` of an `Id` that is not a memory and has no edges is an error, not an empty list. A dangling target shows its edges.
- `pin ID`, `unpin ID` and `pins`. `Ops.pinMemory` checks that the memory is in the store, like `ref set`, because an id that nothing has is most likely a typo.
  `GC.pin` itself allows an object that is not there. `unpin` does not check, so a person can remove the pin of a deleted memory.
- `gc [--dry-run] [--keep-generations N] [--grace DURATION] [--trash-ttl DURATION]`. Each flag defaults to `defaultPolicy`. There are no temp roots.
  A duration is a whole number and a unit (`s`, `m`, `h` or `d`), like `30m`, `1h` or `7d` (`Ops.parseDuration`). The unit is not optional.
  `Akyuu.GC` did not change: `dryRunGC` and `runGC` take the `Policy`.
- `verify` reads and hashes every object itself, and builds the graph from them, not from the cache. It reports corrupt and unreadable objects,
  missing edge targets, bad refs, and refs to a missing object. A target with a tombstone is "pruned". That is normal, so it is not a problem.
- `optparse-applicative` is a new library dependency. The Nix shell already had it. `akyuu.nix` is edited by hand to add it.
  A new run of `cabal2nix` would also add the test dependencies, and `nix build` would then run the tests. Lilly should decide that.

- [x] `add`, `get`, `supersede`, `ref set|get|list`, `search`, `neighbours`, `gc [--dry-run]`, `reindex`, `verify`, `pin`, `unpin`, `pins`.
- [x] The flags of the GC policy.
- [x] Friendly error text from `AkyuuError`, not `Show`.
- [x] Unit tests for the parser, the error text and `Akyuu.Ops`. `test/smoke-cli.sh` runs the executable against a temp store.

Not done:

- No `init` command.
- The smoke script is not part of `cabal test`. Run it by hand: `nix develop -c bash test/smoke-cli.sh`.
- `get` does not show the edges of a memory in a separate form. Use `neighbours`.

### MCP server

The server is `Akyuu.MCP`, and `akyuu mcp` runs it. It is a subcommand and not a second executable, so it shares
the root rule (`--root`, `AKYUU_ROOT`) and the client config needs one binary: `akyuu --root DIR mcp`.

Decided:

- Transport: stdio, one JSON-RPC 2.0 message on each line. Stdout carries only protocol messages. Logs go to stderr.
- Methods: `initialize`, `ping`, `tools/list`, `tools/call`. A notification gets no answer. A message with no method (a response) is ignored.
  A batch (a JSON array) gives `-32600`, because MCP 2025-06-18 removed batches.
- Versions: `2025-11-25`, `2025-06-18`, `2025-03-26`, `2024-11-05`. `initialize` gives back the version of the client if it is in the list, or else the newest.
- The server keeps no state. It does not check that `initialize` came first.
- Tools: `add`, `get`, `supersede`, `search`, `neighbours`, `ref_get`, `ref_set`, `ref_list`. Each one has a JSON schema with `additionalProperties: false`.
  `gc`, `reindex` and `verify` are not tools: they are jobs for a person or a timer, not for an agent.
- The text of a tool result is the same as the CLI output (`Akyuu.Render`). An error is the text of `describe`.
- A failed operation and bad arguments are tool results with `isError: true`, so the model can read the text and try again.
  An unknown tool and bad `params` are `-32602`. An unknown method is `-32601`. A line that is not JSON is `-32700`.
- `ref_set` needs `expected` or `create: true`. An agent cannot set a ref without the compare-and-set check. The CLI can (`Unchecked`), for a person.
- `handleMessage` is pure in the runner of the tools (`Monad m => (ToolCall -> m ToolResult) -> …`). The tests use `Identity` and a fake runner.
- A tool that throws (a bug) gives an error result, and the server goes on. Async exceptions are not caught.
- `aeson` comes from Nix (2.2.4.1). It links QuickCheck 2.15.0.1, so the test suite now builds with that QuickCheck, and not 2.19 from Hackage.
  QuickCheck 2.15 has no `withNumTests`, so `StoreTests`, `RefsTests` and `CacheTests` use `withMaxSuccess`, the older name of the same function.
  To go back to 2.19, aeson must be built from Hackage. That needs the network and is outside Nix. Lilly should decide.

- [x] Wrap the same library functions. Do this after the CLI works.
- [x] Tests: the pure handler (initialize, list, calls that work and fail, protocol errors) and `runTool` on a temp store.
      `test/smoke-mcp.sh` runs `akyuu mcp` over real pipes.

Not done:

- No `structuredContent` or `outputSchema` in tool results. The text is the only content.
- No resources, prompts, sampling, logging or cancellation. A `notifications/cancelled` is ignored, because each call runs to the end before the next line is read.
- The server reads one line at a time and answers in order. A slow call (a big search) blocks the next one.

### Web UI

A local, read-only view of a store, for a person who tests it. `akyuu serve [--port N]` serves it live.
`akyuu viz > out.html` writes the same page with the data inside it, so it needs no server.
`akyuu seed --demo --root DIR` makes a small store that has one of each case. The modules are `Akyuu.Web.*` and `Akyuu.Seed`.

Decided:

- Read-only. Every endpoint is a `GET`, and any other method gets `405`. There is no write endpoint. Write actions behind `--rw` are a possible later step.
- The web layer does not call `Cache.sync`, and writes no file. A sync would hide the drift that the health view shows.
  The graph comes from the cache and the new objects of the store, as in `GC.snapshot`. A test calls every endpoint and checks that no file changes.
  The search uses the text index of the cache, so it misses a memory that the cache does not have yet. The search view says so.
- `Akyuu.Web.Api.route` is pure in the runner of the endpoints, like `MCP.handleMessage`. The tests use a pure runner and a real store.
- Endpoints: `/api/stats`, `/api/graph`, `/api/memory/:id`, `/api/refs`, `/api/search`, `/api/gc/plan`, `/api/gc/explain/:id`, `/api/trash`, `/api/verify`.
  `/api/memory/:id` takes the start of an id (`Ops.resolveId`). The others take whole ids.
  Errors: `400` bad input, `404` not there, `410` deleted by GC, `500` the rest. The body is `{"error": …}` with the text of `describe`.
- Threat model: a local tool with no login. The server binds 127.0.0.1 only, and checks the address after the bind.
  It refuses a `Host` header that is not `127.0.0.1:PORT` or `localhost:PORT` (`403`), against DNS rebinding. It sends no CORS headers.
  It serves no file by path: the page is in the binary (`file-embed`). The headers forbid frames, sniffing and outside loads.
- The server answers one request at a time (an `MVar`). The SQLite connection is shared, and two transactions on one connection cannot run at once.
- `serve` prints only the address on stdout. The default port is 7420. `--port 0` takes a free port.
- The page is one HTML file with inline CSS and JavaScript, and hand-written SVG. It loads nothing from the network.
  It puts store data in the DOM only as text (`textContent`, `setAttribute`), never as HTML. A memory body is untrusted.
- `viz` puts the data in a `<script type="application/json">` element. The JSON escapes `<`, `>` and `&`, so a body cannot end the element.
  The export has the whole graph, every memory and `GC.explainAll` for every node. Its search is a plain word match in the page, with no stems.
- Layout: time runs down. The order is newest first, but a memory is always below each memory that points at it.
  A memory and the memory that it supersedes share a lane. In a fork, the newest source keeps the lane and the other one branches.
  This is only for the drawing: the UI shows both heads and does not choose (see "Forks" below).
- Edge routing: circuit-diagram style, with rounded corners (6 px). An edge never runs over a node box or a ref tag.
  It uses only the gutter to the right of a column (vertical runs) and the gap between two rows (horizontal runs).
  A clear edge inside one column is a straight line. An edge to the next row is a "Z" in one gap.
  Any other edge leaves the source into the gap below its row, runs to a gutter, goes down, comes back in the gap above the target, and goes into its top.
  The gutter is the one next to the target, or the next one if that one is much busier (the edges to a few old nodes would make one huge gutter).
- Tracks are 6 px apart. A gutter is COL_GAP wide plus 6 px for each track. A row gap is 24 px, plus 6 px for each track after the first, so rows are no longer 60 px apart.
  Runs with no common row share a track. Edges that share a gap or a gutter get their own track, ordered by the crossings that each pair would make.
- Ports: the edges at the bottom or the top of a node are sorted by the x of the place where they go, spread along the box (at most 12 px apart, fewer when there are many, inside the box).
  A straight edge has its port at the middle of the box on both ends, so it stays straight.
- Column order: after the rows, the columns are ordered with barycenter sweeps and neighbour swaps, to make the edges short. Chains stay in their column.
- Compact layout: the by-time layout gives one column to each chain that is alive at once, and most chains start at the top, so a store of many short
  chains is wide and short (17 columns by 14 rows on 57 memories). `layout(graph, {maxColumns: K})` stacks the chains in at most K columns (`packChains`):
  a chain moves down as a whole, below the chain above it and below every node that points at it. Chains that point at each other are pinned and keep
  their own column. If the result has more than K columns, the by-time layout is used. The page tries fewer and fewer columns and keeps the layout that fits
  the canvas at the largest scale (`chooseLayout`). The toolbar has a "layout" select: compact or by time. Graphs of more than 800 nodes stay by time.
  Not done: chains that cross-link densely (the synthetic graphs of the routing check) do not compact, because they are pinned.
- Highlight: the edges of the hovered or selected node are bold, the others faint, and the boxes at the other ends get a frame. The kind styles and the filter dim stay.
- The routing is in pure functions (`planRoutes`, `columnGeometry`, `routeEdges`, `roundedPath`), exported for the node checks.
- Window: by default `/api/graph` shows the 200 newest heads and the nodes within 2 hops, with `truncated` and the counts.
  The page starts with the whole graph for a store with up to 1000 memories. It has "show all", a hops and a heads field, and "focus here".
  The GC drawing shows the whole graph up to 2000 nodes, and the window of the graph tab above that.
- The page polls `/api/stats` every 2 seconds. It loads the views again when the fingerprint changes: the counts and the newest file time of the store directories and refs.
- `GC.explain :: Policy -> Observed -> Roots -> Graph -> Id -> Why` lists every reason (ref, pin, temporary root, young, retaining edge) and one shortest chain from a root.
  A property test checks that an id is in `plan` exactly when `explain` says that it is a node and not live. `GC.explainAll` does all nodes in one walk.
  The web layer adds which ref generation holds an id (`refHolds`). `GC.young`, `listTrash` and `listTombstones` are new exports.
- `Cache.summaries` gives the id, kind, agent, created time and first line of each memory. It is in `Akyuu.Cache`, because the cache has these columns and the bodies.
  `firstLine` reads at most 400 characters and stops at a NUL, because SQLite ends a text at a NUL.
- `seed --demo` uses the library: `Store.add`, `supersedeFrom`, `setRef`, `pin` and `sweep`. Old objects get a created time and a file time in the past.
  The prune uses `sweep` with a trash time of 0 and a run time one second after now. `seed` refuses a directory that holds anything but an empty store.
- New dependencies, all from Nix: `warp` 3.4.9, `wai` 3.2.4, `http-types` 0.12.4, `file-embed` 0.0.16.0, `network` and `streaming-commons`.
  The test suite also uses `wai` and `http-types`. The build plan only adds packages: no version of an existing package changes. `akyuu.nix` is edited by hand.

- [x] The read model and the JSON API, with tests.
- [x] `serve`, `viz`, and the graph, refs and search views.
- [x] The GC and health views, and `GC.explain`.
- [x] `seed --demo`. The tests use it as the fixture of the GC and health views.
- [x] A store of 3000 memories: each endpoint answers in less than 0.12 seconds. `viz` makes a file of 4.2 MB in 0.6 seconds.
- [x] Edge routing, port spread, tracks, column order and highlight. `test/check-routing.js` checks the routes in node
      (axis-aligned runs, no run through a box or a tag, no shared run, ends on the box edges, time limits).
      `test/check-page.js` runs the page in a fake DOM. `test/smoke-routing.sh` runs both on real exports.

Not done:

- The page is not checked in a browser. Node (from nixpkgs) checks the syntax, runs the layout on real exports, and runs the page in a small fake DOM.
  That shows no runtime errors and no use of `innerHTML`. It does not show how the page looks.
- `test/smoke-web.sh` is not part of `cabal test`. Run it by hand: `nix develop -c bash test/smoke-web.sh`.
- The fingerprint does not see an `add` of an object that is already there: that only changes the file time of the object.
- A graph with many standalone memories is tall and narrow: each one gets its own row.
- Edge crossings are fewer with the column order, but not minimal. Routed edges can cross more than the old curves did: a long edge crosses every line in the gaps and gutters that it passes.
  Ideas: a better cost for the column order (the crossings, not the column distance), and doglegs in a gap to avoid the cycles in the track order.
- A store with many edges to a few old memories makes wide gutters (one track per concurrent edge) and tall row gaps. Bundling edges would help.
- The routing is not seen in a browser: the real SVG rendering, the corner shapes, the hover and the colours are not checked.
- After the hops, the window has no cap. A memory with thousands of edges can pull them all into the view.
- One unreadable object stops the graph view, as it stops `GC.snapshot`. The health view still shows it.
- [x] The check report has its own tab, between GC and Health. It shows a summary, an "all clear" line, filters, and a count of
      problems on the tab. A pair finding has a Compare button: the side panel shows both memories and the sentences that only
      one has. The page does the comparison itself (the same as `Akyuu.Compare`, with the same test cases), so an export can too.
- [x] The memory graph fits the viewport: a scale from the size of the drawing and of the canvas, never enlarged and never below 40%.
      Below 55% the page hides the node text and keeps the shape. Buttons, ctrl or cmd and the wheel, and a drag zoom and pan.
      Checked in a real browser by Lilly on 2026-10-13 (the thresholds are as they are).
- `explain` reads the whole snapshot for each request. This is fast enough at 3000 memories.

## Open decisions

- [x] **Smart constructor for `Memory`.** Done: `mkMemory :: Text -> UTCTime -> Text -> Set Edge -> Text -> Either MemoryError Memory`.
      `Akyuu.Memory` no longer exports the constructor, only the field readers. `kind` and `agent` must pass `validField`,
      and the time is cut to whole seconds, so a made memory equals what the store reads back. `parseMemory` uses it too.
      `Ops.checkField` and `Ops.buildMemory` call it. Tests use `Support.testMemory`.
      A record update (`m {memKind = ""}`) can still break the rule. Nothing in the code does it.
- [x] **Order of headers.** Done: `parseMemory` accepts only the canonical form. A file with the headers in another order,
      a repeated or unsorted edge line, or any other change gives `NotCanonical`. So for every file that parses,
      `renderMemory m == bytes`, and the `Id` of the memory is the hash of the file. All 55 objects of the live store pass.
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
      See "Consolidation pass" below for the plan.
- [x] **A link to a memory that GC deleted.** Done in part. `Query.resolve` follows `Supersedes` edges backwards from an old `Id` to the memories that replace it.
      It works after GC, because the edge of the newer memory stays in the cache as a dangling target. `get` on a deleted memory names the replacements
      (`Pruned` holds them, and the web API sends them in the 410 text). A fork gives every head.
      Not done: the chain breaks when a middle memory is deleted too, because its own edge goes with it. The fix is a tombstone that records the successors
      at trash time (a second line in the tombstone, and old tombstones must still parse). Do it if this happens in practice: it needs 6 or more supersedes of one ref plus 7 days.
      A link to a ref always resolves, because the ref is the stable name. Use `derived_from` or `refines` from a live memory to keep an old text alive.

## Future work

Ideas, not decisions. None of this is started.

### Consolidation pass

Detection is built: `akyuu check`, the `check` MCP tool, and `GET /api/check` (see `docs/check.md`).
It finds stale links, forks, duplicate and near-duplicate bodies, memories that nothing keeps, and hubs.
Judgement (the LLM phase) is not built. It would read the findings and write normal `supersede` or `add` calls.
Not done: `SameProject` (detector 6), shingle hashes in the cache, and a way to mark a pair as reviewed.

Two phases, so that no result depends on the attention of a model.

1. **Detection, with no LLM.** Cheap checks, deterministic or based on embeddings, that flag candidates. It is exhaustive.
   - Identical or near-identical text (the `ultrakill-macos` and `values` pairs of 2026-10-11 are examples).
   - One ref name that points at several live hashes.
   - Unreferenced nodes: no ref, no pin, no retaining edge.
   - Links to superseded versions (the profile situation in the graph).
   - Nodes with the same project path.
2. **Judgement, with an LLM.** For each flagged pair or group, the model rules: duplicate, supersedes, or both true.
   It only sees the cases that detection hands it. Its output is a `supersede` or a merged memory, written with the normal tools.

Detection can be pure functions over the `Graph` and the cache, so it can sit next to `GC.plan` and have a dry run.
Embeddings are a derived index keyed by `Id` (see the Query item "Later"), so they cache without any invalidation.

### Weighted connections

Give a stronger connection more weight in search context and in the graph view:

- **Degree discount.** Score a link by about `1 / log(inbound links of the target)`, so a hub like the profile counts for less.
- **Hop decay.** Weight a direct hit above a one-hop neighbour, and cap at one or two hops. `searchHops` is 1 by default now.
- **Tiers instead of links.** The profile and the memory policy need not be reachable by links. They can be an always-loaded tier that every session gets.
  Then no memory needs a link to them, and the graph is cleaner to look at (`about` edges to the profile are the main source of hubs today).
- **Recency of confirmation** as a mild boost.

## Clean-up

- [x] Remove the commented-out `breakOn'` in `src/Akyuu/Memory.hs`. Removed, not used: `splitBody` and `splitHeader` need the rest of the text on a miss (`MalformedHeader` holds the whole line), so `Maybe` would add code.
- [x] `Backward` in `WalkMode` (`src/Akyuu/Graph.hs`) is never built. Removed it: no test used it.
- [x] `Graph` now has `Eq`, so `observe` in `test/GraphTests.hs` can become plain `===`.
- [x] Run `ormolu` over the whole tree so the style is the same everywhere. Done with ormolu 0.8.0.2 (`nix develop -c ormolu --mode inplace $(git ls-files '*.hs')`).
      Every file parsed. Run it again after an edit.
- [x] Cache: `tryExisting` treats every `SQLError` as "not usable", and `openCache` then deletes the file.
      A busy or locked database (`ErrorBusy`, `ErrorLocked`) must not do that. Match only `ErrorNotADatabase` and `ErrorCorrupt`.
- [x] Cache: set `PRAGMA busy_timeout` right after `open`, before `tryExisting` reads the version.
- [x] Cache: use `withImmediateTransaction` in `index`, `forget`, `sync` and `reindex`. A deferred transaction that reads and then writes can fail with `BUSY`, and the timeout does not help.
- [x] Cache: `sync` fails if GC sweeps an object between `Store.list` and `Store.get` (`NotFound`). Skip that object. Add a test.
- [x] Cache: remove `tryIO` (unused) and the `CacheIO` constructor (nothing builds it), or give it a job.
- [x] Cache: `cachedIds` has its own `toId`. Use `parseCached`.
- [x] Cache: two processes that find a bad cache at the same time can each delete the file that the other made. Done: a lock file around `openCache`, with a test that fails without it.
- [x] Pick one style for `Akyuu.Id` imports (`qualified` at the front or the back). The back (ImportQualifiedPost): every import in `src`, `app` and `test` already used it, so no file changed.
      `-Wprepositive-qualified-module` (see below) keeps it so.
- [x] Add `-Wprepositive-qualified-module` and `-Wmissing-import-lists` to `shared` in `akyuu.cabal`, and fix what they flag.
      The second flag also warns for `T (..)`, so every `T (..)` import item is now a list of the constructors and fields that the module uses.
      Both flags apply to the library, the executable and the tests.
- [x] `Store.add`: wrap `removeFile tmp` in the cleanup with `ignoreIO`, so a cleanup error cannot hide the real one. Already true: `add` has no cleanup of its own now.
      `Fs.atomicWrite` removes the temporary file with `ignoreIO`, and `add` calls it.
- [x] Move `ignoreIO` and a generic `tryWith` from `Akyuu.Store` to `Akyuu.Fs`.
- [ ] Do the same for `orNotFound` once `getRef` shows what it needs.
      `Store.orNotFound` and `Refs.orNoSuchRef` have one shape: `tryWith`, then one test on the `IOException`. They differ in the test:
      `isDoesNotExistError` for the store, `isMissing` (also `InappropriateType`) for refs. A shared helper needs that test as a parameter,
      for example `orMissing :: (IOException -> Bool) -> e -> (IOException -> e) -> IO a -> IO (Either e a)`. That is a choice about the API, so it waits for a decision.
- [x] Add `-threaded` to the test suite, so the race test with `MustBe` can really run threads in parallel.
      Done, with `-N`. Check that the `MustBe` race test now runs threads in parallel: it is not changed yet.

## Agent ergonomics (2026-10-11)

- [x] `amend`: change one passage of the memory of a ref, or append, in one call (`Akyuu.Amend`).
- [x] Tools accept a unique id prefix of 8 hex digits or more. Lists show ids cut to 12 digits.
- [x] Search hits show the refs that hold them (`held by`). `ref_list` shows the first line of each memory.
- [x] Manifest lines `at DIR: refs` and `log DIR: ref`. `context` adds the refs of a directory. `note` writes to the log of a directory.
- [x] `docs/hooks.md`: a SessionStart hook that runs `akyuu context`.
- [x] Fuzzy search: a stem is near a long word only if it has 5 characters or more and starts like the word (no more `perl` for `persnoa`).
- [x] `check` finding `long-log`: a log with more than 30 episodes (`--long-log N`, `long_log`).
- [x] The memories repo has a private remote (github.com/lillycham/akyuu-mem). `akyuu-version` still never pushes.
- [ ] **Per-log retention.** Needs a decision first: should a log summarise itself (a procedure memory that an agent runs when
      `long-log` shows), or keep only the newest N episodes (GC would then need to cut a chain)? Today the answer is the first one, by hand.
- [ ] `akyuu-version` could push after it commits, when a remote exists and the person turns it on (`versioning.push = true`).
