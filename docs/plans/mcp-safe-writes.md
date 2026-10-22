# Safer MCP writes and tool sets

Status: implemented on the feature branch as of 2026-10-22. Not merged or installed.

## Goal

An ordinary agent must be able to save and revise knowledge without knowledge of GC or raw ref operations.
The store format, graph edges, and CLI operations stay the same.

## 1. Enforce version checks

Require `expected` for MCP `supersede` and `amend` in every tool set.
Require it in the JSON schema and the argument parser.
The server must reject a call without it before any write.
Continue to accept short ids through the existing id expansion path.
Use the existing compare-and-set operation with the supplied version.
Do not retry a stale replacement against a newer version.
Return an error that tells the agent to read the current memory before it revises the text.

The CLI can retain its existing optional version argument.
The lower-level API can retain its current types unless a small adapter improves clarity.
This avoids a change to the core modules for an MCP constraint.

Tests:

- Both schemas require `expected`; both parsers reject its omission.
- A valid full id and a valid short id work.
- Two agents read version A. One writes B. The other cannot replace B with a revision of A.
- A stale amend fails even when its target text still occurs once in B.
- Invalid arguments cause no write. Stale revisions leave the ref unchanged.
- A stale replacement can leave an unreferenced object for GC, as the existing store API permits.

## 2. Add ordinary and maintenance tool sets

Proposed interface: `akyuu mcp --tool-set ordinary|maintenance`.
Use `ordinary` as the default, approved on 2026-10-22. Document the compatibility change.
Use `maintenance` as an explicit choice for existing consolidation clients.
Require version checks in maintenance too.

The ordinary set contains:

- `context`, `search`, `get`, `log`, and `unfold` for recall.
- `note` for retained episodes.
- `add` for current knowledge, with a required new `ref`.
- `amend` and `supersede` for revisions, with required `expected`.

Keep `unfold` because log recall can return summaries.
Keep `append`, raw ref tools, graph tools, checks, comparisons, reviews, and summaries in maintenance.
Maintenance retains the full tool set, including raw `add` without a ref.

Keep the existing name `add` to avoid two names for the same task.
Its ordinary schema and parser require `ref`; its maintenance form permits an unreferenced object.
Describe this difference directly. An outgoing link does not retain its source memory.

Derive tool listing, argument-name checks, and dispatch from the selected tool set.
Reject a tool outside the set even if a client calls it by name.
Do not treat the tool set as access control; the process still has access to the store.
Keep the selection fixed for the lifetime of one MCP connection.

Start with the CLI flag and `McpConfig` field.
Defer TOML, environment, and home-manager options until a concrete use requires them.
Use the existing configured agent as the default author for ordinary creation and replacement.
Retain an explicit author override. Do not infer authors from memory contents.
Require only task data; let the server supply the timestamp and the existing mechanical edges.

Tests:

- Each set lists exactly its intended tools and schemas.
- Ordinary calls cannot invoke maintenance tools by name.
- Ordinary `add` without a ref fails before storage.
- Ordinary `add` creates a ref and refuses an existing ref.
- A created ordinary memory survives GC after the grace period.
- Maintenance can create a raw object, with a clear retention warning in its description.
- CLI parsing selects each set and rejects an unknown value.
- Author defaults and explicit overrides work without changes to note author selection.

## 3. Explain links without a graph redesign

Keep current retention and identity rules.
Use short descriptions to distinguish exact-version links from topic links.
Explain that ID evidence links retain their targets when their source is live.
Explain that topic links follow the current ref and do not retain an old version.
Do not add implicit evidence links or copy all old links into a replacement.
Document that `amend` preserves metadata and `supersede` supplies a complete replacement.

Update the agent install guide, MCP examples, man page, and changelog.
Update ROADMAP.md when implementation starts, so it remains the authoritative work list.
Check all examples for required refs and version arguments.

## Code style

Use the existing code as the stylistic reference.
Follow nearby modules for types, functions, names, error handling, and tests.
Reuse established patterns before you introduce new abstractions.

## Delivery order

1. Commit the enforced version checks and focused regression tests.
2. Commit the tool-set selection, retained creation, author defaults, and tests.
3. Commit concise descriptions, migration guidance, and related documentation.
4. Run the relevant tests through `nix develop`, then run the repository checks.
5. Review the whole repository for private setup details before a PR.

Do not merge, push, restart an MCP client, or change the installed version as part of this plan.

## Evaluation

Use isolated temporary stores and a fixed set of tasks.
Include recall, episode capture, fact creation, revision, and a stale-writer conflict.
Compare the current interface with the ordinary set on the same tasks and models.
Record success, lost updates, unretained writes, tool errors, and tool-schema size.
Use scripted tests to prove the constraints before any model trial.
A model trial can show usability; it cannot prove concurrency safety.

## Approved choices

- Approved: ordinary is the default. This is a deliberate MCP compatibility change.
- Maintenance remains a full tool set, rather than a separate executable.
- Named `add` remains the ordinary creation operation.
- The first version uses a CLI selector instead of new persistent configuration.

These choices apply to this implementation. The running server does not change until a separate update.

## Validation

The local suite passes all 967 tests. Both MCP pipe scenarios pass.
The ordinary scenario checks author defaults, hidden tools, required versions, and short version ids.
The man-page check and the Haskell format check pass.
Model usability trials remain a separate experiment.
