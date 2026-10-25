# Related topics for agents

Status as of 2026-10-25: step 1 of the delivery order is written, and not committed: the pure module `Akyuu.Related` (`src/Akyuu/Related.hs`) and its 31 tests (`test/RelatedTests.hs`, two of them properties). The full suite and `ormolu` pass. Steps 2 to 7 are not started. The ranking was tried on a copy of the maintainer's own store (below).

## Goal

An agent that works on one topic should see up to three other topics that belong with it, and why.
It then finds the existing note and does not start a new topic, and it does not miss context.
The topic tool set already speaks in topics, so the list is of topics, with a reason for each.

The related list is derived data. It is computed when it is asked for, from the store as it is.
It is never written to the store, and the store format, the ids and the edges do not change.
A suggestion that was written down would become a label for the next suggestion.

## What the experiment found

The scripts were throwaway, and the data stays private. This plan keeps only the findings.

Store: 40 topics (a topic is a ref that is not a log), 780 pairs, vectors from `nomic-embed-text` v1.5, 23 explicit links between two topics.
The maintainer judged 166 pairs (yes, maybe, no) in two rounds: "Would you want to be shown this topic when you look at that one?"

- `closeTopics` finds nothing for any of the 40 topics. It is a duplicate warning (a fifth of the word triples), not a relatedness test. Its score has no signal here.
- Cosine alone separates yes from no with an AUC of 0.77. A link or a mention of the topic name in the text lifts it to 0.89 (a fixed sum, chosen after seeing round 1: optimistic).
- The hubness correction (CSLS) made it worse (0.71): it demoted general topics that the maintainer wanted to see, such as the profile and the preferences.
- Removing the shared component of the vectors made it worse, so that component is signal.
- Shared `about-ref` sets, creation time and word-triple overlap added nothing.
- A fitted logistic regression (leave one topic out) gave 0.86: no better than the fixed sum. No model is needed.
- Among topics of one kind that have many siblings (project topics), a pair with no link and no mention was a yes 4 times in 37. With a link or a mention it was a yes 14 times in 17. Sibling topics look alike because they share a template, not because they are related.
- A link or a mention from a topic that points at many topics is weaker evidence for each: weigh it by 1 / sqrt(how many topics the source points at). Without this, a summary topic became a hub of the explicit-link term.

Limits: one store, one person's judgement, one embedding model, 166 labels, weights chosen after seeing the first 143. The second round (23 pairs) is the only fresh test, and it was mixed (11 yes, 5 maybe, 7 no).
The strict precision of the top three was 0.63 for the new score and 0.62 for the first mix: about equal.

## The score

For a topic `a` and a candidate `b`:

    score(a, b) = z(cos(a, b)) + 2 * link(a, b) + 1 * mention(a, b)
                  - penalty, when a and b are siblings and have no link and no mention

- `cos`: the cosine of the topic vectors. A topic vector is the mean of the unit-length chunk vectors of its current memory.
  `z` uses the mean and the spread over all pairs of topics.
- `link(a, b)`: the larger of two directions. A direction counts when the current memory of one topic has an `about-ref` to the other, or an `about`, `derived-from` or `refines` edge to a memory that the other ref held now or before.
  Its strength is 1 / sqrt(the number of topics that its source links to).
- `mention(a, b)`: the name of one topic appears in the text of the other, as a whole name. The same damping.
- The sibling penalty is 1.5 to 3. It is the rule of the last finding. See the decisions.
- Only a candidate with a score above zero is listed: above the average similarity, or with some evidence. Of the 166 judged pairs, the 6 at or below zero held no yes (5 no, 1 maybe), and only one topic had no candidate above zero.
- Ties break by name. Scores that differ only in the ninth decimal count as equal, so the order of the topics on disk cannot change the result.
  The list has at most three entries and every entry has a reason: `linked`, `mentioned` or `similar text`, the strongest one first.
- A name counts as mentioned only as a whole name. A longer name or path that contains it does not count (`kitchen/oven2`, `home/kitchen/oven`, `kitchen/oven/door`, `kitchen/oven.l1`). A full stop that ends a sentence does.
- No vector (no embedder, or the vectors are for another model key): the cosine term is left out and the list holds only topics with a link or a mention. This is the fallback, and it needs no model.

## Where it goes

1. `recall` with a `topic`: a line `Related topics: name (reason), ...` after the topics it is about.
2. `recall` with a `query`: a `See also` line under each hit, only for the first three hits. Flag it as optional: it costs tokens.
3. `remember` already shows topics with similar text (`closeTopics`). That stays: it answers "does this repeat one?". A new topic has no vector yet, so only the mention term is used there.

