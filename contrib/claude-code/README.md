# akyuu for Claude Code

A Claude Code plugin that connects each session to an akyuu store. It holds:

- **The MCP server.** `akyuu mcp`, with the default tool set.
- **The context at the start.** Three `SessionStart` hooks print
  `akyuu context --page 1` to `--page 3`, so the memories of the tier and of
  the project are in the session before the first prompt. The same hooks run
  again after `/compact` and `/clear`, so the memories come back after a
  compaction. See [docs/hooks.md](../../docs/hooks.md) for why there are pages.
- **A skill, `memory`.** How to read and write memories with the tools. A
  policy in the store wins over it.
- **A status line.** The counts of the store, and how many writes this session
  made, after the name of the plugin: `650 memories, 50 refs · 2 written here`.
- **`/akyuu-note TEXT`.** Writes a note in the log of the current directory
  without a turn of the model.

## Install

The plugin runs `akyuu` from `PATH`, with no `--root`. Set `root` in
`~/.config/akyuu/config.toml` (or `AKYUU_ROOT`) first, and check that
`akyuu status` works in a shell. See [docs/install.md](../../docs/install.md).

In Claude Code:

```
/plugin install akyuu --marketplace lillycham/akyuu
```

If you added the MCP server or the `SessionStart` hooks yourself before, remove
them. Otherwise each session loads the context two times and has two akyuu
servers.

The status line and `/akyuu-note` use the function hooks of Claude Code, an
early-access interface. On a version without it, the rest of the plugin still
works.

## Develop

```sh
claude plugin validate contrib/claude-code
claude plugin test contrib/claude-code
claude --plugin-dir contrib/claude-code
```
