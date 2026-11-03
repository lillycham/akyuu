akyuu(1)

# NAME

akyuu, akyuu-backup, akyuu-version - a memory store for agents

# SYNOPSIS

*akyuu* [*--root* _dir_] [*--embed-profile* _name_] _command_ [_arg_ ...]

*akyuu* *--version*

*akyuu-backup* [*--root* _dir_] *--dest* _dir_ [*--keep* _n_]

*akyuu-version* [*--root* _dir_] [*--message* _text_] [*--push*]

# DESCRIPTION

*Akyuu* keeps memories for agents. A memory is a plain text file named by the
SHA-256 hash of its contents: once written, it never changes. A _ref_, such as
*me/garden*, names the current memory of a topic. To change what a ref says,
an agent writes a new memory that supersedes the old one and moves the ref to
it. The old memory stays until *gc* collects it. Memories link to older ones
with edges, and the links form a graph. The format on disk is in *akyuu*(5).

The store is the directory _dir_ of *--root*, or *$AKYUU_ROOT*, or *root* in
the config file (see CONFIGURATION). An _id_ is
*sha256-* and 64 hex digits; a command takes the first 4 or more of them, with
or without *sha256-*, when only one memory starts with them. A _duration_ is a
number and a unit: *30m*, *1h*, *7d* (*s*, *m*, *h* or *d*).

Agents use the store through *akyuu mcp*, an MCP server, or through the
commands below.

## Memories

*add* *--kind* _text_ *--agent* _text_ [*--ref* _name_] [_edges_] [_body_]
	Write a memory and print its id. The _kind_ says what it is (*fact*,
	*preference*, *decision*, ...) and the _agent_ who wrote it. The _body_ is
	*--body* _text_, *-f* _file_ or *--file* _file_, or the standard input. A
	body that has no text apart from white space is refused, here and in
	every command that writes a memory.
	The _edges_ are *--about*, *--derived-from*, *--refines* and *--supersedes*,
	each with an _id_, each repeatable: the new memory is about the target,
	comes from it, adds detail to it, or replaces it. With *--ref*, also make the
	new ref _name_ for it; the ref must not exist.
	*--about-ref* _name_, repeatable, says that the memory is about the ref
	_name_: whatever memory the ref names when it is read. The ref must exist.

*supersede* _name_ [*--expect* _id_] *--kind* _text_ *--agent* _text_ [_edges_] [_body_]
	Write a memory that replaces the current memory of the ref _name_, and move
	the ref to it. With *--expect*, fail unless the ref points at _id_ now: read
	the ref, then supersede what was read, so that two agents cannot overwrite
	each other.

*amend* _name_ [*--expect* _id_] [*--agent* _text_] (*--from* _text_ *--to* _text_ | *--append* _text_)
	Supersede the memory of _name_ with a copy that has one passage replaced
	(*--from* must occur once) or text added at the end. The copy keeps the
	kind, the agent (unless *--agent* is given), the edges and the about-ref
	links.

*get* [*--with-id*] _id_ | *get* [*--with-id*] *--ref* _name_
	Print a memory: its headers, a blank line, and its body, exactly as the
	store holds it. *--with-id* first prints a line *id:* _id_ with the id of the
	memory read, the value for *--expect*. The MCP tool *get* always starts with
	that line.

*neighbours* _id_
	Print the edges of a memory, in both directions, then its about-ref links:
	*out about-ref* _name_ _id_ for a link of this memory and the memory that
	the ref names now, and *in about-ref* _name_ _id_ for a memory with a link
	to a ref that names this one.

*compare* [*--json*] _id_ _id_
	Print what each of two memories says that the other lacks.

## Refs

*ref list*
	Print the name and the id of each ref.

*ref get* _name_ [*--history*]
	Print the id that _name_ points at; with *--history*, also its older
	values, newest first.

*ref set* _name_ _id_ [*--expect* _id_ | *--new*]
	Point _name_ at a memory that is in the store. *--new* fails if the ref
	exists.

A ref keeps its older values as _generations_, for *gc* and for the history.

