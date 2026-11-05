# shellcheck shell=bash
# shellcheck disable=SC2034,SC2154
# Section memories: add and get, ids, the format, and errors.

sec_memories() {
  use_root memories

  t M01 "add prints the id of the new memory"
  ak add --kind fact --agent tester --body "The first memory."
  need_rc 0
  need_id "$out"
  m1=$out

  t M02 "get prints headers, a blank line, and the body"
  ak get "$m1"
  need_rc 0
  need_eq "$(line_n 1)" "kind: fact"
  printf '%s' "$(line_n 2)" | grep -E -q '^created: [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' ||
    fail "the second line is not a created header: $(line_n 2)"
  need_eq "$(line_n 3)" "agent: tester"
  need_eq "$(line_n 4)" ""
  need_eq "$(line_n 5)" "The first memory."

  t M03 "the id is the SHA-256 of the bytes that get prints"
  ak get "$m1"
  need_eq "$(sha256_file "$outf")" "${m1#sha256-}" "SHA-256 of the output"

  t M04 "get takes the start of an id, with or without sha256-"
  ak get "${m1:7:8}"
  need_rc 0
  need_out_has "The first memory."
  ak get "${m1:0:15}"
  need_rc 0
  need_out_has "The first memory."

  t M05 "get --with-id puts the id on a first line, then the memory"
  ak get --with-id "$m1"
  need_rc 0
  need_eq "$(line_n 1)" "id: $m1"
  need_eq "$(line_n 2)" "kind: fact"

  t M06 "an id start of fewer than 4 characters is bad usage (exit 2)"
  ak get "${m1:7:3}"
  need_rc 2

  t M07 "text that is not an id is bad usage (exit 2)"
  ak get not-an-id
  need_rc 2

  t M08 "an id that no memory has fails with exit 1"
  ak get "$ZERO_ID"
  need_rc 1
  ak get 00000000
  need_rc 1

  t M09 "the body can come from --body, from standard input, or from a file"
  ak add --kind fact --agent tester --body "from the option"
  need_rc 0
  ak get "$out"
  need_out_has "from the option"
  akin "from standard input" add --kind fact --agent tester
  need_rc 0
  ak get "$out"
  need_out_has "from standard input"
  printf 'from a file' >"$sandbox/body.txt"
  ak add --kind fact --agent tester --file "$sandbox/body.txt"
  need_rc 0
  ak get "$out"
  need_out_has "from a file"
  ak add --kind fact --agent tester -f "$sandbox/body.txt"
  need_rc 0

  t M10 "a body comes back byte for byte (blank lines, trailing newline, unicode, CR, fake headers)"
  n=0
  for body in \
    "plain" \
    "with a newline at the end
" \
    "two

blank lines" \
    "  spaces at both ends  " \
    "kind: fact
about: $ZERO_ID

headers inside the body" \
    "caf$(printf '\303\251') $(printf '\342\230\203') $(printf '\360\237\220\260')" \
    "$(printf 'carriage\rreturn\r\nand line feed')"; do
    n=$((n + 1))
    printf '%s' "$body" >"$sandbox/rt$n.txt"
    ak add --kind fact --agent tester --file "$sandbox/rt$n.txt"
    [ "$rc" = 0 ] || {
      fail "case $n: add exits $rc"
      continue
    }
    ak get "$out"
    tail -n +5 "$outf" >"$sandbox/rt$n.got"
    cmp -s "$sandbox/rt$n.txt" "$sandbox/rt$n.got" || fail "case $n: the body changed"
  done

  t M11 "a body of one megabyte comes back byte for byte"
  awk 'BEGIN { for (i = 0; i < 20000; i++) printf "line %d of a large body, with some words in it.\n", i }' >"$sandbox/big.txt"
  ak add --kind fact --agent tester --file "$sandbox/big.txt"
  need_rc 0
  ak get "$out"
  tail -n +5 "$outf" >"$sandbox/big.got"
  cmp -s "$sandbox/big.txt" "$sandbox/big.got" || fail "the large body changed"

  t M12 "edges are headers: about, derived-from, refines and supersedes"
  mk "target" 
  tgt=$id
  ak add --kind fact --agent tester --about "$tgt" --derived-from "$tgt" --refines "$tgt" --supersedes "$tgt" --body "has four edges"
  need_rc 0
  ak get "$out"
  need_out_has "about: $tgt"
  need_out_has "derived-from: $tgt"
  need_out_has "refines: $tgt"
  need_out_has "supersedes: $tgt"

  t M13 "an edge to an id that is not in the store is allowed (a dangling target)"
  ak add --kind fact --agent tester --about "$ZERO_ID" --body "points at nothing"
  need_rc 0
  ak get "$out"
  need_out_has "about: $ZERO_ID"

  t M14 "a missing --kind or --agent is bad usage (exit 2)"
  ak add --agent tester --body x
  need_rc 2
  ak add --kind fact --body x
  need_rc 2

  t M15 "a kind or an agent that has a line break or spaces at its ends is refused (exit 2)"
  ak add --kind "two
lines" --agent tester --body x
  need_rc 2
  ak add --kind " fact" --agent tester --body x
  need_rc 2
  ak add --kind fact --agent "tester " --body x
  need_rc 2

  t M16 "add with --ref makes the ref, and refuses a ref that exists"
  ak add --kind fact --agent tester --ref me/first --body "under a ref"
  need_rc 0
  r1=$out
  ak ref get me/first
  need_out_eq "$r1"
  ak add --kind fact --agent tester --ref me/first --body "again"
  need_rc 1
  ak ref get me/first
  need_out_eq "$r1"

  t M17 "an unknown id in --about-ref's place: a ref that does not exist is refused"
  ak add --kind fact --agent tester --about-ref no/such/ref --body x
  need_rc 1

  xt M18 "giving both --body and --file is refused with an error that names the two options" \
    "the error is 'Invalid option -f' with the usage of the top-level akyuu, and it does not say that --body and --file exclude each other"
  printf 'file text' >"$sandbox/both.txt"
  ak add --kind fact --agent tester --body X -f "$sandbox/both.txt"
  [ "$rc" != 0 ] || fail "both options were accepted"
  need_text_has "--body"
}
