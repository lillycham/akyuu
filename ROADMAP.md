# Roadmap

What is open, in the order that matters. This is the only list of open work.
The history of the decisions is in [docs/development-log.md](docs/development-log.md).

## Next

- **Safer MCP writes and tool sets.** Work in progress: required version
  checks, retained ordinary creation, and a separate maintenance interface.
- **A test of the systemd units on a real machine.** The module is checked by
  evaluation, and the package builds on Linux, but nobody has run the timers.
## Later

- **Install without Nix.** The goal is that anyone can install akyuu. Nothing
  in the code needs Nix; the work is packaging. In order:
  - A `cabal.project` with a fixed `index-state`, and a CI job that builds and
    tests with GHCup and no Nix.
  - Release binaries from CI for macOS (arm64, x86_64) and Linux (static with
    musl, or glibc). Then maybe Hackage and a Homebrew tap.
  - Move the helper scripts from `nix/` to `scripts/` and list their tools
    (rsync, git, curl, jq, llama.cpp). Add example launchd and systemd units in
    `contrib/` for the daily jobs.
  - A path without Nix in `docs/install.md` and `docs/agent-install.md`.
  - Native Windows needs replacements for the uses of `unix` (fsync, process
    group signals, touchFile). Not planned until someone asks; WSL works.
- **Automatic supersession.** `check` finds duplicates, forks and stale links,
  and an agent decides. A pass that proposes `supersede` operations by itself,
  with a person approving, is not built.
- **Retargeting stale links.** Manual by choice for now.
- **Search.**
  - Try EmbeddingGemma 2 when nixpkgs has llama.cpp b11452 or later
    (see `docs/embeddings.md`).
- **Shorter MCP tool descriptions.** The answer of `tools/list` is about 16 KB,
  and a client that loads every tool pays for it in each session.
- **The wiki view:** Markdown tables and images.
- **A shared helper** for `Store.orNotFound` and `Refs.orNoSuchRef` (an API
  decision, see docs/development-log.md).
- **Records for the tool calls.** Some constructors of `ToolCall` in `Akyuu.MCP`
  have many fields by position (`CallContext` has five, `CallReview` has two
  `Text` fields side by side). Records or small argument types would let the
  compiler catch fields in the wrong order.
- **The script of the web view in files.** `web/index.html` holds about 2000
  lines of JavaScript. Keep it in `web/*.js` and join the files at build time,
  as `Page.hs` does for `web/fonts.css`, so the page stays one file.

## Not planned

- Access control or encryption inside akyuu. It is for one user; protect the
  directory and the remote of the store.
- Running a model. Akyuu only calls a command that you set.