GC and mutations share one store lock. Reference and pin target checks run
under that lock. A busy lock causes an error after about one second. Update
all writers and GC jobs together; old processes do not use this protocol.

## Experimental local replicas

*replica init* *--label* _text_ [*--json*]
	Create a local checkpoint repository in an empty directory. Existing
	replica initialisation can resume. This command does not migrate a legacy
	store or connect a remote. The local replica identity stays on this machine.

*replica read* _name_ [*--json*]
	Print every current head and the opaque version of the topic. A conflict
	has no selected current value. A missing topic has an explicit status.

*replica create* _name_ *--kind* _text_ *--agent* _text_ [_edges_] [_body_] [*--json*]
	Create a topic. Fail if its name exists. Memory arguments are as for *add*.
	Replica commands require complete memory IDs; they do not expand prefixes.

*replica replace* _name_ *--expected* _version_ *--kind* _text_ *--agent* _text_ [_edges_] [_body_] [*--json*]
	Replace one resolved topic. Copy the complete opaque version from
	*replica read*. A memory ID is not this version. Resolve conflicts first.

*replica resolve* _name_ *--expected* _version_ (*--select* _id_ | *--kind* _text_ *--agent* _text_ [_edges_] [_body_]) [*--json*]
	Resolve the current heads. Select one current memory, or write merged
	content. Selection preserves the memory bytes. New content supersedes all
	current head memories. A stale version refuses the operation.

*replica conflicts* [*--json*]
	List topic and ref type conflicts. Independent log heads are not conflicts.

*replica context* *--ref* _name_ ... [*--json*]
	Read explicit topics from one checkpoint. Include missing and conflict
	markers.

*replica configured-context* [*--policy-ref* _name_] [*--tiers-ref* _name_] [*--tier* _tier_] [*--cwd* _dir_] [*--ref* _name_] ... [*--json*]
	Read policy, tier, directory and extra refs from one checkpoint. The tier
	defaults to *always*. Unresolved controls suspend manifest expansion.
	The result includes readiness and diagnostics. Missing members retain
	explicit markers. Policy-dependent resolution checks control versions
	again under the mutation lock. Control refs themselves remain repairable.
	Resolution uses the policy and tier names from configuration. Context
	flags override names for that read only.

*replica search* _words_ ... [*--limit* _n_] [*--json*]
	Search current topic heads with SQLite FTS. The limit is from 1 to 100;
	the default is 10. A match in one conflict head returns every alternative.
	Words from different heads do not combine into one match. Superseded and
	unaccepted objects are absent. This command does not use embeddings.

*replica log* _name_ [*--limit* _n_] [*--json*]
	Read all branches once, with successors before ancestors. The default limit
	is 100 distinct episodes. An incomplete read reports its frontier and any
	unreadable memories. Clock skew does not change causal order.

*replica append* _name_ *--expected* _version_ *--kind* _text_ *--agent* _text_ [_edges_] [_body_] [*--json*]
	Append an episode that follows every observed log head. Copy the version
	from *replica read*. A missing ref starts a log. A topic or type conflict
	does not permit append. The command supplies the follows edges.

*replica log-levels* _name_ [*--json*]
	Read complete levels from one checkpoint. The top-level version describes
	the summary inputs. It differs from an individual log resource version.
	Incomplete history prevents this read and summary generation.

*replica summarise* _name_ *--expected* _version_ *--level* _n_ *--source* _id_ ... *--kind* _text_ *--agent* _text_ [_edges_] [_body_] [*--json*]
	Record a summary beside its sources. Give at least two distinct, complete
	IDs from the immediately lower level. Copy the source version from
	*replica log-levels* or *replica log-todo*. The transaction checks all
	source levels again. The command supplies derived_from and follows edges.
	Overlap with other summaries is valid. Every source remains stored.

*replica log-resolution* _name_ [*--keep* _n_] [*--json*]
	Select disjoint summaries by descending level, descending base source
	count, then ascending summary ID. Raw episodes fill uncovered gaps.
	The newest _n_ episodes remain whole; the default is 10.

