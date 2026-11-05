# shellcheck shell=bash
# shellcheck disable=SC2034,SC2154
# Section search: words, stems, spellings, ranking, and the memories near a hit.

sec_search() {
  use_root search
  ak add --kind fact --agent tester --ref me/garden --body "Water the tomatoes every second day. The basil needs full sun."
  garden=$out
  ak add --kind fact --agent tester --ref me/cooking --derived-from "$garden" --body "Pesto is made from basil, pine nuts and olive oil."
  pesto=$out
  ak add --kind fact --agent tester --about "$garden" --body "Cafe notes: the café on the corner sells good coffee."
  cafe=$out
  ak add --kind preference --agent tester --ref me/lang --body "I prefer Haskell for command line tools."
  hask1=$out

  t Q01 "a search finds a memory by a word, marks the word, and names the ref that holds it"
  ak search basil
  need_rc 0
  need_out_has "$pesto"
  need_out_has "[basil]"
  need_out_has "held by me/cooking"
  need_out_has "$garden"
  need_out_has "held by me/garden"

  t Q02 "the search ignores case"
  ak search TOMATOES
  need_rc 0
  need_out_has "$garden"

  t Q03 "the search matches word stems"
  ak search tomato
  need_out_has "$garden"
  ak search watering
  need_out_has "$garden"

  t Q04 "several words must all be in the memory"
  ak search basil pesto
  need_out_has "$pesto"
  need_out_lacks "held by me/garden"

  t Q05 "a word that has an accent matches without it, and with it"
  ak search café
  need_out_has "$cafe"
  ak search cafe
  need_out_has "$cafe"

  t Q06 "a word that no memory has is tried as the start of a word, and the output says so"
  ak search hask
  need_rc 0
  need_out_has "$hask1"
  need_text_has "start of a word"

  t Q07 "a near spelling finds the memory"
  ak search haskel
  need_rc 0
  need_out_has "$hask1"

  t Q08 "a search with no hit exits 0 and prints nothing"
  ak search zzzqqq
  need_rc 0
  need_out_empty

  t Q09 "-n and --limit cap the number of hits"
  ak search -n 1 basil
  need_rc 0
  need_eq "$(grep -c '^sha256-.*  ' "$outf")" 1 "hits with -n 1"
  ak search --limit 1 basil
  need_eq "$(grep -c '^sha256-.*  ' "$outf")" 1 "hits with --limit 1"
  ak search -n 0 basil
  need_rc 2

  t Q10 "a superseded memory is still found, and says which memory replaces it; the current one comes first"
  hask2=$("$bin" amend me/lang --from "command line tools" --to "tools of every kind" 2>/dev/null)
  ak search haskell
  need_rc 0
  need_out_has "$hask1"
  need_out_has "superseded by $hask2"
  first=$(grep -n "$hask2" "$outf" | head -1 | cut -d: -f1)
  second=$(grep -n "$hask1" "$outf" | head -1 | cut -d: -f1)
  [ -n "$first" ] && [ -n "$second" ] && [ "$first" -lt "$second" ] || fail "the current memory is not before the old one"
  need_out_has "held by me/lang"

  t Q11 "--hops 0 shows no neighbours, and the default shows the memories one edge away"
  ak search --hops 0 tomatoes
  need_rc 0
  need_out_lacks "context:"
  ak search tomatoes
  need_out_has "context:"
  need_out_has "$pesto"
  need_out_has "$cafe"

  t Q12 "--follow shows only the edges of that kind"
  ak search --follow about tomatoes
  need_rc 0
  need_out_has "$cafe"
  need_out_lacks "$pesto"
  ak search --follow derived-from tomatoes
  need_out_has "$pesto"
  need_out_lacks "$cafe"

  t Q13 "--mode text works, and an unknown mode is bad usage (exit 2)"
  ak search --mode text basil
  need_rc 0
  need_out_has "$pesto"
  ak search --mode bogus basil
  need_rc 2

  t Q14 "--mode meaning with no embedding profile falls back to words, and says so"
  ak search --mode meaning basil
  need_rc 0
  need_out_has "$pesto"
  need_text_has "No embedding profile"

  t Q15 "a search with no words is bad usage (exit 2)"
  ak search
  need_rc 2

  t Q16 "characters that have a meaning in a query do not break the search"
  for q in 'foo-bar' '"unterminated' 'AND' 'basil OR' 'NEAR(' '*' 'col:basil' '^basil' "it's" 'a\b' '()'; do
    ak search "$q"
    [ "$rc" = 0 ] || fail "search '$q' exits $rc"
  done
  ak search "pine-nuts"
  need_out_has "$pesto"

  t Q17 "a new memory can be found at once, and the new text of an amended memory is found as current"
  ak add --kind fact --agent tester --body "The quokka lives on Rottnest Island."
  nq=$out
  ak search quokka
  need_out_has "$nq"
  ak amend me/garden --from tomatoes --to courgettes
  need_rc 0
  ak search courgettes
  need_out_has "held by me/garden"

  t Q18 "search covers the text of a memory that has many words and a long line"
  awk 'BEGIN { for (i = 0; i < 3000; i++) printf "word%d ", i; print "needleinhaystack" }' >"$sandbox/long.txt"
  ak add --kind fact --agent tester --file "$sandbox/long.txt"
  ak search needleinhaystack
  need_rc 0
  need_out_has "needleinhaystack"
}
