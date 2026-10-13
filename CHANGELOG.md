# Changelog

## 0.1.0.0

The first release. It is for people who use Nix, a Mac or Linux, and Claude
Code, Claude Desktop or another MCP client. Before 1.0, the commands and the
tools of the MCP server can change. The store format is described in
`docs/format.md`.

### The store

- Content-addressed memories (SHA-256) in plain text, a graph of edges
  (`supersedes`, `about`, `derived-from`, `refines`), refs with generations,
  pins, and a garbage collector (grace period, trash, tombstones).
- A disposable SQLite cache with a full-text index (porter stems).
- `akyuu-backup` and `akyuu-version` (a git repository of the memories, with
  an optional push to a remote).

### Using it

- A command line, an MCP server (stdio) and a read-only web view with a graph.
- Search forgives typing mistakes, ranks held and new memories higher, and
  can search by meaning with an embedding command you choose
  (`docs/embeddings.md`).
- `context` (tiers and places in a manifest memory), `note`, `amend` and
  short ids for agents (`docs/hooks.md`).
- Episodic logs (`append`, `log`; `docs/episodes.md`).
- `check` finds stale links, forks, duplicates, memories that nothing
  keeps, hubs and long logs. `compare` and `review` support the judgement of
  an agent (`docs/check.md`, `docs/judgement.md`).
- A home-manager module for the binary, the daily jobs (launchd agents on
  macOS, systemd user timers on Linux), the embedding model and the settings.

### Known limits

- One user, one machine. There is no access control: a client of the MCP
  server can change every ref. The web view is read-only and loopback only.
- The embedding command is a shell command that you set. Treat the file
  `~/.config/akyuu/embed.env` like a script.
- A memory that you forget stays in the git history, if you use
  `akyuu-version`.
- The Linux timers are checked by evaluation only (`nix flake check`): the
  author runs macOS. Reports from Linux are welcome.