*replica log-todo* _name_ [*--size* _n_] [*--keep* _n_] [*--json*]
	List uncovered source batches with their source version. The default size
	is 8, with a minimum of 2. Keep 10 recent base episodes whole by default.
	Coverage is the union of exact source IDs from the next level.

*replica unfold* _id_ [*--json*]
	Read the exact direct sources of an accepted summary in DAG order.
	This command does not substitute other summaries for the evidence.

*replica archive* [*--json*]
	Save a complete durable local archive of accepted events and payloads.
	Keep pending export obligations. This command does not publish to a remote.
	The archive retains bytes indefinitely and permits explicit fallback reads.

*replica gc* [*--keep-generations* _n_] [*--dry-run* | *--expected* _checkpoint_] [*--json*]
	Plan or remove unused local copies. The default generation depth is 5;
	valid depths are 1 to 1000. Retain ancestry along every causal branch.
	Copy the checkpoint from a dry run to collect. A changed checkpoint
	refuses collection. Pending exports, all current heads, pins, log history
	and retaining dependencies remain active. The archive keeps every accepted
	object. Reads of old snapshots fall back without restore to search.
	A new live reference restores its payload. A repeated import of old data
	preserves eviction. Local GC never removes review records or archive bytes.
	Until transport verifies publication, unpublished objects remain protected.

*replica pin-state* _id_ [*--json*]
	Read pin state and its opaque resource version.

*replica pin* _id_ *--expected* _version_ [*--json*]
	Pin an accepted memory. Use the version from *replica pin-state*.
	An archived memory becomes active again.

*replica unpin* _id_ *--expected* _version_ [*--json*]
	Clear every observed pin head. An unseen concurrent pin survives.

*replica review-state* _id_ _id_ [*--json*]
	Read every surviving review reason and the pair's opaque resource version.
	Pair order does not change the resource or version.

*replica review* _id_ _id_ *--expected* _version_ *--agent* _text_ *--reason* _text_ [*--json*]
	Record that two accepted memories are distinct. Use the version from
	*replica review-state*. Concurrent reasons remain visible.

*replica unreview* _id_ _id_ *--expected* _version_ [*--json*]
	Clear observed review heads. An unseen concurrent review survives.

*replica serve* [*--port* _n_] [_context-options_]
	Serve the read-only topic browser on loopback. Port 0, the default, chooses
	a free port. Print its URL. Context options are as for
	*replica configured-context*. Each API response contains one checkpoint.

*replica viz* [_context-options_]
	Print a static topic browser with an embedded checkpoint. The export has
	a literal text filter; live search uses SQLite FTS. It loads no external
	assets. Memory bodies remain plain text.

With *--json*, errors have a code and a message on stdout. Stale-write and
conflict errors also include the current heads. The exit code is 1 for a
failed operation. A successful read of a conflict has exit code 0.

Use *mcp --tool-set replicated* for the experimental topic and log tools. Results
include the same JSON in structured content and text. The set includes
*configured_context* and *topic_search*. Unresolved or invalid control refs
block unrelated resolution, but permit repairs to the controls themselves.
Missing controls permit initial setup. The log tools are *log_read*,
*log_append*, *log_levels*, *log_summarise*, *log_resolution*, *log_todo* and
*log_unfold*. Pin tools are *pin_state*, *pin_set* and *pin_clear*.
Review tools are *review_state*, *review_set* and *review_clear*. Each write
requires the resource version from its state read. GC and archive operations
remain CLI maintenance commands. This set has no legacy raw tools, migration,
or remote sync.
Legacy commands refuse checkpoint repositories.

## Logs and notes

A _log_ is a ref whose memories are episodes: things that happened, as opposed
to things that are true. Each episode has a *follows* edge to the one before
it, so the log keeps its whole history. (A log from before *follows* links
episodes with one *derived-from* edge; it is still read.)

*append* _ref_ *--kind* _text_ *--agent* _text_ [_edges_] [_body_]
	Add an episode to the log _ref_, and move the ref to it.

