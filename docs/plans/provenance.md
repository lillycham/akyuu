# Provenance: where a memory came from

Status as of 2026-11-07: a proposal. Nothing is built. The open questions at the
end need a decision before any code.

## Goal

A memory should be able to say which part of which agent session it came from.
A person or an agent can then read the original exchange, and check that the
memory still says what the exchange said.

Agents already keep full transcripts on disk. akyuu should point at them. It
should not copy them.

The first use is the consolidation pass. A note is a claim about a session.
With a pointer, the pass can compare the claim with the session, and does not
have to trust the note.

## What is on disk

- Claude Code writes one file for each session, `<session id>.jsonl`, in a
  folder for each project. Every record has a `uuid`, a `parentUuid`, a
  `sessionId` and a `timestamp`. The records are append-only.
- Codex writes one `rollout-<time>-<session id>.jsonl` for each session. The
  first record, `session_meta`, has the session id. Every record has a
  `timestamp` and an `ordinal`.
- The two formats differ. Other agents will differ again.
- On one machine the Claude Code folder is about 740 MB in 184 files. Most of it
  is tool output and hook payloads.
- A transcript can hold secrets and private text. Its text must not go into
  the store.
- Agents may delete old sessions. On this machine the oldest one is from
  2026-09-27 and none was removed, but another machine or setting may differ.
  A pointer can therefore dangle, and that must be a normal result.

## Decision: a pointer is a memory, not a header

There are three ways to record a pointer.

1. A new header in the memory file, like `about-ref`. This changes the
   canonical form. Older akyuu refuses the file, as `format.md` says for
   `follows` and `about-ref`. The pointer also becomes part of the id, so the
   same text with two sources is two memories, and `check` will call them
   duplicates.
2. A side index outside the store, from memory id to pointer. The pointer can
   change when a file moves. But the index is not content-addressed, GC does not
   know it, and sync would have to carry it.
3. A memory of kind `source` that holds only the pointer, and a `derived-from`
   edge from the memory to it. No format change.

This note proposes 3.

- The format, the ids and the edges do not change. Older akyuu reads the store.
- The same pointer is the same memory, so it is stored once.
- GC keeps a pointer while a memory derives from it, and no longer.
- The graph, `neighbours` and the web view show the link with no new code.
- The pointer cannot change, but it does not have to. The session id is the key,
  and the path is only a hint (below).

One caution: an episode with exactly one `derived-from` edge is a legacy shape
(see `previousChecked`). A note of this kind has a `follows` edge, so it is read
correctly. A first episode of a log cannot carry exactly one `derived-from`
edge, and `append` already refuses it.

## The pointer

Kind `source`, agent as for any memory, body of `key: value` lines:

```
agent: claude-code
session: 0775d85c-5836-4715-a3a7-f306d261bf49
from: 1a65b40b-18eb-42b1-befb-ecd00702cc97
to: e1c8399c-1294-4b30-937d-6e0d363a28cd
at: 2026-11-01T19:00:58Z
sha256: <hash of the bytes of the records from `from` to `to`>
hint: projects/-Users-me-code-app/0775d85c-5836-4715-a3a7-f306d261bf49.jsonl
```

- `agent` names the transcript format, so the right reader is used. It is not
  the author of the memory.
- `session` is the key. Resolution looks for it under configured roots. It does
  not use the hint if the file is elsewhere.
- `from` and `to` are optional. If an agent cannot name records, the pointer has
  only `at`, and resolution reads the records near that time. The note's own
  `created` time is a good `at`.
- `sha256` is optional. With it, `verify` tells a changed span from an intact
  one. Without it, `verify` only says that the session is found. It is the hash
  of the records in archive form (see "The archive"), so that a live file and
  its archived copy give the same hash.
- `hint` is relative to a root, so a person's home directory is not in the store.
  It may be absent.

## The archive

Decided 2026-11-07. Sessions are archived by a separate program, not by akyuu.
akyuu only reads the archive.

- The program copies closed sessions into an archive folder and compresses each
  one with zstd. It copies. It never moves or deletes an original: the person
  keeps the live files for now.
- A session is closed when its file has not changed for some hours (a setting)
  and no running agent holds it. A session that later grows gets a newer copy.
  Because the files are append-only, the program checks that the old copy is a
  prefix of the new one before it replaces the old one.
- The archive layer does not parse a transcript. It stores opaque bytes and a
  manifest: agent, session id, size, first and last time, working directory, the
  hash of the archive form, and the version of the strip rule.
- Layout: `<agent>/<session id>.jsonl.zst` and an append-only `manifest.jsonl`.
  Files never change after they are written, so `rsync` copies the folder to an
  external drive in increments. The program does not need the drive. The copy
  is a separate job.
