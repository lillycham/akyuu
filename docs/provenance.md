# Provenance: where a memory came from

Status: the pointer, `source add`, `source show`, `source verify` and the MCP
tool `source_show` are built, for Claude Code, Codex and omp (and pi)
transcripts. So is a check that the records did not change (`--hash`), and a
start hook for Claude Code that tells the agent the id of its session
(`source hook`).

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
| `format` | The transcript format: `claude-code`, `codex` or `omp`. |
| `session` | The session: the id that its file is named for. |
| `at` | The time the memory is about, to the second. |
| `from`, `to` | Optional. The ids of the first and the last record, if something knows them. With both, `source show` prints that range. |
| `hint` | Optional. A path below a root, for a person to read. It is never used to find the file, and it must not hold a home directory. |
| `sha256` | Optional. The hash of the records from `from` to `to`, after the strip rule (see "Did the records change?"). |

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
  { format = "codex", path = "~/.codex/sessions" },
  { format = "omp", path = "~/.omp/agent/sessions" },
  { format = "omp", path = "~/archive/sessions/omp" },
]
```

There is no default, because akyuu does not guess where you keep them. `akyuu
config` shows the roots in effect.

The formats:

| Format | Agent | A file is named | The `session` is | The records |
|---|---|---|---|---|
| `claude-code` | Claude Code | `<session>.jsonl` | the whole name | user and assistant turns, with tool calls and results |
| `codex` | Codex CLI | `rollout-<time>-<session>.jsonl` | the id at the end | messages, reasoning that has a summary, tool calls and outputs, messages between agents. A record's id is its ordinal. |
| `omp` | oh-my-pi, and pi | `<time>_<session>.jsonl` | the id at the end, or the name of a session that has one | user, assistant and tool-result messages. A record's id is the id of its entry. |

For `codex` and `omp` the id at the end must be the whole id (36 characters for
the ones that these agents write): the last group of an id does not find the
file. A Codex developer message is the instructions that the host adds, and it
is not shown.

A session is found by its file name below a root, at any depth. The name
without its ending is the _stem_, and the endings are:

- `.jsonl` is the agent's own file.
- `.jsonl.zst` is an archived copy, and `.N.jsonl.zst` is the Nth version of a
  session that grew after it was archived. This is the layout that the archive
  tool [engi](https://github.com/lillycham/engi) writes, but any folder of such
  files works.

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
that you can already read in the files.

The MCP tool `source_show` does the same for an agent. It takes `id`, `before`
and `after`, like the command, and returns the same text. It is off by default,
and it exists only if the config says so:

```toml
[source]
mcp = true
roots = [{ format = "claude-code", path = "~/.claude/projects" }]
```

It is off because it hands the text of one agent's sessions to another agent.
With the flag on, every tool set (`ordinary`, `maintenance` and `topic`) offers
it. A session that is not on the machine, or a missing root, is a tool error
that says so.

## Did the records change?

A pointer with `from` and `to` can also hold a hash of that span:

```
$ akyuu source add --session 0775d85c-… --from <id> --to <id> --hash
```

The hash is the SHA-256 of the raw lines of the file from the record `from` to
the record `to` (with every line between them, also those that are not
conversation), each ending in a line feed, after the strip rule: the data of
images and opaque signatures are replaced by a placeholder that holds their
length and their hash, and nothing else is changed. `source verify` reads the
span again and says:

- `hash intact`: the records are the ones that the pointer saw.
- `hash CHANGED`: they are not. An agent edited its file, or the file is another
  one.
- `hash not checked`, and why: the check could not be made.

Only an intact hash is a success; the exit status is 1 otherwise.

Why the strip rule: an archive made by [engi](https://github.com/lillycham/engi)
does not keep the data of images, so a hash of the raw bytes would not match
the archived copy. A hash of the stripped form is the same for the agent's own
file and for the archived copy. A changed image is still found, because the
placeholder holds the hash of the data that it replaced.

akyuu does not implement the rule a second time. It runs `engi strip`, so the
`engi` command must be on the `PATH` for `--hash` and for the check, and there
is one definition of the rule. The strip rule is written in `docs/strip-rule.md`
of that project. If a later version of the rule changes the placeholder, a hash
made under the old one shows as `CHANGED`.

## Letting an agent make its own pointers

An agent does not know the id of its session. A start hook can tell it:
`akyuu source hook` reads the JSON that Claude Code gives a hook on its standard
input, which has `session_id` in it, and prints

```
This is a claude-code session, id 0775d85c-….
When you write a memory that comes from this conversation, make a pointer to it …
  akyuu source add --format claude-code --session 0775d85c-…
It prints the id of the pointer. Give that id as derived_from when you write the memory. …
```

The Claude Code plugin in `contrib/claude-code` has this hook, and its `memory`
skill says when to use it. To add the hook yourself, see
[hooks.md](hooks.md). The hook prints nothing if the input has no usable
session id, and with `2>/dev/null || true` it also stays quiet on an akyuu that
is too old to have the command.

The agent then runs `akyuu source add --session <id>` when it writes a memory
that a later session may need to check, and passes the id that the command
prints as `derived_from`. The `note` tool takes `derived_from` in the `ordinary`
and `maintenance` tool sets. The `topic` tool set has no `derived_from`, so the
agent links the pointer with `akyuu add --derived-from` instead.

The hook is for Claude Code. The payloads of other agents differ, and the id in
the name of a Codex rollout can differ from the `session_id` in its metadata,
so a hook for Codex or omp needs its own check before it is added.

## Not built yet

- A hook for Codex and omp (see above).
