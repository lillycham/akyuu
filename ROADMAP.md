# Roadmap

What is open, in the order that matters. The development log with the history
of the decisions is in [TODO.md](TODO.md).

## Next

- **macOS in CI.** Linux runs on every push and pull request. macOS can join
  when the repository is public (the minutes are free there).
- **A test of the systemd units on a real machine.** The module is checked by
  evaluation, and the package builds on Linux, but nobody has run the timers.
- **Per-log retention.** A long log is found by `check` (`long-log`). Whether a
  log should summarise itself (an agent runs a procedure) or keep only the
  newest episodes (GC cuts the chain) is not decided. Today it is by hand.

## Later

- **Automatic supersession.** `check` finds duplicates, forks and stale links,
  and an agent decides. A pass that proposes `supersede` operations by itself,
  with a person approving, is not built.
- **Retargeting stale links.** Manual by choice for now.
- **Search.**
  - Chunking of long memories for the embedding. Only the first 4000
    characters are embedded now.
  - Removing the vectors of a model that is no longer used (`embed --prune`).
  - Try EmbeddingGemma 2 when nixpkgs has llama.cpp b11452 or later
    (see `docs/embeddings.md`).
- **A wiki-style view.** A page for reading memories, next to the graph.
- **A shared helper** for `Store.orNotFound` and `Refs.orNoSuchRef` (an API
  decision, see TODO.md).

## Not planned

- Access control or encryption inside akyuu. It is for one user; protect the
  directory and the remote of the store.
- Running a model. Akyuu only calls a command that you set.
