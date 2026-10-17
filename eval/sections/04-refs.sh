# shellcheck shell=bash
# shellcheck disable=SC2034,SC2154
# Section refs: names that point at memories, and their history.

sec_refs() {
  use_root refs
  mk "first value"
  v1=$id
  mk "second value"
  v2=$id
  mk "third value"
  v3=$id

  t R01 "ref set --new makes a ref, and ref get prints the id it names"
  ak ref set me/topic "$v1" --new
  need_rc 0
  ak ref get me/topic
  need_rc 0
  need_out_eq "$v1"

  t R02 "ref set --new on a ref that exists fails (exit 1) and does not move it"
  ak ref set me/topic "$v2" --new
  need_rc 1
  ak ref get me/topic
  need_out_eq "$v1"

  t R03 "a ref can only name a memory that is in the store (exit 1 otherwise)"
  ak ref set me/other "$ZERO_ID" --new
  need_rc 1
  ak ref get me/other
  need_rc 1

  t R04 "ref set --expect moves the ref if the value is right"
  ak ref set me/topic "$v2" --expect "$v1"
  need_rc 0
  ak ref get me/topic
  need_out_eq "$v2"

  t R05 "ref set --expect with a wrong value fails (exit 1), names the real value, and does not move the ref"
  ak ref set me/topic "$v3" --expect "$v1"
  need_rc 1
  need_text_has "$v2"
  ak ref get me/topic
  need_out_eq "$v2"

  t R06 "ref set with no check moves the ref"
  ak ref set me/topic "$v3"
  need_rc 0
  ak ref get me/topic
  need_out_eq "$v3"

  t R07 "ref get --history prints the id now, then the older ids, newest first"
  ak ref get me/topic --history
  need_rc 0
  need_eq "$(nlines "$out")" 3 "number of ids"
  need_eq "$(line_n 1)" "$v3" "first line"
  need_eq "$(line_n 2)" "$v2" "second line"
  need_eq "$(line_n 3)" "$v1" "third line"

  t R08 "ref list prints one name and id for each ref, sorted by name"
  ak ref set zeta "$v1" --new
  ak ref set alpha/two "$v1" --new
  ak ref set alpha/one "$v1" --new
  ak ref list
  need_rc 0
  names=$(printf '%s\n' "$out" | awk '{ print $1 }' | tr '\n' ' ')
  need_eq "$names" "alpha/one alpha/two me/topic zeta " "ref names in order"
  printf '%s\n' "$out" | awk '{ print $2 }' | while read -r x; do
    printf '%s' "$x" | grep -E -q "$ID_RE" || echo bad
  done | grep -q bad && fail "a line of ref list has no id"

  t R09 "ref get of a ref that does not exist fails with exit 1"
  ak ref get no/such
  need_rc 1
  ak get --ref no/such
  need_rc 1

  t R10 "a ref name has parts of a-z 0-9 - _ . and no more (others are bad usage, exit 2)"
  for bad in "../x" "Bad Name" "a//b" "/abs" ".hidden" "Notes" "tail/" "$(printf 'x%.0s' $(seq 1 65))"; do
    ak ref set "$bad" "$v1" --new
    [ "$rc" = 2 ] || fail "ref set '$bad' exits $rc, expected 2"
  done
  ak ref set ok/a-b_c.1 "$v1" --new
  need_rc 0

  t R11 "one ref name cannot be the start of another (exit 1, and it says so)"
  ak ref set alpha "$v1" --new
  need_rc 1
  need_text_has "clash"
  ak ref set zeta/inner "$v1" --new
  need_rc 1

  t R12 "a ref keeps every older value in its history, more than 5"
  mk "history base"
  base=$id
  ak ref set me/long "$base" --new
  for i in 1 2 3 4 5 6 7; do
    mk "history step $i"
    ak ref set me/long "$id"
  done
  ak ref get me/long --history
  need_eq "$(nlines "$out")" 8 "number of ids in the history"
}
