# Topic verbs for agents

Status: proposed 2026-10-23. Not implemented. Nothing here is merged or installed.

## Goal

An agent must be able to use akyuu without a model of the store.
Today it must know ids, versions, edge kinds, and which of four write tools fits.
The new interface speaks in topics, which are ref names, and in plain text.
The store format, the graph edges, the CLI, and the core modules stay the same.

## What the agent must know today

This is the ordinary tool set from PR #18.

- An id is a version. The agent must `get` first, copy the `id:` line, and pass it back as `expected`.
- A new topic uses `add`, which refuses an existing ref. A change uses `supersede` or `amend`. A happening uses `note`.
- Links come in five kinds: `about`, `about_refs`, `refines`, `derived_from`, `supersedes`.
  Some link to an exact version and some follow a topic.
- A `search` hit can be an old version. The agent must read `superseded by` and `held by` to find the current text.
- `search` exposes `mode`, `hops` and `follow`.

## The idea: split the verbs by their algebra

Writes to a topic fall into three classes. Each class needs a different guard.

| Class | Operations | Guard |
|---|---|---|
| Commutative | `note`, `add_to` | None. Order does not matter, so the server can retry a lost race. |
| Local patch | `revise` | The text to replace. It must occur exactly once in the current memory. |
| Whole rewrite | `replace` | A version token that `recall` returned. |

In Haskell terms: appending is an action of a monoid on the body, so any interleaving gives the same set of lines.
A patch is a function that is partial on the body: the text match says whether it applies.
Only a rewrite needs compare-and-set from the agent.

The store already has the primitives. `supersedeFrom` checks the expected id under the mutation lock and rejects a stale call before it writes the object (see the header of `Akyuu.Supersede`).
`amendMemory` already reads the ref and writes with a check.
The new part is a retry loop around them, and a smaller vocabulary on top.

## The verbs

All verbs take a topic name, not an id. The configured agent is the author.
No result prints a `sha256-` id. The one exception to "no versions" is the version token of `recall`, described below.

### `recall`

Arguments: `query` or `topic` (exactly one), and optional `limit`.

- With `query`: search with the defaults (fused, one hop, all link kinds).
  Show each hit as a topic. A hit on an old version becomes the current version of the same topic.
  Two hits on one topic become one entry. A hit that no ref holds, such as an episode, shows its log and time.
- With `topic`: the whole current text, the version token, the kind and author, the topics it is about, and the topics that are about it.
- Long text is cut at about 600 characters in a query result, with a line that says how to read the rest.
- No hit prints `No topic matches.`, not nothing (finding C2 of the evaluation).

The version token is the first 12 hex digits of the current id, without the `sha256-` prefix.
It is opaque to the agent: copy it into `replace`. The server expands it with the existing prefix lookup.
An ambiguous token is an error that tells the agent to call `recall` again.

### `remember`

Arguments: `topic`, `text`, optional `kind` (default `fact`), optional `about` (a list of topics).

Make a new topic. It uses `addUnderRef`, so a ref that exists is refused.
The refusal shows the first lines of the current text and names `add_to`, `revise` and `replace`.
After a successful write, the result lists up to three topics whose text is close to the new text.
This is advice only. It does not block the write.

### `add_to`

Arguments: `topic`, `text`.

Append a line to a topic. The server reads the ref, applies `Append`, and writes with the read id as the expected value.
On `Stale` or `Locked` it reads again and repeats, up to five times. The agent needs no version.
A topic that does not exist is an error that lists the closest topic names and names `remember`. A typo must not make a new topic.

### `revise`

Arguments: `topic`, `replace` (a list of `{from, to}`, as in `amend`).

Apply the patch to the current memory. It uses the same retry loop as `add_to`.
`from` must occur exactly once. When it does not, the error includes the current text of the topic, so the agent can fix its patch in one more call.
The result shows the changed lines, so the agent can see what it produced.

This reverses one choice of PR #18 for this verb only: a patch that applies cleanly to a newer version is accepted.
The text match is the guard, as in a three-way merge of separate hunks.
The risk is an edit that applies cleanly but is wrong in view of the newer text.
The shown result is the mitigation. `replace` keeps the strict rule.

### `replace`

Arguments: `topic`, `text`, `version`.

Rewrite the whole text. It uses `supersedeFrom` with the token as the expected id and does not retry.
A stale token is an error that carries the current text and the current token, so the agent can merge and call again.
The kind and the links of the old memory stay, as in `amend`. An optional `about` replaces the topic links.

### `note`

Arguments: `text`, optional `kind`, optional `topics`.

The same as the ordinary `note`, with `about_refs` named `topics`.
The id-based links `about`, `refines` and `derived_from` are not in this set.
An agent that wants evidence names it in the text. Maintenance keeps all the links.

### Kept as they are

`context`, `log` and `unfold` stay unchanged in the first version. `log` shows ids for episodes, which have no topic.
Show full bodies by default in this set, so that the agent never needs `get`.
Open: fold `log` and `unfold` into `recall`.

## Guards that apply to all verbs

- Refuse a blank body (empty or only white space) in `Ops`, for every writer, CLI and MCP.
  This is finding A1 of the evaluation. It is a behaviour change of the CLI: put it in its own commit and in the changelog.
  The error says: "The body is empty. To forget a topic, say what should replace it."
