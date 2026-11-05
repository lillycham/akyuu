# shellcheck shell=bash
# shellcheck disable=SC2034,SC2154
# Section gc: what the collector keeps, what it moves, and what it deletes.

# The number of memory files in the store.
count_store() { find "$AKYUU_ROOT/store" -type f 2>/dev/null | wc -l | tr -d ' '; }
count_trash() { find "$AKYUU_ROOT/trash" -type f 2>/dev/null | wc -l | tr -d ' '; }

sec_gc() {
  use_root gc
  ak add --kind fact --agent tester --ref me/doc --body "doc version one"
  v1=$out
  akin "doc version two" supersede me/doc --kind fact --agent tester
  v2=$out
  akin "doc version three" supersede me/doc --kind fact --agent tester
  v3=$out
  mk "a memory that nothing keeps"
  lonely=$id
  all_before=$(count_store)

  t G01 "gc --dry-run with the default grace period collects nothing, because every memory is young"
  ak gc --dry-run
  need_rc 0
  need_out_has "would collect 0 objects"

  t G02 "gc --dry-run lists what a sweep would collect, and writes nothing"
  ak gc --dry-run --grace 0s --keep-generations 0
  need_rc 0
  need_out_has "$lonely"
  need_out_has "$v1"
  need_out_has "$v2"
  need_out_lacks "$v3"
  need_out_has "would collect 3 objects"
  need_eq "$(count_store)" "$all_before" "files in the store"
  need_eq "$(count_trash)" 0 "files in the trash"

  t G03 "memories in the last generations of a ref are kept (the default is 5)"
  ak gc --dry-run --grace 0s
  need_rc 0
  need_out_has "$lonely"
  need_out_lacks "$v1"
  need_out_lacks "$v2"
  need_out_match "would collect 1 objects?"

  t G04 "a pinned memory is kept, pins lists it, and unpin lets it go"
  ak pin "$lonely"
  need_rc 0
  ak pins
  need_out_has "$lonely"
  ak gc --dry-run --grace 0s --keep-generations 0
  need_out_lacks "$lonely"
  need_out_has "would collect 2 objects"
  ak unpin "$lonely"
  need_rc 0
  ak pins
  need_out_empty
  ak pin "$ZERO_ID"
  need_rc 1

  t G05 "a memory that a kept memory has an about, derived-from or refines edge to is kept"
  mk "target of about"
  ta=$id
  mk "target of derived-from"
  td=$id
  mk "target of refines"
  tr=$id
  ak add --kind fact --agent tester --ref me/holder --about "$ta" --derived-from "$td" --refines "$tr" --body "keeps three"
  ak gc --dry-run --grace 0s --keep-generations 0
  need_rc 0
  need_out_lacks "$ta"
  need_out_lacks "$td"
  need_out_lacks "$tr"

  t G06 "a supersedes edge keeps nothing: the old memory goes when its generation is out"
  ak gc --dry-run --grace 0s --keep-generations 0
  need_out_has "$v1"
  need_out_has "$v2"

  t G07 "gc moves what it collects to the trash, and it can no longer be read"
  ak gc --grace 0s --keep-generations 0
  need_rc 0
  need_out_has "moved 3 objects to trash"
  need_eq "$(count_trash)" 3 "files in the trash"
  for x in "$lonely" "$v1" "$v2"; do
    ak get "$x"
    [ "$rc" = 1 ] || fail "get $x exits $rc after the sweep, expected 1"
  done
  ak get --ref me/doc
  need_rc 0
  need_out_has "doc version three"

  t G08 "a second gc finds nothing to collect"
  ak gc --grace 0s --keep-generations 0
  need_rc 0
  need_out_has "moved 0 objects"

  xt G09 "verify does not report a problem for ids that gc moved to the trash" \
    "verify exits 1 and says 'missing' for each id that GC moved to the trash, if a kept memory has a supersedes edge to it. The report is clean again only after the trash is deleted (--trash-ttl, 7 days) and the id is a tombstone."
  ak verify
  need_rc 0

  t G10 "gc --trash-ttl 0s deletes the trash, and records a tombstone for each deleted id"
  ak gc --grace 0s --keep-generations 0 --trash-ttl 0s
  need_rc 0
  need_out_has "deleted 3 old trash files"
  need_eq "$(count_trash)" 0 "files in the trash"
  need_eq "$(find "$AKYUU_ROOT/tombstones" -type f 2>/dev/null | wc -l | tr -d ' ')" 3 "tombstones"

  t G11 "after the tombstones, verify is clean, and says that the pruned targets are normal"
  ak verify
  need_rc 0
  need_out_has "pruned"
  need_out_has "ok: checked"

  t G12 "a bad duration or number for gc is bad usage (exit 2)"
  ak gc --grace banana
  need_rc 2
  ak gc --trash-ttl 5x
  need_rc 2

  t G13 "gc keeps the current memory of every ref, whatever the options"
  ak gc --grace 0s --keep-generations 0 --trash-ttl 0s
  ak get --ref me/doc
  need_rc 0
  ak get --ref me/holder
  need_rc 0
}
