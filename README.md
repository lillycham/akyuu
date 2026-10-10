# Akyuu

Akyuu is a persistent store for AI agents modelled on Nix. It retains a single
store of truth as plaintext, and builds a DAG on top of that. The DAG is
queryable and allows chains of memories and concepts to be followed.

## Usage

Akyuu can be interfaced with through a command-line tool `akyuu` or the MCP (Model Context Protocol) server.

## Design

Akyuu consists of 4 main "parts":

- The store: A content-addressable store. Immutable plaintext on disk.
- The graph: An acyclic graph derived from the store, representing relations between memories.
- Refs: The mutable layer. Akin to Nix profiles or Git refs. Old memories are "superseded" by new ones.
- GC: Garbage collector prunes superseded memories.

In pseudo-Haskell:

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

## Data Format

Data addressed by Akyuu must follow this format:

```text
kind: <kind>
created: <timestamp>
agent: <agent>
supersedes: sha256-<...>
about: sha256-<...>

<body>
```
