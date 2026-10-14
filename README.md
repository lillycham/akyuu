# Akyuu

[![ci](https://github.com/lillycham/akyuu/actions/workflows/ci.yml/badge.svg)](https://github.com/lillycham/akyuu/actions/workflows/ci.yml)
[![license: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

Akyuu is a persistent memory store for AI agents, modelled on Nix. A memory is
an immutable plain-text file, named by the hash of its text. A small mutable
layer of named refs says which memory is current, and a graph of links
between memories is derived from the files. An agent reads and writes it
through a command line or an MCP server, so Claude Code, Claude Desktop and
other MCP clients can share one memory.

**Status: 0.2.0.0, pre-1.0.** It is in daily use by its author. Commands and
MCP tools can still change. The store format is in [docs/format.md](docs/format.md),
the changes are in [CHANGELOG.md](CHANGELOG.md), and open work is in
[ROADMAP.md](ROADMAP.md). It is written in Haskell and built with Nix.

What it is for:

- **Facts that change.** A ref such as `me/projects/garden` names the
  current text. To change it, an agent adds a new memory that supersedes the
  old one. Nothing is edited, so the history is kept until GC collects it.
- **Things that happened.** A log (`append`, `note`) keeps episodes in order.
- **Finding things.** Text search that forgives typing mistakes, and optional
  search by meaning with an embedding model that you choose.
- **Keeping it tidy.** `check` finds duplicates, forks and stale links, and an
  agent decides what to do.

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/images/webui-wiki-dark.png">
  <img alt="The web view of akyuu: the wiki page of a ref, with its text, links and history" src="docs/images/webui-wiki-light.png">
</picture>

The read-only web view (`akyuu serve`) shows each ref as a wiki page, and the
store as a graph, with search, GC, check and health tabs.

## Quick start

To let an agent do the install, point it at
[docs/agent-install.md](docs/agent-install.md) from a release tag. It asks you
before it changes your files. To do it yourself:

```sh
nix run github:lillycham/akyuu -- --help      # or: nix profile install github:lillycham/akyuu

export AKYUU_ROOT=~/.local/share/akyuu
akyuu init                                    # makes the root, a policy for agents and a manifest
akyuu add --kind fact --agent me --body "Nix for every tool."
akyuu search nix
akyuu serve                                   # a read-only web view on http://127.0.0.1:7420
```

Give an agent the store. For Claude Code:

```sh
claude mcp add --scope user akyuu -- akyuu --root ~/.local/share/akyuu mcp
```

For Claude Desktop, add this to `claude_desktop_config.json`:

```json
{ "mcpServers": { "akyuu": { "command": "akyuu", "args": ["--root", "/Users/you/.local/share/akyuu", "mcp"] } } }
```

Use the full path of `akyuu` as the command if the app does not have it in its
`PATH`. The MCP server tells the agent to read the policy of the store first:
`akyuu init` writes a short one under `policy/memory`. Change it to fit you, or
name another ref with `--policy-ref` (or `AKYUU_POLICY_REF`).

## Trust and safety

- **One user.** There is no access control. A client of the MCP server can
  add, supersede and point refs, so give it only to agents that you trust with
  the memories.
- **Local.** The MCP server speaks on stdio. The web view is read-only and
  listens on `127.0.0.1` only, and it checks the `Host` header.
- **Commands from settings.** `AKYUU_EMBED_COMMAND` is run with `sh -c`. It
  comes from the environment or from `~/.config/akyuu/embed.env`: protect that
  file like a script.
- **Forgetting.** To forget a memory, supersede it with a text that leaves it
  out. GC then deletes the old text after the grace period and the ref
  generations. If you keep the store in git (`akyuu-version`), the old text
  stays in the history until you rewrite it.
- **Secrets.** Do not store passwords or keys in memories.

## Documents

| Topic | Document |
|---|---|
| The format on disk, and what is stable | [docs/format.md](docs/format.md) |
| Install, the home-manager module, backup, versioning | [docs/install.md](docs/install.md) |
| An install guide for an agent to follow | [docs/agent-install.md](docs/agent-install.md) |
| Search by meaning, models, evaluation | [docs/embeddings.md](docs/embeddings.md) |
| Logs and forgetting | [docs/episodes.md](docs/episodes.md) |
| Finding duplicates, forks, stale links | [docs/check.md](docs/check.md), [docs/judgement.md](docs/judgement.md) |
| Tiers, places, notes, hooks for agents | [docs/hooks.md](docs/hooks.md) |
| The web view | [docs/wiki-view.md](docs/wiki-view.md), [docs/webui-tabs.md](docs/webui-tabs.md) |
| Security, contributing | [SECURITY.md](SECURITY.md), [CONTRIBUTING.md](CONTRIBUTING.md) |

## Usage

```sh
export AKYUU_ROOT=~/.local/share/akyuu   # or pass --root DIR

akyuu add --kind fact --agent me --body "Nix for every tool."   # prints the id
akyuu add --ref me/tools --kind fact --agent me --body "..."    # the same, under a new ref
akyuu search nix                    # text search, with the memories near each hit
akyuu get 08d4                      # the start of an id is enough
akyuu supersede me/notes --kind fact --agent me --body "..."
akyuu ref list                      # the name and the id of each ref
akyuu gc --dry-run --grace 30m      # also --keep-generations N, --trash-ttl 7d
akyuu pin 08d4                      # GC keeps a pinned memory
akyuu pins                          # the id of each pin (akyuu unpin ID removes one)
akyuu init                          # start a store: a policy for agents and a manifest of tiers
akyuu context                       # the memories every session needs, in one call (the tier "always")
akyuu context --page 1              # the same, in pages that fit a Claude Code hook (docs/hooks.md)
akyuu amend me/notes --from tea --to coffee   # change one passage; the ref moves to a new memory (also --append TEXT)
akyuu embed                         # vectors for search by meaning (docs/embeddings.md)
akyuu search-eval                   # run a set of searches in each mode
akyuu note "a small thing"          # an episode in the log that the manifest names for this directory
akyuu compare 08d4 1c9b             # what each of two memories says that the other lacks
akyuu review 08d4 1c9b --agent me   # both are true and different: check leaves the pair out
akyuu status                        # the setup in a few lines: counts, manifest, policy, vectors, git
akyuu check                         # stale links, forks, duplicates, memories nothing keeps
akyuu append me/episodes --kind episode --agent me --body "..."   # a log: each episode points at the one before
akyuu log me/episodes               # the episodes, newest first (see docs/episodes.md)
akyuu log me/episodes --since 7d    # only the last week
akyuu serve                         # the read-only web UI on 127.0.0.1:7420
akyuu seed --demo --root /tmp/demo  # a demo store, for the web UI
```

## Install

Install with `nix profile install github:lillycham/akyuu`, or with the home-manager
module of the flake, which can also run GC, backups and versioning every day.
See [docs/install.md](docs/install.md) for the module, the daily jobs,
`akyuu-backup` and `akyuu-version`.

## Checks

`nix flake check` runs the unit tests and tests of `akyuu-backup` and `akyuu-version` in the Nix
sandbox. For day to day work, `nix develop -c cabal test`.

## Design

Akyuu has four parts, in pseudo-Haskell:

```hs
Store  :: Id -> Memory          -- immutable, content-addressed, plaintext on disk
Refs   :: Name -> Id            -- the only mutable layer (like git refs / Nix profiles)
Graph  = foldMap edges Store   -- derived, so the cache is disposable
GC     = sweep (Store \ reachable Roots)
```

## Architecture

Each layer uses only the layers below it. The pure core (green) does no I/O. Refs
(amber) is the only layer that changes a value in place. The web UI only reads.

```mermaid
flowchart TD
  CLI["CLI"]
  MCP["MCP server"]
  Web["Web UI<br/>read-only, on 127.0.0.1"]
  Ops["Ops<br/>supersede, AkyuuError"]
  Query["Query<br/>search, then withinHops"]
  GC["GC<br/>plan (pure), sweep (IO)"]
  Cache["Cache<br/>SQLite and FTS5, disposable"]
  Store["Store<br/>objects by hash"]
  Refs["Refs<br/>name to Id, flock, generations"]
  Fs["Fs<br/>atomicWrite with fsync"]

  subgraph core ["Pure core, no I/O"]
    Memory["Memory<br/>parse, render"]
    Graph["Graph<br/>a Monoid"]
    Id["Id<br/>SHA-256"]
  end

  CLI --> Ops
  MCP --> Ops
  Web --> Ops
  Ops --> Query
  Ops --> GC
  Query --> Cache
  GC -->|roots| Refs
  GC -->|trash| Store
  Cache -->|sync| Store
  Cache -->|loadGraph| Graph
  Store --> Fs
  Refs --> Fs
  Store -->|parse, render| Memory
  Store -->|hash| Id
  Memory --> Graph
  Graph --> Id

  classDef pure fill:#e4f1e8,stroke:#3b7a56,color:#1a2230
  classDef io fill:#e2ebf8,stroke:#3c5f99,color:#1a2230
  classDef mut fill:#fbe9d0,stroke:#b3631a,color:#1a2230
  class Memory,Graph,Id pure
  class Store,Fs,CLI,MCP,Web,Ops,Query,GC,Cache io
  class Refs mut
  style core fill:#f3faf5,stroke:#3b7a56,stroke-dasharray:3 4,color:#1a2230
```

On disk, `store/` and `refs/` are the sources of truth. `cache.sqlite` is derived from
them, so it can be deleted at any time. GC moves swept objects to `trash/` and does
not delete them at once.

## Licence

Akyuu is under the MIT licence ([LICENSE](LICENSE)).

The web view contains two fonts under the SIL Open Font License 1.1: Shippori
Mincho B1 and Spline Sans Mono. Their licences are in [web/fonts/](web/fonts/).
