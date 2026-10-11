# Places, notes and hooks

Status: built, 2026-10-11. This note says how a session gets the memories of
the project it works in, how it writes down small things, and how to run the
start of a session from a hook.

## The manifest knows the place

The manifest of the tiers (the memory under `policy/tiers`) has two more kinds
of line, next to the tiers:

```
always: claude/profile claude/preferences claude/memory-policy
at ~/devel/akyuu: claude/projects/akyuu
log ~/devel/akyuu: claude/log/akyuu
log *: claude/log/general
```

- `at DIR: refs` adds the refs to the output of `context` for a session that
  works in DIR or below it. They come after the refs of the tier.
- `log DIR: ref` names the log that `note` writes to. The line with the most
  specific directory wins, and `*` matches every directory. A `log` line has
  exactly one ref.
- `~` is the home directory of the person.

The server and the command line take the directory from where they run. The
tools `context` and `note` also take `cwd`, for a client such as Claude Desktop
that does not start the server in a project.

## Notes

`akyuu note TEXT` and the tool `note` append an episode to the log of the
place, with no ref to choose. The kind is `note` unless `--kind` says
otherwise. The agent is `--agent`, then `$AKYUU_AGENT`, then `agent`. A place
with no `log` line gives an error that says what line to add.

## Amend

`akyuu amend REF --from TEXT --to TEXT` (also `--append TEXT`) and the tool
`amend` change one passage without writing the whole memory again. The text to
replace must occur once. The new memory keeps the kind, the agent (unless one
is given) and the `about`, `derived_from` and `refines` edges, and it replaces
the old one under the ref.

## Short ids

The tools accept the first 8 or more hex digits of an id, with or without
`sha256-`, when one memory starts with them. Lists show ids cut to 12 digits.
`get` and `context` show whole ids and whole bodies.

## A hook for the start of a session

Claude Code can run a command at the start of a session and add its output to
the context. In `~/.claude/settings.json`:

```json
{
  "hooks": {
    "SessionStart": [
      { "hooks": [ { "type": "command", "command": "akyuu context" } ] }
    ]
  }
}
```

`akyuu context` uses the current directory, so the refs of the project come
too. The hook saves a tool call, but the output is long: use it in place of the
call of `context`, not in addition to it.

A hook at the end of a session could call `akyuu note`, but a hook has no
knowledge of what happened. Do not write a note from a script that has only the
transcript: let the agent write notes during the work.

Akyuu does not change the settings file. Add the lines yourself if you want
them.
