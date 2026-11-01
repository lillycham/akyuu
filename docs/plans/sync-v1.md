# Sync v1: implementation status

The first phase implements the pure event model. It does not change the live
store, refs, GC, CLI, MCP tools, or network behaviour. The wire format is
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

`applyLocal` checks a resource version and its complete parent set. Future
writers must call it under the mutation lock. Remote merge permits unseen
concurrent events and does not require a local version token.

Resource versions include the store identity, resource key, and event heads.
A rollback therefore changes the version even when it restores old content.

An event has no memory payload bytes. The next phase must verify and save
those bytes before it publishes a checkpoint. Replica registration records
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

## Next phase

Implement durable checkpoints and an outbox with fault injection. All
accepted payloads must survive a crash before the first remote publication.
Uncommitted preparations must remain absent from search and resolution.

Do not add transport or migrate a live store before these guarantees pass.
