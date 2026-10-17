# Changelog

## Unreleased

### Added

- A new edge kind, `follows`, links an episode to the one before it in its
  log. `append` and `note` write it. Before, that link was the one
  `derived_from` edge of an episode, so an episode could not cite evidence.
  Now `append` and `note` take `derived_from` for evidence. akyuu still reads
  older logs, and their next episode follows them. akyuu 0.2.0.0 and older
  refuse a memory with this header.
- About-ref links: a memory can be about a ref, not one exact memory, with the
  header `about-ref: NAME`. The link names whatever memory the ref names when
  it is read, so it does not go stale when the ref moves. Use `about_refs` in
  the MCP tools `add`, `supersede`, `append` and `note`, and `--about-ref` on
  the command line. A ref must exist to be linked. `neighbours`, `search` and
  the web view resolve the links. akyuu 0.2.0.0 and older refuse a memory with
  this header.
- `check` reports `missing-ref`: a link to a ref that does not exist.
- `get` tells the id of the memory it read: the MCP tool `get` starts its
  result with a line `id: ID`, and `akyuu get --with-id` prints the same line.
  It is the value for `expected` in `supersede` and `amend`, so an agent needs
  no `ref_get` before an update. Without `--with-id`, `akyuu get` still prints
  the stored file exactly.
- A config file, `~/.config/akyuu/config.toml` (or `$AKYUU_CONFIG`), for every
  setting: the root, the refs of the policy and the manifest, the agent, and
  search by meaning. A variable of the environment wins over the file, and an
  option wins over both. An unknown key is reported with its line.
- Embedding profiles: `[embed.profiles.NAME]` keeps the command, the key, the
  prefixes, the minimum similarity and the arguments of one model together.
  `embed.profile` picks one, and `--embed-profile NAME` (or
  `$AKYUU_EMBED_PROFILE`) picks another for one command.
- `akyuu config` shows each setting in effect and where it came from. It needs
  no store.
- `embed` and `status` warn when the vectors of a key were made by another
  command, other arguments or other prefixes (a fingerprint in
  `embeddings.sqlite`).
- The home-manager module writes `config.toml`, has the options
  `embed.profiles`, `embed.profile` and `settings`, and no longer sets session
  variables or writes `embed.env`.
- Man pages: `akyuu(1)` for the commands, `akyuu-backup` and `akyuu-version`,
  and `akyuu(5)` for the files of a store. The package installs them, and
  completions for bash, zsh and fish. A check of the flake fails when a
  command or a flag of `akyuu --help` is missing from `akyuu(1)`.

### Fixes

- The MCP server refuses an argument that a tool does not have, with the
  arguments it has and a "did you mean" hint. Before, it ignored the argument,
  so a misspelt `expected` made a compare-and-set into a plain write.
- When the root is missing, the error says to run `akyuu init`.

### Changes

- `check` knows which memories are episodes (a memory on a log chain), and
  does not report their links to old versions as stale: an episode records a
  past state, and an episode is never superseded.
- `check` no longer reports a `derived-from` edge to an old version as a stale
  link: that edge is evidence of one exact text. A stale `about` link names the
  ref that holds the current memory, so the fix is an about-ref link.
- akyuu puts the prefix of the model before the text. The commands
  `akyuu-embed-llama` and `akyuu-embed-openai` no longer add it, so a command
  of your own that adds the prefix itself must stop, or the text gets it twice.
- `status` names the profile and the key, and the config file.

- The web view has a new look, "Akyuu Manuscript": a page of a chronicle
  in indigo ink. It has a paper theme (light) and an indigo theme (dark), one
  accent for what is current, and status colours for problems (vermilion),
  good results (pine) and search hits (gold). Text is in Shippori Mincho B1,
  and labels, ids and dates are in Spline Sans Mono. Every tab changes.
- The web view contains its fonts (Latin subsets, as data: URIs). It still
  loads nothing from the network. The Content-Security-Policy now allows
  `font-src data:`. A page and an `akyuu viz` export are about 134 KB bigger.
  The fonts are under the SIL Open Font License 1.1 (see "Licence" in the
  README, and `web/fonts/`).
- Graph nodes show their kind as a strip at the left edge. The colours follow
  the theme, also when it changes after the page loads. Labels are cut to fit
  by their measured width.
- The web view works in small windows and on phones (below 720 px), and in
  forced colours (Windows high contrast).

## 0.2.0.0 (2026-10-13)

The store format does not change (`docs/format.md`). The table of vectors for
search by meaning changes, and a hook for Claude Code needs a new command: see
"Upgrading".

### Highlights

- A Wiki tab, the first tab of the web view. Each ref is a page, and the body
  of its memory is rendered as Markdown (built as DOM nodes, never as HTML).
  Ref names and ids in the text are links. A page shows its links, backlinks,
  history and, for a log, its episodes. The first page is the first ref of the
  tier `always` of the manifest (`docs/wiki-view.md`, `GET /api/pages`).
- `context --page N` (and `--budget`) splits the context into pages that fit the
  10,000-character limit of a Claude Code hook. The MCP tool `context` takes
  `budget` and `page` too (`docs/hooks.md`).
- `akyuu init` starts a store: the root, a short policy for agents
  (`policy/memory`) and a manifest (`policy/tiers`). Existing refs are kept.
- `akyuu status` shows the counts, the manifest, the policy, search by meaning
  and versioning in a few lines.

### Changes

- Search by meaning embeds a long memory in chunks (at most 8) and ranks it by
  its best chunk. `akyuu embed --prune` removes the vectors of other models and
  of deleted memories, and the home-manager module runs it daily. The MCP
  search takes `mode` (`fused`, `text` or `meaning`), and the web view searches
  by meaning too.
- `context` on a store without a manifest gives a hint, not an error.
- `add --ref` (and `ref` for the MCP tool `add`) makes a new ref in the same
  call.
- `log --since 7d` (and `since` for the MCP tool `log`) shows the episodes of
  the last length of time.
- The MCP server takes the name of the client (`clientInfo.name`, for example
  `claude-code`) as the default agent of `note`, when `AKYUU_AGENT` is not set.
- `akyuu --version`, and the MCP server reports the version of the package.
- `nix flake check` checks the formatting (ormolu). CI runs on Linux and macOS.

### Fixes

- A file that is not a valid memory (for example one edited by hand) no longer
  stops every search: the cache skips it, and `verify` reports it.
- The backup copies the refs before the objects, so a ref in a snapshot always
  has its object.
- The idle stop of `akyuu-embed-llama` works (it used a BSD form of `stat`), and
  two callers can no longer start two servers.
- A timeout of the embedding command stops its children too. An error of the
  vector table falls back to a text search. The settings file accepts
  `export`, quotes and CRLF.
- An append retries up to 20 times when other agents append at the same time.

### Upgrading

- Run `akyuu embed` once if you use search by meaning: the vectors are now in a
  table of chunks. The old table stays until `akyuu embed --prune`, so an older
  akyuu on the same store keeps working.
- If a Claude Code SessionStart hook runs `akyuu context`, use three hooks with
  `akyuu context --page 1`, `--page 2` and `--page 3` (`docs/hooks.md`).

## 0.1.0.0 (2026-10-13)

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