The ordinary tool set is not changed in the first version.

## Design

- A new pure module `Akyuu.Related`. It takes the topics, their vectors, their link sets and their texts, and returns the ranked list. No IO, no store.
- `Akyuu.Ops` reads the inputs (current memories, the about-ref links from the cache, the chunk vectors from the embedding table) and calls it.
- `Akyuu.Topic` renders the lines. The names of topics are the only strings of the store in the result: a ref name has a restricted character set, and no memory text is shown, so a memory cannot put an instruction into the list.
- A setting turns the feature off, so that the evaluation can run it on and off: `[topic] related = true` in `config.toml`, and the environment variable that goes with it.
- The cost of `z` is one cosine for each pair of topics. Compute it when asked for stores up to a few hundred topics, measure it, and cache it per store state if it is slow.
- The core modules stay as they are. No store format change, no cache schema change.

## Tests

The tests use hand-made vectors and the neutral demo store (`seed --demo`, topics such as `notes/oven`) with the fake embedder of the evaluation harness. They never use the maintainer's store or judgements.

- Cosine orders topics. A link or a mention beats a small cosine difference.
- A source that links to many topics gives each one less than a source that links to one.
- Ties break by name. The result is the same for the same input.
- No vector: only linked and mentioned topics appear. A topic with neither gets an empty list, and the line is left out.
- Logs are not topics and never appear. The topic itself never appears.
- A topic that was renamed or superseded: the current memory is used, and a link to an old version of a ref still counts.
- The sibling penalty applies to siblings only, and not when there is a link or a mention.
- The result for a given store is stable when the order of the refs on disk changes.
- `recall` of a topic prints at most three topics and a reason for each. No result has an id.

## Evaluation

Offline: done once, on the maintainer's store (above). Do not tune further on those 166 labels: every change makes the numbers look better than they are.

With agents: the harness on `feat/mcp-eval` (not merged; merge it first or copy the scenarios).
Add one scenario, S8: the store holds about ten topics. An agent must record a fact that belongs with an existing topic whose name it cannot guess from the task.
Run it with the feature on and off, on Sonnet and Haiku, three runs each, as the topic evaluation did.
Record: the topic that got the fact, new duplicate topics, number of calls, tool errors, the size of a `recall` answer, and cost.
Also run S1 to S3 again, to check that the extra line does not make agents merge things that should stay apart.
The feature stays if S8 improves and S1 to S3 do not get worse.

## Delivery order

1. `Akyuu.Related` and its pure tests.
2. The inputs in `Ops`, the rendering in `Akyuu.Topic`, the setting, and the tests on the demo store.
3. The query hits, only if step 6 shows they help.
4. Documents: the man page, the changelog, the server instructions of the topic set, ROADMAP.md.
5. The repository checks, through `nix develop`.
6. The evaluation.
7. Search the whole repository for private setup details before a PR (`git grep`, not only the diff).

Do not merge, push, restart an MCP client or change the installed version as part of this plan.

## Decisions (the maintainer's)

1. Who writes the Haskell: Claude (like `Akyuu.Topic`), or the maintainer with tests and pointers from Claude.
2. The sibling rule. Sibling topics (the same parent namespace) look alike because of a shared template, and the judged pairs without evidence were mostly "no". Options:
   a. A generic rule: a penalty for sibling pairs when the parent namespace has many topics. The cut-off (say ten) was tuned on one store, and `policy`-like groups of five were mostly "yes".
   b. A setting that lists the namespaces whose topics are parallel instances (the default is none).
   c. No rule in the first version, and let the evaluation say.
   The proposal is (b) with an empty default, and (a) only if the evaluation asks for it.
3. Query hits: part of the first version, or after the evaluation (the proposal).
4. The default of the setting in the topic set (the proposal: on, so that the evaluation measures the real behaviour, and a way to turn it off).
5. Fixed weights (the proposal) or weights in the config.
6. The ordinary tool set: later, if the topic set shows a gain.

## Risks

- One person's judgement on one store. Another store may want other weights.
- A change of the embedding model changes every cosine and the spread. The fallback and the key check (as `status` does) must cover it.
- An agent may merge topics because they are listed as related. S1 to S3 test this.
- The reason is a guess about why two topics are near. `similar text` is the weakest reason, and the text says so.
- The sibling penalty is the least proven part of the score.

## Code style

Use the existing code as the stylistic reference.
Follow nearby modules for types, functions, names, error handling, and tests.
Reuse established patterns before you add new abstractions.