- Refuse `add_to`, `revise` and `replace` on a log. A log head must stay in its chain.
  The check is: the head memory has a `follows` edge. A first episode has none, so the predicate needs a second rule.
  Decide it in the first commit of the Ops work, with a test for a one-episode log. The error names `note`.
- A refused call writes nothing.

## Design

- Add the operations to `Akyuu.Ops`, where the CLI and the MCP server share them:
  `rememberTopic`, `addToTopic`, `reviseTopic`, `replaceTopic`, `recallQuery`, `recallTopic`, and one `retryStale` helper.
  The helper takes a limit and an action, and repeats on `Stale` and `Locked` only.
- Put the pure parts in a new module `Akyuu.Topic`: the version token, the rendering of `recall`, the choice of similar topics, the log predicate.
  They get unit tests that need no store.
- In `Akyuu.MCP`, add `Topic` to `ToolSet` and the flag `--tool-set topic`.
  The tool list of this set is its own list, not derived from `toolList`, because the verbs are new.
  Make the argument-name check (`toolArgNames`) depend on the selected set.
  Give the new `ToolCall` constructors records (the roadmap item on records for tool calls).
- Leave `Ordinary` as the default. The default changes only after the evaluation, and only when the maintainer decides.
- Leave the core modules alone: `Id`, `Graph`, `Memory`, `Store`, `Refs`, `Cache`.
  The bytes of a memory, the ids and the ref file format do not change.

## Tests

Scripted tests prove the constraints. A model trial can show usability, not safety.

- The Topic set lists exactly its tools. A maintenance tool called by name is refused. Each schema has the arguments above and no others.
- No result of any verb contains `sha256-`.
- `add_to`: twenty concurrent writers (processes, as the existing helper scenarios do) to one topic leave all twenty lines.
  Afterwards `check` shows no fork and no unreferenced memory, and `verify` is clean.
- `add_to` and `revise` on a missing topic, a log, and a blank text fail and write nothing.
- `revise` applies to a newer version when `from` occurs once, and fails with the current text when it does not.
- `replace` with a stale token fails and leaves the ref unchanged. With a current token it succeeds, and kind and links stay.
- `remember` on an existing ref fails and shows the current text. On a new ref it lists close topics.
- `recall` replaces an old hit with the current version, merges two hits on one topic, and prints `No topic matches.` for no hit.
- A token of eight digits works. An ambiguous token fails with an instruction.
- The size of `tools/list` for the Topic set is recorded, and it is below the size of the Ordinary set.

## Delivery order

1. Refuse blank bodies in `Ops`, with tests and a changelog line. This can be its own PR.
2. `Akyuu.Topic` and the Ops operations, with the pure tests and the concurrency test.
3. The Topic tool set in `Akyuu.MCP`, with its tests.
4. Documents: the agent install guide, the MCP part of the man page (the `man` check runs), the changelog, the server instructions for the set, and ROADMAP.md.
5. Run the tests through `nix develop`, then the repository checks.
6. Search the whole repository for private setup details before a PR (`git grep`, not only the diff).
   Examples in docs and tests use neutral names such as `notes/oven`.

Do not merge, push, restart an MCP client, or change the installed version as part of this plan.

## Evaluation

Use the scenarios of `feat/agent-eval` (it is not merged): cold start and recall, change a fact, a concurrent change, a log.
Run each with a blind subagent twice, once on the Ordinary set and once on the Topic set, on the same model.
Record success, tool errors, number of calls, lost updates, unretained writes, and the size of `tools/list`.
The branch has to be merged or rebased first, or the scenarios copied. Decide this at step 5.

## Related findings from the evaluation

`docs/plans/eval-findings.md` (untracked) is from 2026-10-17 and is older than PR #19.

- A1, an empty body: still open. Step 1 fixes it.
- A2, a lost race leaves a fork: `Akyuu.Supersede` now says that a stale expectation is rejected before the write.
  Check this with the test above, and remove the known-issue marks K16 and K17 in the eval branch if it holds.
- C2, silent search: `recall` answers it for this set. The CLI and the other tool sets still print nothing.
- P25, the id length: not reachable in this set, because the agent never types an id.

## Decisions (the maintainer's)

Decided 2026-10-23: the proposed answer holds for each item.
For items 3 and 5 the proposal is to change nothing yet: `log` and `unfold` stay as they are,
and `Ordinary` stays the default until the evaluation has run.

1. Similar topics after `remember`: advice after the write (proposed), or refuse when a close topic exists.
   The proposal avoids a false match that blocks a legitimate write. `check` already finds duplicates later.
2. `add_to` on a missing topic: an error with suggestions (proposed), or create it.
3. Fold `log` and `unfold` into `recall`.
4. Drop the id-based links from `note` in this set (proposed). Revisit if the evaluation shows that agents want evidence links.
5. Which set is the default after the evaluation.
6. Whether the CLI gets the verbs too. Not planned now.

## Risks

- A clean `revise` on a changed topic can be wrong in meaning. The shown result reduces this and does not remove it.
- The log predicate can miss a one-episode log. The first commit of step 2 must settle it.
- The agent cannot read the history of a topic in this set. It stays in Maintenance and the CLI. Forgetting is outside this plan.
- The topic name is still the agent's choice. The advice after `remember` and the suggestions of `add_to` help, and they do not decide.

## Code style

Use the existing code as the stylistic reference.
Follow nearby modules for types, functions, names, error handling, and tests.
Reuse established patterns before you add new abstractions.