*note* [*--cwd* _dir_] [*--kind* _text_] [*--agent* _text_] [*--manifest* _name_] [*--about-ref* _name_] _text_ ...
	Append a note (kind *note*) to the log that the manifest names for the
	current directory, or _dir_. The agent is *--agent*, then *$AKYUU_AGENT*,
	then *agent* in the config file, then *agent*.
	*--about-ref* links the note to a ref, as for *add*.

*log* _ref_ [*-n* _n_ | *--limit* _n_] [*--full*] [*--since* _duration_] [*--todo* [*--size* _n_] | *--resolution* [*--budget* _chars_]] [*--keep* _n_]
	Print the episodes of a log, newest first: 20 of them, or _n_, or those of
	the last _duration_. *--full* prints the bodies too.
	A normal limit prints *more:* _id_ as a continuation. An unreadable episode
	instead prints the readable prefix and the failed id with its cause, then
	returns failure. The MCP result sets *isError*.

	*--todo* prints the oldest stretches that need a summary: runs of _n_ (8)
	memories that no summary covers, at level 1 (episodes) and above (level-1
	summaries, and so on). The newest _n_ (*--keep*, 10) episodes get no summary
	yet. *--resolution* prints each older stretch as the highest summary that
	covers it, and every other episode whole, so only a summary makes it
	shorter. With *--budget*, if the text is longer than _chars_, older
	episodes with no summary are cut to their first line, then fewer recent
	episodes are whole, and a last line says so; if it still cannot fit, it
	fails and says what it needs.

*summarise* _ref_ [*--level* _n_] *--source* _id_ ... *--agent* _text_ [*--kind* _text_] [_body_]
	Record a summary of the oldest stretch of the log _ref_ that has none. The
	sources are the memories that it covers, as *log --todo* lists them: at
	level 1 (the default) the oldest episodes that no summary covers, at level
	_n_ the oldest summaries of level _n_ - 1. The summary gets a *derived-from*
	edge to each source and goes to the log _ref_*.l*_n_. The episodes stay. The
	kind is *summary*, or *--kind*.
	Every existing source chain must be complete. An unreadable episode or
	level ref causes an error before the summary is written.

*unfold* _id_
	Print the sources of a summary, newest first, whole: the exact words that it
	stands for.

## Sources

A _pointer_ says which agent session a memory came from, and when. It is a
memory of kind *source* whose body is a few *key: value* lines (*format*,
*session*, *at*, and optionally *from*, *to* and *hint*), so the store does not
change. A note or a fact links to it with a *derived-from* edge. The
transcripts are not in the store. They are files that an agent keeps, or an
archive of them, found under the *source.roots* of the config file. A session
that is not on this machine is not an error of the store: the commands say
that it is not available.

*source add* [*--format* _format_] *--session* _id_ [*--at* _time_] [*--from* _id_] [*--to* _id_] [*--hint* _path_] [*--agent* _text_] [*--hash*]
	Make a pointer and print its id. The format is *claude-code* (the default),
	*codex* (the rollouts of the Codex CLI) or *omp* (oh-my-pi, and pi, which has
	the same shape). The session is the id that the transcript file is named for:
	for Claude Code the whole name, for Codex and omp the id at the end of it
	(a Codex file is named rollout, a time and the id, with hyphens; an omp file
	a time, an underscore and the id), and for an omp session that has a name,
	the name.
	The time is like *2026-11-01T19:00:58Z*, and is now if it is left out. *--from*
	and *--to* are the ids of the first and the last record, if something
	knows them. *--hint* is a path below a root, for a person to read; it never
	holds a home directory and is not used to find the file. The agent is
	*--agent*, then *$AKYUU_AGENT*, then *agent* in the config file. Link a
	memory to the pointer with *--derived-from* when you *add* it.
	With *--hash* the pointer also holds the SHA-256 of the records from *--from*
	to *--to* (all the lines between them), as they are in the file now, with the
	strip rule of the archive tool engi applied: the data of images and opaque
	signatures are replaced by a placeholder that holds their hash. It needs both
	ids, the session on this machine, and the *engi* command on the PATH, which
	applies the rule so that akyuu does not have a second copy of it.

