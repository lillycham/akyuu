# Episodic memory

Status: built, 2026-10-11 (`akyuu append`, `akyuu log`, the MCP tools `append`
and `log`). This note says what the pattern is, why it is built this way, and
how to forget.

## Two kinds of memory

| | Fact (semantic) | Episode (episodic) |
|---|---|---|
| What | What is true now: a profile, a preference, the state of a project | What happened or was said: a decision, a conversation, an event |
| Changes by | `supersede`: the new text replaces the old one | `append`: a new episode is added, nothing is replaced |
| Where | A ref that names the current memory | A log: a ref that names the newest episode of a chain |
| Old versions | Garbage after the ref generations | Kept, as long as the log is |

An agent writes episodes eagerly and cheaply. A consolidation step turns
clusters of episodes into facts, and a fact is a normal ref.

## The log

A log is a ref, for example `agent/episodes`, that names the **newest**
episode. Each episode has a `derived_from` edge to the one before it:

```
ref agent/episodes ──> e3 ──derived_from──> e2 ──derived_from──> e1
```

`akyuu append REF --kind episode --agent NAME --body TEXT` adds the episode,
adds that edge, and moves the ref, in one compare-and-set. The first append
makes the ref. Two agents that append at the same time both get in: the
second one reads the ref again and builds its episode again (three tries).

`akyuu log REF [-n N] [--full]` walks the chain from the newest episode and
prints one line for each. A last line `more: ID` says where the log goes on.

### Why `derived_from`, and not `supersedes`

GC keeps a memory if a ref, a pin or a live memory's edge reaches it, and
liveness flows from the newer memory to the older one. A `supersedes` edge
does **not** keep its target: that is how an old version becomes garbage. An
episode must not be replaced, so the chain uses `derived_from`, which does keep
its target. The ref keeps `e3`, `e3` keeps `e2`, and so on.

An episode that is only `about` a topic is **not** kept alive by that edge. The
edge goes from the episode to the topic. Without a log or a ref above it, the
episode is garbage an hour later (the grace period). This is why a store of
eager notes needs the chain.

## Rules

- The `derived_from` edge of an episode is its link to the previous one. The
  tool adds it, and refuses a memory that has one of its own. Link an episode
  to a topic with `about` or `refines`.
- One log for one stream: an agent, a session, a project, a persona. Several
  logs are fine, and a summary can be derived from several of them.
- Keep an episode small and about one thing. Search finds them by words.

## Reading

- `log` for the recent episodes of one stream.
- `search` for anything, across logs and facts. The text index holds every
  episode, current ranking boosts a memory that a ref holds and a newer one.
- `get ID` for one episode, and `neighbours ID` for what points at it.

## Forgetting

A log grows, and forgetting is a deliberate act, so that nothing is lost by
accident. To forget the old part of a log, replace it with a summary:

```
akyuu supersede agent/episodes --kind summary --agent NAME --body "…"
```

The summary has a `supersedes` edge to the newest episode, and that edge does
not keep the chain. The chain is garbage once no ref generation names it
(`keepGenerations`, 5 by default, so after five more moves of the ref, or at
once with `--keep-generations 0`). New episodes then continue from the summary:
the next `append` derives from it. The summary is the trace of what was
forgotten.

To keep one episode forever, pin it (`akyuu pin ID`), or make it the target of
a `derived_from` edge from a fact that is under a ref.

## Promotion

Consolidation (see `policy/consolidation`) can read a log, write a fact that
holds what matters, put it under a ref, and give it `derived_from` edges to the
episodes that it comes from. Then the fact keeps those episodes, and the log
can be summarised without losing the evidence.

## A persona

A chat agent that remembers a persona and adapts it over time is two things:

- a **core** that a person writes and edits: stable, in the `always` tier;
- an **adaptations** memory that the agent supersedes as it learns, with a size
  limit and a review step in consolidation.

The log of episodes is the evidence for the adaptations. The split keeps the
agent from drifting without a person seeing it: the core does not change by
itself, and each version of the adaptations is a memory that can be read.

## Not built

- A `check` finding for a log that is very long, to suggest a summary.
- A retention setting for each log (keep the last N, summarise the rest).
- Branching logs (two agents that append to different heads of one log). They
  would be a fork of the chain: `append` does not make one, because it
  compare-and-sets the ref.
