# Sync v1: implementation status

The first two phases implement the pure event model and checkpoint storage.
Phase 3a adds opt-in local topic commands and a replicated MCP tool set.
Phase 3b adds configured context, current-head search and a read-only browser.
Phase 4 adds DAG log reads, appends and summary levels through CLI and MCP.
Phase 5 adds a durable local archive, checkpoint eviction and replicated pins
and reviews. Publication acknowledgement requires verified transport receipts.
Phases 6 and 7 add manual Git exchange, fresh join and a journaled legacy
snapshot copy. They do not perform live cutover or add background sync.
These changes do not migrate the live store. The wire format remains
experimental until consumer integration and performance acceptance are complete.

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
- `Akyuu.Sync.Context` expands configured tiers and reports unresolved controls.
  It checks control versions before it publishes a topic resolution.
- `Akyuu.Sync.Search` searches current topic heads with an in-memory FTS index.
- `Akyuu.Sync.Web` serves a read-only browser or exports a static snapshot.
- `Akyuu.Sync.Logs` traverses all predecessors from every log head. It reads
  summary levels and selects deterministic disjoint coverage.
- `Akyuu.Sync.Retention` derives roots from every causal branch, pending
  exports, live pins and retaining memory edges.
- `Akyuu.Sync.Resources` exposes pin state and every surviving review reason.
- `Akyuu.Sync.Process` bounds Git time, output and private repository size.
- `Akyuu.Sync.Git` validates protocol trees and prepares immutable archive unions.
- `Akyuu.Sync.Run` coordinates previews, manual exchange, receipts and fresh joins.
- `Akyuu.Sync.Migration` validates explicitly classified legacy snapshots and
  copies one deterministic baseline to a separate destination.

`applyLocal` checks a resource version and its complete parent set. Local
writers call it under the mutation lock. Remote merge permits unseen
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
- Log heads form a frontier. Traversal follows every predecessor and visits
  shared ancestors once. Imported appends must retain each observed predecessor.
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

`ReplicaLogTests` covers shared ancestors, clock skew, frontier limits,
captured reads, corrupt history, concurrent summary heads, overlap, higher
levels and stale source dependencies. Generated DAGs test order independence
and precedence for every edge. Imports refuse missing log predecessor links.
On 2026-11-03, all 1,175 Haskell tests passed. The native Nix format, man
and packaged CLI/MCP/HTTP replica checks also passed.

`ArchiveTests` adds archive verification, publication acknowledgement,
pending intermediate payloads, branch generations, pin/review partitions,
old snapshot reads, eviction without import resurrection and restoration
of new live references. Barrier tests cover readers and the shared writer
lock during collection. Process-death tests cover archive dependencies,
acknowledgement pointers and eviction through directory flush.
After phase 5, all 1,222 Haskell tests passed on 2026-11-03. Native format,
man and packaged CLI/MCP/HTTP checks also passed. At that stage, the archive
tests simulated the transport acknowledgement boundary.

`TransportTests` exercises a local bare remote, three replicas, offline
conflicts, late branches, preview isolation, push races, lost-response
recovery, later local obligations and invalid archive refusal. Join and
migration tests inject failures at durable stages and verify idempotent
resumption. Process tests use fresh executable workers, not a fork-only
Haskell child, to avoid inherited runtime locks. They cover output/storage
limits, deadlines, cancellation, surviving descendants and descriptor leaks.
All 1,252 Haskell tests passed in the development shell and native Nix
sandbox on 2026-11-03. Packaged CLI/MCP/HTTP and
sync/join/GC/pin/conflict/migration smoke, format, man and legacy version
compatibility checks passed. At that stage, SSH/HTTPS authentication, real network faults,
and coordinated live cutover remain unverified.

On 2026-11-03, all 1,252 tests also passed in the native aarch64-linux Nix
sandbox on Apple Silicon with Asahi/NixOS. Packaged replica and sync smoke,
format, man and legacy version checks passed. The fake Git scripts use the
shell from PATH because Linux build sandboxes do not provide `/usr/bin/env`.

