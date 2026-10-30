---
name: memory
description: How to keep long-term memories in akyuu, through the akyuu MCP tools. Use when you learn something that a later session needs (a decision, a finished piece of work, a gotcha, a fact about the person or their projects), when you need to remember what earlier sessions knew, or when the person says "remember", "note that", "what do you know about" or "forget".
---

# Memory in akyuu

akyuu is a store of memories that every session shares. The context at the
start of the session came from it. If the store has a policy (`context` names
it, often as a ref such as `policy/memory`), follow the policy: it wins over
this page.

## Read

- The start of the session already holds the context. Do not call `context`
  again, unless a page of it is missing.
- Use `search` before you answer from your own guess about the person, their
  projects or earlier decisions. A hit can be superseded: read the newer one.
- A memory that is cut short, or a ref that the context names, is read whole
  with `get`.

## Write as you go

Write when it happens, not at the end of the session:

- A decision is made or changed: `note` it, with the reason in one clause.
- Something is finished (a merge, a release, a deploy): `note` it.
- You learn a gotcha, or an assumption was wrong: `note` it.
- The person tells you something about themself, their projects or their
  tools: `note` it, and if it will last, write it as a fact under its topic.

A note is an episode: something that happened. A fact is what is true now,
and it lives under a ref (such as `me/projects/garden`). To change a fact,
`get` the ref first, then pass the id you read as `expected` to `amend` (one
passage) or `supersede` (the whole text). If the id is stale, read the ref
again and redo the change on the new text. Use `add` with a new `ref` only
when no ref covers the topic.

## How to write a memory

- One topic for each memory, and one ref for each topic. Plain, short
  sentences.
- Give absolute dates, and date what can go stale ("as of 2026-01-31").
- Say why it matters and how to apply it, not only what it is.
- Do not write secrets, what the code or its history already says, or what
  only matters in this conversation.
- If the person says "off the record", write nothing about it.
- If the person says to forget something, replace the memory with a text that
  leaves it out.

Before a long session ends, write one note: what was done, what is open, what
is next.
