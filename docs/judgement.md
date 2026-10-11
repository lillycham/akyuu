# The judgement phase

Status: planned, 2026-10-11. Steps 0 and 1 are built (see "Order of work").
Detection is `akyuu check` (see `check.md`). This note is about what happens
after it: deciding what to do with a finding.

## What needs a model

| Finding | Model? | Action |
|---|---|---|
| `StaleLink` | No | Retarget the edge to the head that `resolve` names. A person runs it by hand. |
| `DuplicateBody` | No | Keep the memory that a ref holds, or the newest. GC collects the others. |
| `Unreferenced` | Mostly no | Give it a ref, pin it, or let GC collect it. |
| `Fork`, `NearDuplicate` | Yes | Copy, replacement, merge, or both true. |
| `Hub` | No | Information. |

The model rules only on forks and near duplicates, and only on what it is handed.

## Rules

- **The store has no model.** Akyuu never calls a model, names one, or holds a
  key. The agent that runs the procedure is a deployment choice.
- **Portable.** The procedure is a memory in the store, under a neutral ref
  (for example `policy/consolidation`), like the memory policy. Any agent that
  can read the store can follow it. A skill for one agent is a pointer to it.
  Ref names are configuration (`--policy-ref`, `AKYUU_POLICY_REF`), not
  constants.
- **A guard that does not trust the model.** `compare A B` lists the sentences
  that only A has and the sentences that only B has. A verdict "B is a
  duplicate of A" is refused when B has a sentence that A lacks. The right
  verdict is then `merge`, `supersedes` or `distinct`. A weak model cannot
  lose a fact through this path.
- **Nothing is deleted.** An old memory stays in the ref history (5
  generations) and then in trash (7 days).
- **Caps and a dry run.** A run makes at most a few supersedes. A dry run
  writes only the report.
- **`unclear` is an answer.** The pair stays for a person.

## Verdicts

For a pair or a group:

- `duplicate keep=A drop=B`: allowed only when B has no sentence that A lacks.
- `supersedes new=A old=B`: A replaces B. If B is under a ref, `supersede` the ref.
- `merge`: write a new memory that is `derived_from` both, supersede both.
- `distinct`: both are true and different. Record it, so `check` stops
  flagging the pair (see step 2).
- `unclear`: leave it for a person.

For a fork: choose a head, or merge. The loser is superseded by the winner.

## Models

A small model is likely enough to classify one small diff into a verdict with
a short reason. It is not the right model to write a merged memory or to rule
on a fork where both heads have unique content: those go to a larger model or
to a person. This is advice in the procedure text and not code. Measure it on
the fixtures before relying on it: the false `duplicate` rate must be 0 after
the guard, and `unclear` should be rare.

The fixtures are the incidents of 2026-10-11: the two ultrakill memories (one
sentence differs), the two values memories (a closing line is worded
differently), the stale links to the old profile, and the unreferenced copy of
the akyuu project memory.

## The report

A run writes one report memory to one ref (for example
`policy/consolidation-log`), superseding the last one. It lists each pair, the
verdict, the reason, and what was done. A person reviews one text, not each
memory.

## Order of work

0. [x] The policy ref of the MCP server is configuration, with a neutral default.
1. [x] `akyuu compare A B` and the MCP tool, with the drop guard.
2. [ ] `akyuu review A B --verdict distinct --agent NAME`: a file in `reviewed/`
   (like `pins/`). `check` skips a reviewed pair. The ids are content hashes,
   so a pair expires when either text changes. GC removes entries whose ids are
   gone.
3. [ ] The procedure memory and a thin skill that points to it. A dry run on a
   copy of the store, compared with what was done by hand.
4. [ ] Run it for real, by hand, and read the report.
5. [ ] Later, maybe: a timer that runs the procedure weekly.

Decided:

- "Both true" is a file in the store, not an edge kind in `Graph`.
- The procedure applies `duplicate` and `distinct` verdicts itself. It only
  proposes `merge` and fork choices.
- Retargeting stale links is manual. It is not part of an unattended run.
