# Store format, version 1

Status: this is the format that akyuu 0.1 and 0.2 write and read. It has no
version marker in the files: a store without one is version 1.

This note is for a person who wants to read a store without akyuu, write a
tool for it, or move it. Everything here is plain text on disk.

## What is stable

| Part | Where | Stable? |
|---|---|---|
| Memories | `store/` | Yes. The format of a memory and its id are fixed (see below). |
| Refs | `refs/` | Yes. One id on each line, newest first. |
| Pins, reviews, tombstones | `pins/`, `reviewed/`, `tombstones/` | Yes, but they are small and akyuu can write them again. |
| Trash | `trash/` | Objects that GC moved. The same format as `store/`. |
| Cache | `cache.sqlite` | No. It is derived. Delete it any time: `akyuu reindex`. |
| Vectors | `embeddings.sqlite` | No. It is derived from the memories and the model. |
| Locks | `*.lock`, `.lock` | No. They carry no data. |

Before 1.0, an incompatible change to the stable parts is possible. If one
happens, the CHANGELOG says so and says how to move a store. A new version of
akyuu reads every store that an older one wrote. An older version refuses a
file with a header it does not know (it does not read it wrongly).

## A memory

A memory is one UTF-8 file, `store/<xx>/sha256-<64 hex digits>.md`. `<xx>` is
the first byte of the digest in hex. The file name is the id, and the id is the
SHA-256 of the bytes of the file. So a memory cannot change: a changed text is
another memory.

```text
kind: fact
created: 2026-10-05T12:00:00Z
agent: claude
supersedes: sha256-<64 hex digits>
about: sha256-<64 hex digits>
derived-from: sha256-<64 hex digits>
refines: sha256-<64 hex digits>
about-ref: me/notes

The body is free text. It may have many lines.
```

Rules:

- `kind`, `created` and `agent` are required, once each, in this order.
  `kind` and `agent` are one line, not empty, with no space at either end.
- `created` is UTC, in whole seconds: `YYYY-MM-DDTHH:MM:SSZ`.
- The edge headers are optional and may repeat, one id on each line. Their
  order is `supersedes`, `about`, `derived-from`, `refines`, and inside one
  name the ids are in ascending order. A repeated edge is not allowed.
- The `about-ref` header is optional and may repeat, one ref name on each
  line. It comes after all the edge headers, the names in ascending order. A
  repeated name is not allowed.
- A header line is the name, a colon, one space, and the value.
- The body is everything after the first blank line. It is not changed or
  trimmed. Lines end with a line feed only.
- This is the one canonical form. akyuu refuses a file in another form
  (headers in another order, a repeated edge, an unknown header), because the
  id must be the hash of the file.

## Edges

An edge goes from a newer memory to an older one (or to an id that is not in
the store: a dangling target is allowed).

| Header | Meaning | Keeps the target alive for GC? |
|---|---|---|
| `supersedes` | This memory replaces the target. | No. |
| `about` | This memory is about the target. | Yes. |
| `derived-from` | This memory comes from the target. | Yes. |
| `refines` | This memory adds detail to the target. | Yes. |

The graph is acyclic, because an edge points at a memory that existed when the
new one was made.

## Links to refs

`about-ref: NAME` says that the memory is about the ref `NAME`: about whatever
memory the ref names now, not one exact text. Use it for a topic that changes,
such as a project. Use `about` with an id for one exact memory, and
`derived-from` for evidence.

A link is not an edge of the graph. It is resolved when it is read
(`neighbours`, `search`, the web view), so it does not go stale when the ref
moves. GC keeps nothing through a link: the ref keeps its own memory. A link
to a ref that does not exist is a `missing-ref` finding of `check`, and `add`,
`supersede`, `append` and `note` refuse one.

akyuu 0.2.0.0 and older do not know this header, so they refuse a memory
that has one.

## Refs

`refs/<name>` is a text file with one id on each line. The first line is the
current memory. The others are the older values, newest first (the
generations that GC keeps, `--keep-generations`).

A name is parts of `a-z`, `0-9`, `-`, `_` and `.`, joined with `/`. A part is
a directory, so a name cannot be the start of another name. Writes are atomic,
and a change takes a lock (`refs/.lock`) and can check the current value.

## Other files

- `pins/sha256-<...>`: an empty file. The name is a pinned id.
- `tombstones/sha256-<...>`: one line, `pruned: <time>`. GC leaves it when it
  deletes an object, so a read can say "GC deleted this, read the newer one".
- `reviewed/<id>_<id>`: a small text file. The pair of memories that a person
  judged to be different (the lower id first).
- `trash/sha256-<...>.md`: an object that GC moved out of `store/`. GC deletes
  it after the trash TTL (7 days by default).

## Moving or copying a store

Copy `refs` and `pins` first, then `store`, `reviewed` and `tombstones`. An agent
writes a memory before it moves a ref to it, so refs that were copied first
point only at memories that the later copy has (`akyuu-backup` does this). Then `akyuu reindex` and `akyuu verify`.
