# Provenance: where a memory came from

Status: the pointer, `source add`, `source show` and `source verify` are built,
for Claude Code transcripts. An MCP tool, a check of the hash of a span, and
the Codex and omp formats are not built yet.

An agent writes a note after a session. A month later the note is all that is
left of the session, and you cannot tell whether it is right. A pointer fixes
that: the memory says which session it came from and when, and `akyuu source
show` prints what was said around that time.

akyuu does not copy the transcripts into the store. They are files that an
agent keeps, or an archive of them. A pointer says where to look, and the
store stays small, immutable and free of text you would not want to keep.

## A pointer

A pointer is a memory of kind `source`. Its body is a few `key: value` lines:

```
format: claude-code
session: 0775d85c-5836-4715-a3a7-f306d261bf49
at: 2026-11-01T19:00:58Z
```

| Field | Meaning |
|---|---|
| `format` | The transcript format. Only `claude-code` so far. |
| `session` | The session: the id that its file is named for. |
| `at` | The time the memory is about, to the second. |
| `from`, `to` | Optional. The ids of the first and the last record, if something knows them. With both, `source show` prints that range. |
| `hint` | Optional. A path below a root, for a person to read. It is never used to find the file, and it must not hold a home directory. |

A memory is linked to its pointer with a `derived-from` edge. The store format
does not change, so older akyuu reads a store that has pointers; it sees
memories of kind `source`.

## Use

Make a pointer, and link a note to it:

```
$ akyuu source add --session 0775d85c-5836-4715-a3a7-f306d261bf49
sha256-…                                  # the id of the pointer
$ akyuu add --kind fact --agent me --derived-from sha256-… --body "We chose zstd for the archive."
```

`--at` is the time the memory is about, like `2026-11-01T19:00:58Z`. Without
it, the time is now, which is right when an agent writes the pointer during
the session.

Read it back:

```
$ akyuu source show <id of the fact>
source sha256-ff9af3e764dc: claude-code session 0775d85c-…, around 2026-11-01 19:00:58 UTC
  read from live file /…/0775d85c-….jsonl

[2026-11-01T19:00:57Z] user: why did you pick zstd

[2026-11-01T19:00:58Z] assistant: it compresses these files well
```

`source show` takes the id of a pointer, or of a memory that derives from one.
`--before` and `--after` set how many records to print before the time (6) and
after it (2). A record has its time, its speaker (`user`, `assistant`, or
`tool` for a result that a tool returned), and its text. Thinking, tool calls
and tool results appear marked, and long text is cut.

`source verify <id>` only says where the session is, or that it is not
available. It exits with status 1 if it is not.

## Roots

A pointer is resolved against the roots in the config file. A root is a folder
that holds transcripts, with the format of the transcripts in it:

```toml
[source]
roots = [
  { format = "claude-code", path = "~/.claude/projects" },
  { format = "claude-code", path = "~/archive/sessions/claude" },
]
```

There is no default, because akyuu does not guess where you keep them. `akyuu
config` shows the roots in effect.

A session is found by its file name below a root, at any depth:

- `<session>.jsonl` is the agent's own file.
- `<session>.jsonl.zst` is an archived copy, and `<session>.N.jsonl.zst` is
  the Nth version of a session that grew after it was archived. This is the
  layout that the archive tool [engi](https://github.com/lillycham/engi) writes,
  but any folder of such files works.

The agent's own files are preferred. Of two own copies, the larger one wins,
because an agent that copies a session leaves a shorter one behind. Of the
archived ones, the newest version wins. A symbolic link is not followed.

A file that is compressed with zstd is read with the `zstd` command, which
must be on the `PATH`. akyuu does not link a zstd library. Without `zstd`,
`source show` says that the archive cannot be read.

## A session that is not here

A pointer goes wherever the store goes, for example to another machine, and the
transcripts do not. The answer there is `not available`, with exit status 1. It
is not an error of the store, and `akyuu verify` and `akyuu check` do not
report it.

## What it prints, and who sees it

`source show` prints the text of a transcript on the terminal. That is text
that you can already read in the files. It is on the command line only. The
`[source] mcp` flag of the config is reserved for offering the same to agents
over MCP. It is off by default, and no MCP tool exists yet, because such a
tool would hand the text of one agent's sessions to another agent.

## Not built yet

- The MCP tool, behind `[source] mcp = true`.
- A check that the bytes of a span are the ones that the pointer saw (a hash).
  It needs the same rule for removing images and signatures that the archive
  tool uses, so that a live file and its archived copy give the same hash.
- The Codex and omp formats. They have the same shape: a name that finds the
  file, and a reader for the records.
- Capture: a hook that gives an agent the id of its session, so that it can
  make the pointer itself.
