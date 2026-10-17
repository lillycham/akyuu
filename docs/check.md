# `akyuu check`: the detection pass

Status: built on 2026-10-11 (detectors 1 to 5 and 7, the CLI, the MCP tool and the web view).
Detector 6 (`SameProject`) is not built. The seed has no extra cases: the tests build their own stores.
On a real store of about 80 memories, the first run found two orphans of an import, a stale link, and an
unreferenced copy of a project memory that nobody knew about. The threshold of 0.8 gave no false positive there.

## Purpose

Find the memories that need a person's or an agent's attention, without a model.
It is the first half of the consolidation pass in [development-log.md](development-log.md). The second half
(judgement: duplicate, supersedes, or both true) is not in this design.

It would have found, in one run, the two problems that we found by hand on
2026-10-11: two near-copies of one topic with no `supersedes` edge between them
(`ultrakill-macos`, `values`), and fourteen memories with an `about` edge to a
superseded profile.

Rules for the module:

- Exhaustive. Each detector looks at every memory. No result depends on what a model noticed.
- Deterministic. The same store gives the same findings in the same order.
- Read-only. `check` writes nothing, not the store, not the cache, not a lock.
  It reads the graph like `GC.snapshot` does. It does not call `Cache.sync`.
- Cheap. A store of 3000 memories must finish in about a second.
- It reports. It does not fix. The fix is a normal `supersede`, `add` or `pin` by
  a person or an agent.

## Shape

A new pure module `Akyuu.Check`, in the style of `Akyuu.GC.plan`.

```haskell
data Severity = Problem | Suggestion | Info   -- ordered, Problem first

data Finding = Finding
  { findingKind :: FindingKind
  , findingSeverity :: Severity
  , findingIds :: [Id]            -- sorted; the memories that the finding is about
  , findingWhy :: Text            -- one sentence, for a person
  }

check :: CheckOptions -> Inputs -> [Finding]   -- pure, sorted, no duplicates

data Inputs = Inputs
  { inGraph  :: Graph
  , inBodies :: Map Id Text       -- body of each memory in the graph
  , inRoots  :: Roots             -- refs, pins (from GC.readRoots)
  , inNames  :: Map Id [Name]     -- which ref names point at an id now (current value)
  }
```

`Akyuu.Ops.checkStore :: Env -> CheckOptions -> IO (Either AkyuuError [Finding])`
gathers the inputs (graph from `GC.snapshot`, bodies from the cache with a
fallback to the store for objects the cache lacks, as `readGraphData` does) and
calls `check`. The CLI, the MCP server and the web layer render the same values,
like Query.

Pure function and plain data means: unit tests for each detector on a small
`Graph`, and a property test that `check` is deterministic and sorted.

## Detectors

Each detector is a pure function `Inputs -> [Finding]`. `check` is their union,
sorted by severity, then kind, then ids.

| # | Kind | Severity | What it flags |
|---|------|----------|---------------|
| 1 | `StaleLink` | Problem | A live memory has an `about` or `refines` edge to a memory that is superseded (a node with a `Supersedes` predecessor), or to a dangling target that has a successor (`Query.resolve` is not empty). The finding names the current head, and the ref that holds it: an `about-ref` link to that ref does not go stale. A `derived_from` edge is evidence of one exact text, so it is not reported (changed with `about-ref`). An episode (a memory on a log chain) is not reported either: it records a past state. |
| 2 | `Fork` | Problem | Two or more live heads that supersede the same memory. Today the UI shows both and chooses neither. |
| 3 | `DuplicateBody` | Suggestion | Two or more memories whose normalised bodies are equal, and that are not in one `supersedes` chain. |
| 4 | `NearDuplicate` | Suggestion | Two heads whose bodies share most of their word shingles (see below), and that are not in one `supersedes` chain. |
| 5 | `Unreferenced` | Suggestion | A head that no ref holds and no pin holds, and that no live memory points at with a retaining edge. GC collects it after the grace period (`explain` says "not live"). The finding shows it before GC does. |
| 6 | `SameProject` | Suggestion | Two heads under different refs whose first line names the same path (`~/devel/akyuu`). Weak: a heuristic on the text. |
| 7 | `Hub` | Info | A memory with more than N (default 5) incoming retaining edges. It is a sign that links should be a tier (see "Weighted connections" in the TODO). |
| 8 | `LongLog` | Info | A log (the value of a ref that no episode follows) with more than N (default 30) episodes that no summary covers in its chain of `follows` edges (or, in an older log, of one `derived_from` edge each). See `log --todo`. |
| 9 | `MissingRef` | Problem | A live memory has an `about-ref` link to a ref that does not exist. The link resolves to nothing. |

Notes on each:

1. `StaleLink` needs the successor, so it calls `Query.resolve`. A target with
   two successors is a fork: the finding lists both.