*source show* _id_ [*--before* _n_] [*--after* _n_]
	Print the records of the session around the time of the pointer: _n_ (6)
	before it and _n_ (2) after it, or the whole range if the pointer has both
	*--from* and *--to*. _id_ is a pointer, or a memory with a *derived-from*
	link to one. Each record has its time, its speaker and its text; long
	tool output is cut. The session is looked for under the roots: the
	agent's own files first, then an archive, and of an archive the newest
	version. A file that is compressed with zstd is read with the *zstd*
	command, which must be on the PATH. If the session is not found, the
	output says so and the exit status is 1.

*source verify* _id_
	Say where the session of the pointer is (the file and whether it is the
	agent's own or an archive), or that it is not available. If the pointer
	holds a hash, the records are read again and compared with it: the line
	ends with *hash intact*, *hash CHANGED* (the records are not the ones that
	the pointer saw), or *hash not checked* and why (for example, *engi* is not
	on the PATH). Exit status 1 if the session is not available, if the hash
	is changed, or if it could not be checked.

*source hook* [*--format* _format_]
	For the start hook of an agent. Read the JSON that the agent gives the hook
	on its standard input, and print the id of the session with the command to
	make a pointer to it, so that the agent can record where a memory came from.
	Claude Code sends *session_id* in that JSON; the format is *claude-code*
	(the default), *codex* or *omp*. It prints nothing, and exits 0, if the
	input has no usable session id.

## Context

The _manifest_ is the memory of the ref *policy/tiers* (or *--manifest*, or
*$AKYUU_TIERS_REF*, or *tiers-ref* in the config file). Each line is a tier and
its refs, *always:* _refs_; or *at* _dir_*:* _refs_, refs for a session in _dir_
or below it; or *log* _dir_*:* _ref_, the log that *note* writes to (_dir_ may
be *\**, and *~* is the home directory).

*context* [*--tier* _name_] [*--ref* _name_] [*--manifest* _name_] [*--cwd* _dir_] [*--budget* _chars_] [*--page* _n_]
	Print the memories of the tier *always* (or _name_) and of the place, with
	the names of the other refs, for the start of a session. *--ref* adds a ref
	and repeats. *--budget* splits the output into pages of about _chars_
	characters (9500 by default) and *--page* prints one; a page after the last
	prints nothing. This suits a hook whose output is cut.

*init*
	Make the root, a short policy for agents (*policy/memory*) and a manifest
	(*policy/tiers*). Refs that exist are kept.

*status*
	Print the root, the counts, the manifest, the policy, whether search by
	meaning and versioning are set up, and the config file.

*config*
	Print each setting in effect and where it came from: an option, a
	variable, the config file or the default. Then print the notes about the
	file: unknown keys, values that were left out, an older file. It needs no
	store, so it also explains a setup that does not work.

## Search

*search* [*--mode* _mode_] [*-n* _n_ | *--limit* _n_] [*--hops* _n_] [*--follow* _kind_] _word_ ...
	Search the memories and print the hits, current memories first, with the
	memories up to _n_ edges away (1 by default; *--follow* takes only edges of
	_kind_, and repeats). A word that no memory has is tried as the start of a
	word, then as the near spellings that the index has. The _mode_ is *fused* (words and
	meaning, the default), *text* or *meaning*.

*embed* [*--prune*]
	Give a vector to each memory that has none, with the embedding profile in
	use (see CONFIGURATION). *--prune* also removes the vectors of other keys
	and of deleted memories. It warns when the vectors of the key were made by
	another command, other arguments or other prefixes. Without a profile,
	search uses words only.

*search-eval* [*--set* _name_] [*--k* _n_]
	Run the searches in the memory of _name_ (*policy/embedding-eval* by
	default) in each mode, and count those that find the expected memories in
	the first _n_ hits (3).

## Keeping the store

*gc* [*--dry-run*] [*--keep-generations* _n_] [*--grace* _duration_] [*--trash-ttl* _duration_]
	Collect the memories that nothing needs. A memory stays if a ref points at
	it now or in its last _n_ generations (5), if it is pinned, if it is
	younger than the grace period (*1h*), or if a memory that stays has an
	*about*, *derived-from*, *refines* or *follows* edge to it. A *supersedes* edge keeps
	nothing. Collected memories go to the trash, and a tombstone records
	each deleted id; *gc* deletes trash older than the trash TTL (*7d*).
	*--dry-run* prints the plan and writes nothing.

*pin* _id_, *unpin* _id_, *pins*
	Pin a memory so that *gc* keeps it, remove a pin, list the pins.

*check* [*--kind* _kind_] [*--severity* _level_] [*--strict*] [*--json*] [*--near-threshold* _x_] [*--hub-degree* _n_] [*--min-words* _n_] [*--long-log* _n_]
	Print the memories that need attention: stale links (an *about* or
	*refines* edge to a memory that is superseded), about-ref links to a ref
	that does not exist, forks (two memories that supersede the same one), duplicates
	and near duplicates (sharing more than _x_ of their text, 0.8, if they have
	_n_ words or more, 5), two memories under different refs whose first
	lines name the same path, hubs (more than _n_ links, 5), long logs (more than
	_n_ episodes, 30), and memories that nothing keeps. A finding has a
	_level_: *info*, *suggestion* or *problem*. *--strict* exits 1 if a
	problem is shown. *check* changes nothing.

*review* _id_ _id_ *--agent* _name_ [*--note* _text_], *unreview* _id_ _id_, *reviews*
	Record that two memories differ and are both true, so that *check* leaves
	the pair out; remove that record; list the records.

*verify*
	Check that each object hashes to its name, and each edge and ref points at
	an object; report where the cache and the store differ.

*reindex*
	Throw the cache away and read the store again.

## Agents and the web

*mcp* [*--policy-ref* _name_] [*--tiers-ref* _name_] [*--tool-set* _set_]
	Serve the Model Context Protocol (JSON-RPC 2.0) on the standard input and
	output until the input ends. The default tool set is *ordinary*: context,
	search, get, log, unfold, note, add, amend, and supersede. Select
	*--tool-set maintenance* for the full set, with raw object and ref tools.
	Ordinary add requires a new ref. Ordinary add and supersede use the
	configured agent as the default author. An explicit agent overrides it.
	Both sets require expected for amend and supersede. Use the id from get.
	Select *--tool-set topic* for an agent that should not handle ids. The
	tools are context, log, unfold, and these, which name topics (refs) and
	use plain text: *recall* finds topics or reads one, *remember* makes a
	topic, *add_to* adds a line, *revise* changes a part of the text, *replace*
	rewrites the whole text, and *note* records an episode. The server
	retries a busy store lock, and it adds and revises under the lock, so a
	writer needs no version for them. Only *replace* takes a version: the one
	that *recall* shows. A stale version is refused with the current text.
	*recall* of a topic ends with a *related:* line: up to three other topics
	that belong with it, each with a reason (*linked*, *mentioned* or
	*similar text*). See *topic.related* in CONFIGURATION.
	If the config has *source.mcp = true*, every tool set also has
	*source_show*, with the arguments *id*, *before* and *after* of *source
	show*. The server
	tells the agent to read the policy (*policy/memory*, or *--policy-ref*, or
	*$AKYUU_POLICY_REF*, or *policy-ref* in the config file) first.

*serve* [*-p* _n_ | *--port* _n_]
	Serve a read-only web view of the store on 127.0.0.1, port _n_ (7420; *0*
	picks a free one), and print its address. It answers only requests for that
	host and port.

*viz*
	Print the same view, with the store in it, as one HTML file.

*seed* *--demo* [*--root* _dir_]
	Make a small demo store in _dir_, which must hold no data.

## Backups and versions

*akyuu-backup* copies the parts of the store that cannot be made again into a
new directory under the *--dest* _dir_, named by the time, and keeps the
newest _n_ (14). A file that did not change is a hard link to the one in the
last snapshot, so a snapshot of a quiet store costs almost nothing. The refs
are copied before the objects: an agent writes a memory before it moves a ref
to it, so each ref in a snapshot points at a memory in it. To restore, copy a
snapshot into an empty root, then run *akyuu reindex* and *akyuu verify*.

*akyuu-version* commits the store to a git repository in the root, one commit
for each run that finds a change, with a message that counts what changed.
*--message* adds a line. *--push* pushes to the first remote; a failed push is
a warning.

# CONFIGURATION

The settings are in a TOML file, *~/.config/akyuu/config.toml* (or
*$XDG_CONFIG_HOME/akyuu/config.toml*, or *$AKYUU_CONFIG*). Every key is
optional. A variable of the environment wins over the file, and an option wins
over both; *akyuu config* shows which one set each value.

```
root = "~/.local/share/akyuu"
policy-ref = "me/policy"
tiers-ref = "policy/tiers"
agent = "me"

[topic]
related = true
parallel = ["notes/recipes"]

[source]
mcp = false
roots = [{ format = "claude-code", path = "~/.claude/projects" }]

[embed]
profile = "nomic"

[embed.profiles.nomic]
command = "akyuu-embed-llama"
key = "llama:nomic-v1.5-q8_0"
query-prefix = "search_query: "
document-prefix = "search_document: "
min = 0.55
timeout = 60
args = { gguf = "/models/nomic-embed-text-v1.5.Q8_0.gguf" }
```

*root*, *policy-ref*, *tiers-ref* and *agent* are the store, the refs of the
policy and the manifest, and the agent of *note* and *mcp*; *~/* at the start
of *root* is the home directory.

*topic.related* (true by default) shows the related topics when an agent of
the topic tool set recalls a topic. Akyuu works the list out each time and
does not store it. A topic scores higher when its text is near, when one
topic links to the other, and when one topic names the other in its text. A
link or a name counts less when its source points at many topics. Only a topic
with a positive score is listed. Without vectors the list holds only topics
that are linked or mentioned. *topic.parallel* is a list of namespaces whose
topics are parallel instances of one kind (for example *notes/recipes*):
such topics look alike because they share a form, so two of them are related
only if they are linked or mentioned. The default is no namespace.

*source.roots* is a list of folders that hold agent transcripts, each with the
_format_ of the transcripts in it and a _path_ (*~/* at the start is the home
directory). A root is searched below its folders; it can be the agent's own
folder or an archive of it. There is no default: akyuu does not guess where a
person keeps them. *source.mcp* (false by default) makes *akyuu mcp* offer the
tool *source_show* in every tool set. It is off by default because the tool
hands the text of one agent's sessions to another. See *source show*.

An embedding profile turns search by meaning on. Its *command*, run by *sh -c*,
reads a text on its standard input and prints a vector as JSON. *key* names
the vectors: vectors with different keys are never compared, so change it
when the model, its runtime or its quantisation changes. Akyuu puts
*query-prefix* before a search and *document-prefix* before a memory. *min* is
the lowest cosine similarity that counts as near (none by default; it depends
on the model, so find it with *search-eval*). *timeout* is the seconds for one
call (10), and *max-chars* the most characters sent (4000). Each key of *args*
reaches the command as a variable: *gguf* as *AKYUU_EMBED_GGUF*, *api-model*
as *AKYUU_EMBED_API_MODEL*; akyuu itself does not read them.

*embed.profile* names the profile in use; a file with one profile needs no
name. *--embed-profile* or *$AKYUU_EMBED_PROFILE* picks another for one
command, which suits a comparison of models with *search-eval*.

# ENVIRONMENT

*AKYUU_ROOT*, *AKYUU_POLICY_REF*, *AKYUU_TIERS_REF*, *AKYUU_AGENT*
	The settings *root*, *policy-ref*, *tiers-ref* and *agent*, over the
	config file. An empty value is no value.

*AKYUU_TOPIC_RELATED*, *AKYUU_TOPIC_PARALLEL*
	The settings *topic.related* (true, false, yes, no, on, off, 1 or 0) and
	*topic.parallel* (names separated by commas), over the config file.

*AKYUU_EMBED_PROFILE*
	The embedding profile in use, over *embed.profile*.

*AKYUU_EMBED_MIN*, *AKYUU_EMBED_TIMEOUT*, *AKYUU_EMBED_MAX_CHARS*
	The *min*, *timeout* and *max-chars* of the profile in use, over the file.

*AKYUU_EMBED_COMMAND*, *AKYUU_EMBED_MODEL*, *AKYUU_EMBED_QUERY_PREFIX*, *AKYUU_EMBED_DOCUMENT_PREFIX*
	The older way to set search by meaning: a profile named *environment*,
	with the command, the key and the prefixes. It wins over the profiles of
	the file. The command gets every *AKYUU_EMBED_* variable, as before.

*AKYUU_EMBED_ROLE*
	Set for the command: *query* or *document*.

*AKYUU_CONFIG*
	The config file. A name that ends in *.toml* is read as TOML; any other
	name is read in the older format of *embed.env*.

# FILES

_root_/store/
	The memories, one file each; see *akyuu*(5).

_root_/refs/
	The refs, one file each.

_root_/pins/, _root_/reviewed/, _root_/tombstones/, _root_/trash/
	Pins, reviews, the ids that *gc* deleted, and what it moved aside.

_root_/cache.sqlite, _root_/embeddings.sqlite
	The text index and the vectors. They are made from the store, and can be
	deleted at any time.

_root_/embeddings.sqlite also keeps a fingerprint of the profile that made
the vectors of each key, for the warning of *embed* and *status*.

*~/.config/akyuu/config.toml*
	The settings; see CONFIGURATION.

*~/.config/akyuu/embed.env*
	The older settings for search by meaning: *NAME=value* lines of the
	*AKYUU_EMBED_* variables. It is read only when there is no
	*config.toml*, and *akyuu config* says to move it.

# EXAMPLES

Start a store, write a memory under a ref, and change it:

```
mkdir -p ~/.config/akyuu
echo 'root = "~/.local/share/akyuu"' > ~/.config/akyuu/config.toml
akyuu init
akyuu add --ref me/garden --kind fact --agent me --body 'Water the tomatoes daily.'
akyuu amend me/garden --from daily --to 'every second day'
akyuu ref get me/garden --history
```

Keep a log, and read the last week of it:

```
akyuu append me/episodes --kind episode --agent me --body 'Picked the first basil.'
akyuu log me/episodes --since 7d
```

Compare a second embedding profile with the one in use:

```
akyuu --embed-profile gemma embed
akyuu --embed-profile gemma search-eval
akyuu search-eval
```

See what *gc* would collect, and what needs attention:

```
akyuu gc --dry-run
akyuu check --severity suggestion
```

Give the store to Claude Code:

```
claude mcp add --scope user akyuu -- akyuu --root ~/.local/share/akyuu mcp
```

# DIAGNOSTICS

The exit status is 0 on success, 1 when an operation fails, and 2 for bad
usage.

# SOURCE

https://github.com/lillycham/akyuu

# SEE ALSO

*akyuu*(5), *git*(1), *sqlite3*(1)

The documents in the source: *docs/install.md*, *docs/agent-install.md*,
*docs/hooks.md*, *docs/episodes.md*, *docs/embeddings.md*, *docs/check.md*.

# BUGS

There is no access control. Any client of the MCP server can add memories and
move refs, and *serve* shows every memory to anyone on the machine.

An object write and a reference replacement are not one crash-atomic
transaction. A crash or I/O failure between them can leave a searchable,
unreferenced object. Stale expectations reject before the object write.

A log keeps every episode. Summaries make it short to read (*log --resolution*),
but an agent must write them (*summarise*): akyuu runs no model.

*check* reports forks, but there is no rule for which side wins.

Forgetting is slow by design: a superseded text stays for the ref
generations, the grace period and the trash TTL, and in git with
*akyuu-version*, until the history is rewritten.

The store format has no version marker; see *akyuu*(5).

Akyuu runs only on POSIX systems.