After log/context/browser integration, all 1,261 tests passed in the Mac
development shell and native aarch64-darwin and aarch64-linux Nix sandboxes
on 2026-11-03. Packaged CLI/MCP/HTTP, DOM and sync smoke checks passed on
both platforms, as did format, man and legacy version checks. New regressions
cover shared history budgets, summary coverage across pages, stale
continuation, invalid summary-level types, incomplete history and exact
evidence reads. The browser access host was unavailable, so rendered UI
interaction remains unverified.

The later two-machine SSH experiment passed with disposable Mac and Linux
replicas. Offline conflicts, DAG logs, summary evidence, unavailable-remote
recovery and archived pin restoration converged. Performance acceptance did
not pass: the M4 reproduced a busy independent writer at 5,000 entries, and
Linux archive measurements exceeded their deadline. See the
[experiment report](../../bench/results/2026-11-03.md) and
[reproduction instructions](../../bench/README.md). HTTPS authentication,
packet-loss recovery and coordinated live cutover remain open.

On 2026-11-07, archive preparation moved outside the mutation lock. GC checks
its expected checkpoint again before publication and eviction. A barrier
experiment permitted an ordinary writer at 100 and 5,000 base entries while
archive progress was paused. The larger write still took about 3.4 seconds.
Performance acceptance remains open. See the
[follow-up report](../../bench/results/2026-11-07.md).
The branch was rebased onto main `ae13433`. All 1,549 tests and every native
aarch64-darwin Nix check passed after the rebase. Archive crash tests use
fresh executable workers.

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
archive/objects/    complete archived payloads
archive/events/     complete archived events
archive/checkpoints/ immutable archive commit markers
```

Each manifest names all accepted events and payloads. It also names the
pending events and payloads. These pending sets form the durable outbox.
The active object pool holds pending bytes. Explicit archive preparation
adds a durable copy of every accepted payload and event. Archive manifests
appear only after all their dependencies are durable.

An optional `evicted-object` field records inactive copies in a checkpoint.
It does not remove accepted object IDs. Old manifests with no evictions keep
their canonical bytes. Earlier prototype binaries refuse this field. Every
writer and reader must upgrade together before eviction.

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
not inspect directory listings. Replica search indexes only causal topic
heads from one captured checkpoint. Legacy search still uses the legacy store.

The prototype validates full event and payload inventories on each load and
commit. This favours a simple correctness boundary. Incremental validation
and performance acceptance remain open.

Within one operation, transactions, GC plans and incoming archive preparation
reuse the verified payload map. Transactions save only new dependencies and
required restorations. Accepted dependencies became durable before their
previous `CURRENT` publication. Unaccepted preparations still pass through
the durable save path on retry. Later operations validate disk bytes again.

Unchanged sync validates the fetched bundle once. It does not read that same
Git commit again as a previous tip. A verified incoming inventory that is
already accepted locally needs no import. Later writers cannot invalidate
that subset check because accepted inventories only grow.
Matched before/after measurements at 5,000 entries show a median direct
commit of 1.72 → 1.09 seconds and unchanged sync of 9.51 → 7.44 seconds.
One independent writer still returned busy. All 1,550 tests and every native
aarch64-darwin Nix check passed. See the
[performance report](../../bench/results/2026-11-07-performance.md).

The filesystem helper uses `fsync`. It does not issue macOS `F_FULLFSYNC`.
The durability claim does not cover drive caches that survive an `fsync`.

## Next phase

Configured context and the replica browser share summary-aware log pages.
Each page keeps recent episodes whole and preserves exact direct and base
source IDs. Entry limits apply after disjoint summary selection. Complete
history validation permits at most 4096 memories across 32 levels per log;
excessive or incomplete histories produce explicit diagnostics. These limits
bound log traversal and entry counts, not individual memory body sizes or
the repository's existing full-inventory checkpoint validation.

The default is page 1, 20 entries and 10 recent whole episodes. CLI options
are `--log-page`, `--log-limit` and `--log-keep`. MCP uses `log_page`,
`log_limit` and `log_keep`. Later pages require the first response checkpoint
through CLI `--checkpoint` or MCP `log_checkpoint`. A changed checkpoint
refuses continuation; restart at page one. This avoids silent skips or
duplicates after concurrent writes. Summary coverage remains deterministic.

The live browser uses `/api/view` with `log_page`, `log_limit`, `log_keep`
and `checkpoint`. It reads exact evidence through `/api/source` with a
`memory` ID and the same `checkpoint`. A stale checkpoint returns HTTP 409.
Every body enters the DOM as text. Static exports contain one selected page
and source IDs; they do not request other pages or evidence over the network.

Measure representative write, lock, join and archive costs before release
acceptance. Ordinary consumer integration, incremental validation and
persistent search caches remain open. The read interfaces use captured
checkpoints. Context topic counts and body byte budgets remain open.

Keep network deployment and live cutover behind their acceptance checks.

## Manual transport and supported snapshot copy

Configure a separate protocol branch with `replica sync-config --remote URL`.
The default branch is `akyuu-sync-v1`. This configures local transport only.
`replica sync` performs exchange. `replica sync --dry-run` fetches and reports
without changing `CURRENT`, acknowledging exports or pushing. Preview can
change private Git data and the observed cursor. `replica sync-status` has
no network call and does not claim knowledge of unseen remote writes.

Git uses `transport.git`, never the live object's directory or its backup
repository. Trees contain only protocol, store-id, registry events, ordinary
events and sharded memory objects. Validate modes, paths, sizes, canonical
bytes, store identity, parent closure and every required payload before import.
Reject symlinks, submodules, unknown entries and duplicate event identities.
The next fetched tip must descend from the last observed valid tip and retain
its complete event and payload inventories. A descendant can still be an
invalid rewrite if it deletes entries.

Each exchange has three push attempts and a 60-second overall Git deadline.
The private prepared ref can change after a rejected proposal; remote pushes
never use force. A receipt fetch confirms the captured export inventory
before acknowledgement. Later local writes remain pending. If confirmation
fails, retry through a new fetch; do not infer that the push failed.
Progress metadata failure after acknowledgement does not reject the accepted
publication. The response reports whether status metadata was saved.

Git subprocesses run in owned groups with a shell anchor until cleanup.
Close inherited descriptors in the child before Git executes. A full
descriptor-limit scan proved expensive on Darwin. Bound stdout and discard
excess stderr. Disable hooks, global/system Git configuration, interactive
credentials and recursive submodules. SSH uses batch mode and the existing
SSH agent/configuration. Automated acceptance fixtures use local bare
repositories. A separate two-machine SSH experiment passed. HTTPS and
packet-loss recovery remain unverified.

The initial bounds are 100,000 tree entries, 256 MiB of expanded archive
blobs, 16 MiB per memory and 64 KiB per event. Monitor private Git storage
against 512 MiB during each command. The monitor can permit brief temporary
overshoot. A deadline, size violation or process failure preserves pending
local obligations. Incremental transport and archive compaction remain open.

`replica join --remote URL --label TEXT` validates the remote before import.
An empty destination gets its own identity and a matching recovery journal.
After interruption, acknowledge only the verified remote inventory. Never
acknowledge a local registration that the remote has not received. Each join
keeps a fresh REPLICA identity across retries. Unrelated nonempty targets fail.

`replica migrate --source DIR --classification FILE --dry-run` reads a legacy
snapshot under the source mutation lock. The JSON classification must name
every ref as topic or log; no name-based inference applies. Copy the returned
version with `--expected VERSION` to a separate destination. A changed source
or different journal refuses the copy. A nested destination is also refused.
Do not run this against the live store without a separate cutover decision.

Baseline IDs derive from the captured source inventory. Topic generations
describe their known legacy order, while log baselines name the current DAG
without rewriting memory bytes. The Unix epoch is an explicit baseline
sentinel, not an invented date for an original action. Missing historical
generations remain diagnostics; missing current or retaining payloads fail.
Preserve pins, reviews and tombstones. A canonical legacy-baseline memory
carries diagnostic metadata through the protocol archive, and LEGACY provides
a local report. Matching journals resume after baseline import, local
registration or archive preparation. The source stays unchanged.

This is a snapshot-copy migration, not in-place conversion or live cutover.
Cutover still requires a verified backup, a quiescent source and coordinated
upgrades of all readers, writers, GC jobs and front ends. The legacy version
helper now refuses checkpoint markers. Reconciliation of independently
edited legacy stores remains unsupported.

## Local archive, collection, pins and reviews

`replica archive` saves one complete accepted checkpoint locally. It does
not acknowledge remote publication or clear the outbox. Archive payloads,
events and manifests remain indefinitely. No command prunes them.

Transport calls `acknowledgePublished` only after it verifies remote
inclusion of the archived checkpoint's complete payload and event sets.
The API independently validates the complete local archive before it clears
obligations. It clears only the captured sets; newer local writes remain
pending. No standalone CLI or MCP command can acknowledge publication.
Direct archive tests simulate this boundary. Manual exchange tests verify
real Git publication through temporary local bare repositories.

`replica gc --dry-run --keep-generations N` reports a checkpoint-bound plan.
The default depth is 5, including the current generation. Each causal branch
retains that depth independently. Collection requires `--expected CHECKPOINT`
from a dry run and recomputes its roots under the shared mutation lock.
Depth must be from 1 to 1000.

Roots include every current ref head, live pins, pending objects, payloads
of pending events and their retaining dependencies. Pending event roots
protect intermediate versions even after a later local event clears a pin.
Log follows links and summary evidence retain their complete source history.
Published review records do not root their endpoints. GC preserves the
records and emits no replicated pin or review removal.

Collection saves a complete durable archive before it publishes an eviction
manifest. Archive preparation runs outside the mutation lock. Accepted
inventories only grow, and concurrent preparers save identical immutable bytes.
GC checks the expected checkpoint again under the lock after preparation.
A concurrent write makes that collection stale before any eviction.
GC then recomputes roots and publishes under the shared mutation lock.
It removes active copies only after `CURRENT` accepts that manifest.
An unlink failure reports `collection-incomplete` and the accepted checkpoint.
A retry completes removal. This prototype uses archive copies and eviction
metadata, rather than the legacy trash or tombstone mechanism.

Explicit reads try the active copy, then the archive if the file is missing.
An existing corrupt copy remains an error. Old captured snapshots survive
concurrent eviction. Reads do not restore files or add old versions to search.
Imports preserve earlier eviction for unchanged data. A new live ref, pin or
pending event restores its required payload before publication. A greater
generation depth also restores required historical copies.

All accepted events and payload IDs stay in the checkpoint. Load validates
their complete bytes, including archive fallback, and rejects eviction of
any current or pending dependency. Full inventory validation remains costly.
The local archive is a filesystem pool for this prototype. The separate Git
transport preserves the same immutable archive and acknowledgement rules.

`replica pin-state ID` and `replica review-state A B` return opaque resource
versions. `pin`, `unpin`, `review` and `unreview` require the matching version
as `--expected`. Review creation also requires `--agent` and `--reason`.
Each clear consumes every observed head. Unseen concurrent sets survive.
Review pair order does not change its resource. Concurrent reasons remain
visible in state reads. MCP exposes `pin_state`, `pin_set`, `pin_clear`,
`review_state`, `review_set` and `review_clear` in the replicated tool set.

## Replicated logs and summary levels

`replica append NAME --expected VERSION` appends to every observed log head.
Use the resource version from `replica read NAME`, even for a missing log.
The command supplies the follows edges and checks the version under lock.
Topics and type conflicts refuse ordinary append.

`replica log NAME --limit N` reads distinct episodes in reverse topological
order. Among unrelated available episodes, newer creation time comes first,
then ascending memory ID. Clock skew cannot move an ancestor before a child.
The default limit is 100. Limits apply after deduplication. JSON includes
the unvisited frontier and explicit read failures. A zero limit returns heads.
The old single-derived-from predecessor remains a legacy fallback.

`replica log-levels NAME` reads complete levels from one checkpoint. Its
top-level version binds every level and the absent next level. An unrelated
topic write does not change this version. Source history must be complete.
`replica summarise NAME --expected VERSION --level N --source ID ...`
records a summary in `NAME.lN`. Give two or more distinct IDs from the
immediately lower level. The write checks every captured level version under
the mutation lock. The command supplies derived_from and follows edges.

Concurrent summaries and overlapping source sets are valid. Resolution uses
descending level, descending base episode count, then ascending summary ID.
It accepts only disjoint coverage. Raw episodes fill gaps. Recent episodes
remain whole, and summaries that cover them are skipped. Higher levels
flatten their exact sources to a set of base episode IDs.

`replica log-resolution NAME --keep N` returns this view; keep defaults to 10.
`replica log-todo NAME --size N --keep N` suggests oldest uncovered batches.
Todo coverage uses the union of all source IDs from the next level.
`replica unfold ID` reads exact direct sources without summary substitution.
All commands support JSON. MCP exposes `log_read`, `log_append`, `log_levels`,
`log_summarise`, `log_resolution`, `log_todo` and `log_unfold` in the replicated
tool set. Legacy readers retain their existing chain semantics.

This prototype loads full history before it orders or limits a log read.
Time filters and resumable traversal remain open. Configured context and the
browser use the bounded summary pages described above. Archive-backed
collection is described above. No command resets a log or replaces it with
a summary.

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
and conflict markers. `replica configured-context` expands the configured
policy, tier manifest and directory rules. It accepts `--policy-ref`,
`--tiers-ref`, `--tier`, `--cwd` and extra `--ref` values.

Missing controls permit initial setup. Conflicted or invalid controls block
unrelated topic resolutions. The control refs themselves remain repairable.
Publication checks both control versions under the mutation lock. CLI writes
use configured control names; read-only flag overrides affect only that read.

`replica search WORDS` searches each current topic head separately. It groups
matching heads by topic before the limit. Results retain every alternative
and identify the matching heads. Superseded and unselected heads do not match.

`replica serve` provides a read-only loopback browser. Each response contains
topics, configured context and search results from one checkpoint.
`replica viz` exports a static HTML snapshot. Its local filter uses literal
text; the live browser uses FTS search. The legacy graph and GC views remain
separate and do not accept checkpoint roots.

With `--json`, failed writes return structured errors on stdout and exit 1.
Stale-version and conflict errors include the current heads. Successful reads
of conflicts exit 0. Without `--json`, failures use stderr.

`mcp --tool-set replicated` exposes `topic_read`, `topic_create`,
`topic_replace`, `topic_resolve`, `topic_conflicts`, `topic_context`,
`configured_context`, and `topic_search`.
Results carry the same JSON in text and MCP `structuredContent`, as the
[MCP tool specification](https://modelcontextprotocol.io/specification/2025-11-25/server/tools#structured-content)
recommends for compatibility. The server requires a
previously initialised local replica. It accepts explicit policy/tier flags.
The default tool set stays
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
`replica` check runs this smoke test without a remote or model. It also checks
browser script logic, conflict display and stale response rejection.
`ReplicaReadTests` covers context expansion, control races, current-head
search and HTTP guards. The smoke test also checks the loopback HTTP server.
