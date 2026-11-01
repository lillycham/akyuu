# Sync v1: implementation status

The first two phases implement the pure event model and checkpoint storage.
Phase 3a adds opt-in local topic commands and a replicated MCP tool set.
These changes do not migrate the live store or add network transport. The wire format is
experimental until the persistence and migration phases are complete.

## Current modules

- `Akyuu.Sync.Types` defines distinct store, replica, nonce, and event IDs.
  It defines actions and their resource keys. Topic and log actions share one
  ref resource. Review pairs use a canonical order.
- `Akyuu.Sync.Event` validates events and writes canonical bytes. Event IDs
  hash those bytes. The parser refuses alternate encodings.
- `Akyuu.Sync.State` validates parent closure, store identity, replica
  registration, resource types, and acyclic ancestry. It merges valid event
  sets and interprets their causal heads.
- `Akyuu.Sync.Checkpoint` defines canonical, content-addressed manifests.
- `Akyuu.Sync.Repository` saves verified payloads, events, and manifests.
  Only an atomic `CURRENT` replacement publishes accepted state.
- `Akyuu.Sync.Topics` reads every topic head from one captured checkpoint.
  It creates topics, checks opaque versions, and resolves concurrent heads.

`applyLocal` checks a resource version and its complete parent set. Future
writers must call it under the mutation lock. Remote merge permits unseen
concurrent events and does not require a local version token.

Resource versions include the store identity, resource key, and event heads.
A rollback therefore changes the version even when it restores old content.

An event has no memory payload bytes. Repository transactions verify and save
those bytes before they publish a checkpoint. Replica registration records
identity, not authentication. Registered peers remain trusted.

## Experimental wire format

Each event starts with `akyuu-sync-event-v1` and a line feed. One JSON array
and one final line feed follow:

```text
[store,replica,nonce,[parentIds],[actionFields],time]
```

Store, replica, and nonce fields have 32 lower-case hexadecimal digits.
Event and memory IDs use the existing `sha256-` text form. Parent IDs appear
once each, in ascending order. Time uses UTC whole seconds, with years 0001
through 9999. Leap seconds and fractional seconds are refused.

JSON strings escape quotes and backslashes. They use the short escapes for
backspace, form feed, newline, carriage return, and tab. Other C0 controls
use lower-case `\u00xx` escapes. All other characters use literal UTF-8.
There is no optional whitespace. JSON library encoder choices do not define
the wire format.

Actions use these arrays:

| Action | Fields |
| --- | --- |
| Topic replacement | `["set-topic",name,memory]` |
| Log append | `["append-log",name,memory]` |
| Topic resolution | `["resolve-topic",name,memory]` |
| Log type resolution | `["resolve-log",name,memory]` |
| Pin | `["set-pin",memory]` |
| Unpin | `["clear-pin",memory]` |
| Review | `["set-review",lowerId,higherId,author,reason]` |
| Unreview | `["clear-review",lowerId,higherId]` |
| Replica registration | `["register-replica",replica,label]` |

Event bytes have a 64 KiB limit. Parent sets have a 256-entry limit.
An excessive frontier causes an explicit write error; it never loses heads.
Batch resolution or different limits need review before deployment.

An ordinary topic event has zero or one topic parent. It cannot consume a
fork or change a log into a topic. A resolution requires at least one parent
and can consume heads of either ref type. A log append can consume several
log heads. The memory DAG itself remains unchanged in this phase.

## State semantics

A head is an event that no later event for its resource consumes. The merge
uses verified union and retains every event. It never uses timestamps to
select a winner.

- Topic heads remain separate, even when their memory IDs match.
- Concurrent topic and log declarations produce a type conflict.
- Log heads form a frontier. Memory traversal from that frontier is deferred.
- A surviving pin Set retains the pin. A Clear consumes only observed heads.
- Concurrent review Sets retain their reasons. A Clear consumes observed heads.
- Replica registrations accumulate, even after later registry events.

The state constructor accepts a complete event closure. It does not accept
partial histories. A transport importer must assemble dependencies before
it constructs state.

## Validation

`SyncTests` covers canonical bytes, malformed input, causal validation,
rollback, conflict resolution, late branches, type conflicts, log frontiers,
pins, reviews, and optimistic local writes. Generated histories test merge
associativity, commutativity, idempotence, and arrival order independence.

Checkpoint tests cover canonical manifests and export obligations. Repository
tests kill child processes at write, file flush, rename, and directory flush
boundaries. Recovery validates the old or complete new checkpoint. These
tests simulate process death, not a physical loss of power.

## Experimental repository

This API uses a separate, empty directory. It refuses a legacy store or an
unrelated nonempty directory. It does not initialise a production format 2
store or connect existing readers and writers to checkpoints.

