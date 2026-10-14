# Roadmap

What is open, in the order that matters. This is the only list of open work.
The history of the decisions is in [docs/development-log.md](docs/development-log.md).

## Next

- **A test of the systemd units on a real machine.** The module is checked by
  evaluation, and the package builds on Linux, but nobody has run the timers.
- **Per-log retention.** A long log is found by `check` (`long-log`). Whether a
  log should summarise itself (an agent runs a procedure) or keep only the
  newest episodes (GC cuts the chain) is not decided. Today it is by hand.

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

## Not planned

- Access control or encryption inside akyuu. It is for one user; protect the
  directory and the remote of the store.
- Running a model. Akyuu only calls a command that you set.
