akyuu(5)

# NAME

akyuu - the files of a memory store

# DESCRIPTION

A store is a directory of plain text files. *akyuu*(1) writes and reads it, but
a person or another tool can read it with no more than *sha256sum*(1) and a
text editor. This is version 1 of the format. The files carry no version
marker: a store without one is version 1.

## Memories

A memory is one UTF-8 file, *store/*_xx_*/sha256-*_hex_*.md*, where _hex_ is
the 64 hex digits of the SHA-256 digest of the file and _xx_ is its first byte.
The name of the file is the _id_ of the memory. Because the id is the hash of
the bytes, a memory cannot change: a changed text is another memory.

```
kind: fact
created: 2026-10-05T12:00:00Z
agent: claude
supersedes: sha256-...
about: sha256-...

The body is free text. It may have many lines.
```

The headers come first, then a blank line, then the body. A header is a name, a
colon, one space and a value. *kind*, *created* and *agent* are required, once
each and in that order; *kind* and *agent* are one line, not empty, with no
space at either end; *created* is UTC in whole seconds. The edge headers follow:
*supersedes*, *about*, *derived-from* and *refines*, in that order, each with
one id and each repeatable, the ids of one name in ascending order and none
twice. The body is everything after the first blank line, unchanged. Lines end
with a line feed.

This is the only form. *akyuu* refuses a file in any other form (headers in
another order, a repeated edge, an unknown header), because the id must be the
hash of exactly this text.

## Edges

An edge goes from a newer memory to an older one, or to an id that is not in
the store. So the graph has no cycles.

*supersedes*
	This memory replaces the target.

*about*
	This memory is about the target.

*derived-from*
	This memory comes from the target. The episodes of a log point at the
	episode before them with this edge.

*refines*
	This memory adds detail to the target.

*gc* keeps the target of an *about*, *derived-from* or *refines* edge from a
memory that it keeps. A *supersedes* edge keeps nothing.

## Refs

*refs/*_name_ is a text file with one id on each line. The first line is the
current memory; the others are older values, newest first, as many as *gc*
keeps. A _name_ is parts of *a*-*z*, *0*-*9*, *-*, *\_* and *.*, joined with
*/*. A part is a directory, so a name cannot be the start of another. A change
replaces the file atomically, under the lock *refs/.lock*, and can check the
current value first.

## Other files

*pins/sha256-*...
	An empty file. Its name is a pinned id.

*reviewed/*_id_*\_*_id_
	A pair of memories that a person judged different and both true, the lower
	id first.

*tombstones/sha256-*...
	One line, *pruned:* _time_. *gc* leaves one for each object that it deletes,
	so a reader can say that the memory is gone and name the newer one.

*trash/sha256-*...*.md*
	An object that *gc* moved out of *store/*, in the same format. *gc* deletes
	it after the trash TTL.

*cache.sqlite*, *embeddings.sqlite*
	The text index and the vectors for search by meaning. They are made from the
	files above. Delete them at any time; *akyuu reindex* and *akyuu embed* make
	them again.

*\*.lock*, *.lock*
	Locks. They carry no data.

## What is stable

Memories and refs are stable, and so are pins, reviews and tombstones, which
are small. The caches and the locks are not. Before version 1.0 of akyuu an
incompatible change is possible; the CHANGELOG then says how to move a store.
A newer akyuu reads every store that an older one wrote. An older one refuses a
header that it does not know, so that it never reads a file wrongly.

## Copying a store

Copy *refs*, *pins*, *store*, *reviewed* and *tombstones*, in that order: an
agent writes a memory before it moves a ref to it, so refs that were copied
first point only at memories that the later copy has. *akyuu-backup* does this.
Then run *akyuu reindex* and *akyuu verify* in the copy.

# SEE ALSO

*akyuu*(1)

# BUGS

The files have no version marker, so a future version can only tell version 1
by what is missing.