```text
IDENTITY             protocol marker and store identity
CURRENT              one checkpoint ID and a line feed
store.lock           shared mutation lock
objects/<id>         immutable canonical memory bytes
events/<id>          immutable canonical event bytes
checkpoints/<id>     immutable canonical manifest
```

Each manifest names all accepted events and payloads. It also names the
pending events and payloads. These pending sets form the durable outbox.
The object pool holds its bytes without a second copy. No acknowledgement
or collection API exists yet; all accepted data remains available locally.

Local transactions check the current resource token under the mutation lock.
Imports merge against the latest checkpoint under that lock. They retain
all new data as pending until transport can verify publication receipts.

All event payloads and retaining memory dependencies must be present before
publication. Supersession edges may name collected history. Payloads have a
16 MiB limit. Manifests have a 64 MiB limit. Reads enforce their limits before
they allocate a complete file.

Transactions write and flush immutable files first. They publish `CURRENT`
last. Repository initialisation also flushes ancestor directories. Recovery
ignores temporary files and preparations outside the accepted manifest.

An I/O failure after the pointer rename reports `PublicationUncertain` with
the checkpoint ID. The caller must read current state before a retry. This
prevents a visible publication from being reported as a definite rejection.

Captured snapshots retain their accepted ID sets. Explicit memory reads do
not inspect directory listings. Existing live search still uses the legacy
store; checkpoint-based search must follow in the integration phase.

The prototype validates full event and payload inventories on each load and
commit. This favours a simple correctness boundary. Incremental validation,
archive fallback, checkpoint retention and performance limits remain open.

The filesystem helper uses `fsync`. It does not issue macOS `F_FULLFSYNC`.
The durability claim does not cover drive caches that survive an `fsync`.

## Next phase

Complete configured context, search and web integration. Then implement log
DAG traversal and GC integration. Topic operations already use captured
checkpoints through the interfaces below.

Search must use causal topic state. A selected head does not rewrite the
memory supersession graph, so graph heads alone cannot identify topic conflicts.

Keep transport and live-store migration behind their later acceptance checks.

## Experimental topic interfaces

Use a separate directory. This path does not migrate a legacy store:

```sh
akyuu --root ./replica-demo replica init --label laptop
akyuu --root ./replica-demo replica create me/topic \
  --kind fact --agent test --body 'A first version' --json
akyuu --root ./replica-demo replica read me/topic --json
akyuu --root ./replica-demo replica replace me/topic \
  --expected VERSION --kind fact --agent test --body 'A revised version' --json
akyuu --root ./replica-demo replica conflicts --json
akyuu --root ./replica-demo replica context --ref me/topic --json
```

Copy VERSION from the read response. A memory ID is not a resource version.
Replica commands require complete IDs for memory links and selection.

`replica resolve NAME --expected VERSION --select ID` selects one current
head's memory. It preserves its bytes and creates a new causal event. New
content instead uses `--kind`, `--agent`, and a body source. It supersedes
every current head memory. Ordinary replacement refuses conflicts.

Read responses include the checkpoint, opaque version, status and every head.
Each head includes its event ID, memory ID, replica, timestamps and memory
metadata. No conflict response has an arbitrary current value.

`replica context` reads explicit refs from one checkpoint. It retains missing
and conflict markers. It does not expand a policy or tier manifest yet.

With `--json`, failed writes return structured errors on stdout and exit 1.
Stale-version and conflict errors include the current heads. Successful reads
of conflicts exit 0. Without `--json`, failures use stderr.

`mcp --tool-set replicated` exposes `topic_read`, `topic_create`,
`topic_replace`, `topic_resolve`, `topic_conflicts`, and `topic_context`.
Results carry the same JSON in text and MCP `structuredContent`, as the
[MCP tool specification](https://modelcontextprotocol.io/specification/2025-11-25/server/tools#structured-content)
recommends for compatibility. The server requires a
previously initialised local replica. Its explicit policy/tier flags are
refused until configured context is available. The default tool set stays
ordinary. Replicated writers use the configured or negotiated client author.

`REPLICA` stores local identity before its registration event. Repeated init
reuses this identity and completes an interrupted registration. This file is
local configuration; it must not enter the replication archive.

Legacy environment entry points refuse checkpoint markers before they open
legacy object, ref or cache files. Old installed binaries do not have this
guard; coordinated upgrades still precede any real migration.

`TopicsTests` exercises divergent writes by two registered replicas, type
conflicts, explicit resolution and captured context. `ReplicaInterfaceTests`
checks CLI output and JSON-RPC responses. `test/smoke-replica.cjs` tests the
actual CLI and stdio MCP server against a temporary repository. The Nix
`replica` check runs this smoke test without a remote or model.