- The program runs as a scheduled service (a launchd agent, declared in the
  person's system configuration) and has a `verify` command that re-reads the
  archive and checks the hashes.
- It is written in Haskell.
- A session is idle after 6 hours without a change. This is a setting.
- A session that grows gets a new copy (`<session id>.2.jsonl.zst`). The old
  copy stays. The program checks that the old copy is a prefix of the new one,
  and records both in the manifest. It deletes nothing, on the machine or on
  the drive.
- Encryption: the person encrypts the archive with `age` when it goes to the
  external drive. The proposal is to encrypt at the export step, not in the
  local archive. akyuu then reads the local archive without a key, and the local
  archive holds nothing that the live files do not already hold. The export
  needs only the public key, so the private key can stay off the machine. It
  encrypts the manifest too, because it holds folder names. `age` output
  differs on every run, so the export must remember which files it sent. It
  must never encrypt a file again to compare it.

### Archive form: images are stripped

The archive drops the base64 data of images, which is most of what does not
compress. It keeps a placeholder with the size, the media type and the hash of
the dropped data. The originals still have the images.

The strip must not change anything else. It replaces the text of the data value
inside its line and leaves every other byte alone. It does not parse the JSON
and write it again, because that would change key order and spacing and break
the hashes.

The pointer's `sha256` is over the records in archive form. A reader of a live
file applies the same strip before it hashes, so the live file and the archive
agree. The strip rule is deterministic and has a version number. The manifest
and the reader both record it. A new version of the rule means a new hash, so
an old pointer says `changed` and not `intact`: that is the right answer, and
it is why the version is written down.

Resolution order: the live folders first, then the archive. A pointer that
resolves in neither is `unavailable`.

## Reading a pointer

New command `akyuu source show ID`, and a matching MCP tool:

- Find the file: roots from the config, then the session id in the name or in
  the `session_meta` record.
- Read the records of the span, and print them with the speaker and the time.
  Tool output is cut to a limit, because it is the noisy part.
- If the session is not found, say "source not available on this machine" and
  exit with a distinct status. This is not an error of the store.

New command `akyuu source verify ID`: the same lookup, and a comparison of the
hash. Results: `intact`, `changed`, `unavailable`.

A reader is a small record: how to find a session, how to list the records of a
span, and how to render one record. One module for each format. The core knows
the record and not the formats. Claude Code is the first reader, Codex the
second.

## Writing a pointer

Phase 1 needs no automation. A command, `akyuu source add --agent claude-code
--session ID [--from U --to U] [--at TIME]`, makes the memory and prints its id.
An agent then gives that id as `--derived-from` to `add` or `note`.

Capture comes later and is the hard part:

- The model does not know its own session id. A start hook gets it from the
  agent (Claude Code passes `session_id` and `transcript_path` to hooks on
  stdin). The plugin's start hook can print it with the context, so the model
  can use it.
- The model does not know record ids. The time of the note is enough: the note
  has `created`, so a pointer with `at` finds the records near it.
- Whether the MCP server itself can learn the session id, for example from an
  environment variable, is not checked. A test is needed.

## What it enables

- The dream pass reads the pointer of a note and the span, and checks the claim.
  A mismatch becomes a line in the report, as now.
- `check` reports only a pointer with a bad shape. It cannot report a missing
  file, because the transcripts may be on another machine.

## Limits and risks

- Privacy. `source show` prints transcript text. Run on the terminal it shows
  nothing that the person cannot already read. As an MCP tool it hands text from
  one agent's sessions to another agent. Make the MCP tool opt-in in the config,
  and leave it out of the web view in phase 1.
- Neutral code. The core, the docs and the demo store say "source" and "agent
  session". Names of agents and folders live in the readers and in the config
  example.
- Sync. A pointer syncs like any memory. It resolves only where the transcripts
  are. `unavailable` is the expected answer elsewhere.
- Cost of search. Finding a session by id means a scan of the roots. With a few
  hundred files this is cheap. It may need a small cache, keyed by session id.
- A span hash can break if an agent rewrites its file. Treat `changed` as
  "look", not "wrong".

## Phases

0. The archive program, with the strip rule, the manifest, `verify` and the
   service. It stands alone and can ship first. The strip rule is shared by the
   readers below, so it is written down before them.
1. The `source` kind, `source add`, `source show`, `source verify`, the Claude
   Code reader (live folders and archive), config roots, tests, `format.md` and
   a docs page. No capture.
2. Capture: the start hook prints the session id, `note` and `add` accept it,
   and the plugin documents it.
3. The consolidation pass uses `source show` for the notes of the last day.
4. The Codex reader. Search over transcripts is a separate decision, probably an
   index outside the store.

## Open questions

1. Pointer as a memory (this note), a header, or a side index?
2. Is `at` plus the session enough for phase 1, with `from`/`to` only when known?
3. May `source show` be an MCP tool, or terminal only at first?
4. Where do the roots live: the config file, or the manifest of the tiers?
5. Should the dream pass in phase 3 be allowed to write a `review` or a note
   about a mismatch, or only report?
6. The name of the archive program. (Language, idle time, grown sessions and
   encryption are decided above.)
7. Is the proposal to encrypt at the export step, and not in the local archive,
   right?
