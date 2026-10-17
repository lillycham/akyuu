# shellcheck shell=bash
# shellcheck disable=SC2034,SC2154
# Section supersede: replace and change the memory of a ref.

sec_supersede() {
  use_root supersede
  ak add --kind preference --agent tester --ref me/lang --body "I prefer Haskell for tools."
  old=$out

  t U01 "supersede --expect moves the ref to a new memory and prints its id"
  akin "I prefer Haskell, and Nix for every tool." supersede me/lang --expect "$old" --kind preference --agent tester
  need_rc 0
  need_id "$out"
  new=$out
  need_ne "$new" "$old" "the new id"
  ak ref get me/lang
  need_out_eq "$new"

  t U02 "the old memory is still there to read, and the new one says it supersedes it"
  ak get "$old"
  need_rc 0
  need_out_has "I prefer Haskell for tools."
  ak get "$new"
  need_out_has "supersedes: $old"
  need_out_has "Nix for every tool"

  t U03 "ref get --history shows the old id after the new one"
  ak ref get me/lang --history
  need_eq "$(line_n 1)" "$new"
  need_eq "$(line_n 2)" "$old"

  t U04 "supersede with a stale --expect fails (exit 1), names the real value, and leaves the ref alone"
  ak supersede me/lang --expect "$old" --kind preference --agent tester --body "a stale write"
  need_rc 1
  need_text_has "$new"
  ak ref get me/lang
  need_out_eq "$new"

  t U05 "supersede of a ref that does not exist fails (exit 1)"
  ak supersede no/such --kind fact --agent tester --body x
  need_rc 1

  t U06 "supersede takes the body from --body too, and takes edge options"
  mk "something to point at"
  tgt=$id
  ak supersede me/lang --expect "$new" --kind preference --agent tester --about "$tgt" --body "third version"
  need_rc 0
  ak get --ref me/lang
  need_out_has "about: $tgt"
  need_out_has "third version"
  third=$(cat "$outf" >/dev/null; "$bin" ref get me/lang)

  t U07 "supersede needs --kind and --agent (exit 2)"
  ak supersede me/lang --agent tester --body x
  need_rc 2
  ak supersede me/lang --kind fact --body x
  need_rc 2

  # amend
  ak add --kind decision --agent writer --ref me/plan --body "We will use foo for storage and bar for search."
  p1=$out

  t U08 "amend --from/--to replaces one passage, and moves the ref"
  ak amend me/plan --from "foo for storage" --to "baz for storage"
  need_rc 0
  p2=$out
  need_id "$p2"
  ak get --ref me/plan
  need_out_has "We will use baz for storage and bar for search."
  need_out_lacks "foo"
  ak ref get me/plan --history
  need_eq "$(nlines "$out")" 2 "number of generations"

  t U09 "amend keeps the kind and the agent, unless --agent is given"
  ak get --ref me/plan
  need_out_has "kind: decision"
  need_out_has "agent: writer"
  ak amend me/plan --from "bar" --to "qux" --agent editor
  need_rc 0
  ak get --ref me/plan
  need_out_has "agent: editor"
  need_out_has "kind: decision"

  t U10 "amend --from with text that is not in the memory fails (exit 1) and changes nothing"
  ak ref get me/plan
  before=$out
  ak amend me/plan --from "not in the memory" --to "x"
  need_rc 1
  ak ref get me/plan
  need_out_eq "$before"

  t U11 "amend --from with text that occurs more than once fails (exit 1) and says how often"
  mk "ab ab ab"
  ak ref set me/twice "$id" --new
  ak amend me/twice --from "ab" --to "cd"
  need_rc 1
  need_text_has "3 times"

  t U12 "amend --append adds the text at the end, on a new line"
  ak amend me/plan --append "More later."
  need_rc 0
  ak get --ref me/plan
  need_eq "$(tail -n 2 "$outf" | head -n 1)" "We will use baz for storage and qux for search." "the line before the new text"
  need_eq "$(tail -n 1 "$outf")" "More later." "the last line"

  t U13 "amend keeps the edges and the about-ref links"
  mk "linked memory"
  lnk=$id
  ak ref set me/linked "$lnk" --new
  ak add --kind fact --agent writer --about "$lnk" --refines "$lnk" --about-ref me/linked --body "see foo here" --ref me/holder
  need_rc 0
  ak amend me/holder --from foo --to bar
  need_rc 0
  ak get --ref me/holder
  need_out_has "about: $lnk"
  need_out_has "refines: $lnk"
  need_out_has "about-ref: me/linked"
  need_out_has "see bar here"

  t U14 "amend --expect with a stale value fails (exit 1)"
  ak ref get me/plan --history
  oldest=$(tail -n 1 "$outf")
  need_ne "$oldest" "" "the oldest id"
  ak amend me/plan --append " x" --expect "$oldest"
  need_rc 1

  t U15 "amend of a ref that does not exist fails (exit 1)"
  ak amend no/such --append x
  need_rc 1

  xt U16 "supersede with no body at all is refused, and does not blank the memory" \
    "a call with no --body and an empty standard input writes an empty memory and moves the ref to it (a footgun for an agent that forgets the body)"
  ak ref get me/plan
  before=$out
  ak supersede me/plan --kind decision --agent tester
  [ "$rc" != 0 ] || fail "supersede with no body succeeded"
  ak ref get me/plan
  need_out_eq "$before" "the ref moved to an empty memory"
}
