# shellcheck shell=bash
# shellcheck disable=SC2034,SC2154
# Section edges: links between memories, and neighbours.

sec_edges() {
  use_root edges
  mk "the target"
  tgt=$id
  ak ref set me/target "$tgt" --new

  t E01 "neighbours of a memory with no edges prints nothing and exits 0"
  ak neighbours "$tgt"
  need_rc 0
  need_out_empty

  t E02 "neighbours shows each kind of edge going out of a memory"
  ak add --kind fact --agent tester --about "$tgt" --derived-from "$tgt" --refines "$tgt" --body "has edges"
  need_rc 0
  src=$out
  ak neighbours "$src"
  need_rc 0
  need_out_has "out about $tgt"
  need_out_has "out derived-from $tgt"
  need_out_has "out refines $tgt"

  t E03 "neighbours shows the same edges coming in, at the target"
  ak neighbours "$tgt"
  need_out_has "in about $src"
  need_out_has "in derived-from $src"
  need_out_has "in refines $src"

  t E04 "neighbours takes the start of an id, and fails (exit 1) for an id that is not there"
  ak neighbours "${src:7:10}"
  need_rc 0
  need_out_has "out about"
  ak neighbours "$ZERO_ID"
  need_rc 1

  t E05 "an about-ref link shows the memory that the ref names now"
  ak add --kind fact --agent tester --about-ref me/target --body "a note about the target topic"
  need_rc 0
  lnk=$out
  ak neighbours "$lnk"
  need_out_has "out about-ref me/target $tgt"
  ak neighbours "$tgt"
  need_out_has "in about-ref me/target $lnk"

  t E06 "after the ref moves, the link follows it (it does not go stale)"
  akin "the target, revised" supersede me/target --expect "$tgt" --kind fact --agent tester
  need_rc 0
  tgt2=$out
  ak neighbours "$lnk"
  need_out_has "out about-ref me/target $tgt2"
  need_out_lacks "out about-ref me/target $tgt "
  ak neighbours "$tgt2"
  need_out_has "in about-ref me/target $lnk"
  ak neighbours "$tgt"
  need_out_lacks "in about-ref"

  t E07 "supersede shows as an edge in both directions"
  ak neighbours "$tgt2"
  need_out_has "out supersedes $tgt"
  ak neighbours "$tgt"
  need_out_has "in supersedes $tgt2"

  t E08 "a link to a ref that does not exist is refused (exit 1)"
  ak add --kind fact --agent tester --about-ref no/such --body x
  need_rc 1
  need_text_has "no/such"

  t E09 "a dangling edge is shown, and the id that it points at still lists the edge that comes in"
  ak add --kind fact --agent tester --about "$ZERO_ID" --body "points at nothing"
  need_rc 0
  dang=$out
  ak neighbours "$dang"
  need_out_has "out about $ZERO_ID"
  ak neighbours "$ZERO_ID"
  need_rc 0
  need_out_has "in about $dang"
}