2. `Fork`: `Graph.predecessors Supersedes x` has two heads or more, after
   following the chain with `resolve`. One finding for each forked memory.
3. `DuplicateBody`: normalise by NFKC-free simple rules only: trim, collapse white
   space, lower-case. Group by the normalised text. This is exact, so no threshold.
4. `NearDuplicate`: shingles are 3-grams of words, hashed to 64 bits.
   Similarity is Jaccard over the two sets. Default threshold 0.8. To avoid
   comparing every pair, build an inverted index from shingle to memories and
   compare only pairs that share at least one shingle, skipping shingles that
   occur in more than 10% of the memories (they carry no signal). A body with
   fewer than 5 words is skipped, because tiny texts match by chance.
   Two memories in one `supersedes` chain are old and new versions of one text:
   they are meant to be similar, so they are not a finding.
5. `Unreferenced` only looks at heads. A superseded memory is normal garbage and
   GC already reports it.
6. `SameProject` is the weakest. It takes the first token of the first line that
   looks like a path (starts with `~/` or `/`, has a slash). Keep it behind a
   flag, off by default, until it shows value.
7. `Hub` counts incoming `about`, `derived_from` and `refines` edges from live
   memories. It is information for a person who designs tiers.

What the model of the store does not allow, and the plan from the notes needs a
different name for: "the same ref name points at several live hashes" cannot
happen, because a ref holds one current value. Its real forms are (2) a fork of
one lineage and (3, 4) the same topic under two ref names. Both are covered.

## Interfaces

CLI:

```
akyuu check [--kind KIND]... [--severity problem|suggestion|info]
            [--near-threshold 0.8] [--hub-degree 5] [--same-project]
            [--json]
```

- Text output, one finding per block: severity, kind, ids (whole, so an agent can
  use them), and the sentence. Exit code 0 even with findings. `--strict` gives
  exit code 1 when there is a `Problem`, for use in a timer or a hook.
- `--json` is the same data, for the web page and for scripts.

MCP: one read-only tool `check`, with the same options in a schema. A read-only
tool is safe for an agent, unlike `gc`. It is the input of the judgement step: an
agent calls `check`, reads the ids with `get`, and decides.

Web: a "Check" tab beside the health view, `GET /api/check`. It lists findings and
links each id to the memory view. It does not call `Cache.sync`, like the other
endpoints. The `viz` export includes the findings.

## Cache and schema

No change to the schema in the first version. Bodies are read from the cache (the
FTS table keeps a copy) and shingles are computed on each run. At 3000 memories of
about 1 KB each, that is about 3 MB of text, and the cost is a few tens of
milliseconds. If a measure says otherwise, keep shingle hashes in a derived table
keyed by `Id`. Objects never change, so that table needs no invalidation. That
would be schema version 3.

## Tests

- One unit test for each detector on a small hand-built `Graph`, with a case that
  must not fire (a superseded chain is not a duplicate; a short text is not a near
  duplicate; a head under a ref is not unreferenced).
- A property: `check` is deterministic, sorted, and every finding id is a node or
  a dangling target of the graph.
- An integration test on `seed --demo`: the demo store already has a fork, a
  superseded memory, a pruned target and garbage, so it is the fixture. Add one
  near-duplicate pair and one stale link to the seed so each kind has a case.
- `test/smoke-cli.sh` runs `akyuu check` on a temp store.
- A regression test with the store of 2026-10-11 in miniature: two near-copies with
  no edge, and an `about` edge to a superseded memory.

## Order of work

1. `Akyuu.Check` with detectors 1 to 5, and unit tests. (Pure, no I/O.)
2. `Ops.checkStore`, `Render.findingLines`, `akyuu check`, with smoke test.
3. The MCP tool.
4. The web endpoint and tab, and the seed additions.
5. Detectors 6 and 7, if (1 to 5) are useful in daily use.

Each step is a commit that builds and passes. Steps 1 and 2 are enough to use it.

## Open questions

- **Threshold.** 0.8 is a guess. It should come from real stores: run it on
  yours and look at the pairs between 0.5 and 0.9.
- **Where it is allowed to be loud.** Should `gc` print `check` Problems before it
  runs? Probably not: GC is a timer job and nobody reads the log. A `launchd` job
  that runs `check --strict` daily and writes the log is a better place.
- **Findings that a person has judged.** After a person decides that a near
  duplicate is on purpose, `check` will flag it every day. Options: a pin-like
  "reviewed pair" file (an `ignore` list in the store), or a `both true` edge kind
  that the judgement step writes (a `Graph` change, so it is your decision).
  I suggest to ship without it and see how much noise there is.
- **Normalisation.** Plain trim and lower-case are enough for the exact check. A
  stronger form (stemming, as the FTS index does) would catch more but is harder
  to explain. Keep it simple first.
