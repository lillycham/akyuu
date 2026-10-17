# shellcheck shell=bash
# shellcheck disable=SC2034,SC2154
# Section check: findings, reviews, and compare.

sec_check() {
  use_root check

  t K01 "check on a store with nothing wrong says so, and exits 0"
  mk "A single memory about gardens and tomatoes and the weather in spring."
  ak ref set me/clean "$id" --new
  ak check
  need_rc 0
  need_out_has "No findings."

  t K02 "a link to a memory that a newer memory replaces is a stale-link problem, and the text says to use about-ref"
  mk "the old text of a topic"
  tgt=$id
  ak ref set me/topic "$tgt" --new
  ak add --kind fact --agent tester --about "$tgt" --body "a note that links to the exact old text" --ref me/linker
  akin "the new text of a topic, written with other words" supersede me/topic --expect "$tgt" --kind fact --agent tester
  ak check
  need_rc 0
  need_out_has "[problem] stale-link"
  need_out_has "about-ref me/topic"
  ak check --kind stale-link
  need_out_has "stale-link"

  t K03 "an about-ref link is never a stale-link, because it follows the ref"
  use_root check-link
  mk "topic text one"
  ak ref set me/topic "$id" --new
  ak add --kind fact --agent tester --about-ref me/topic --body "a note that links to the topic" --ref me/linker
  akin "topic text two, written with other words" supersede me/topic --kind fact --agent tester
  ak check --kind stale-link
  need_rc 0
  need_out_has "No findings."

  t K04 "two memories that replace the same memory are a fork problem"
  use_root check-fork
  mk "origin text"
  origin=$id
  ak ref set me/origin "$origin" --new
  ak add --kind fact --agent tester --supersedes "$origin" --body "left branch" --ref me/left
  ak add --kind fact --agent tester --supersedes "$origin" --body "right branch" --ref me/right
  ak check --kind fork
  need_rc 0
  need_out_has "[problem] fork"
  need_out_has "$origin"

  t K05 "two memories with the same text (other kind) are a duplicate-body finding"
  use_root check-dup
  ak add --kind fact --agent tester --ref me/a --body "The deploy runs every night at three on the big server."
  ak add --kind note --agent tester --ref me/b --body "The deploy runs every night at three on the big server."
  ak check --kind duplicate-body
  need_rc 0
  need_out_has "duplicate-body"

  t K06 "two memories that share most of their text are a near-duplicate suggestion, and --near-threshold changes that"
  use_root check-near
  ak add --kind fact --agent tester --ref me/a --body "The deploy runs every night at three and takes about ten minutes to finish on the big server."
  ak add --kind fact --agent tester --ref me/b --body "The deploy runs every night at three and takes about ten minutes to finish on the big server!"
  ak check --kind near-duplicate
  need_out_has "[suggestion] near-duplicate"
  need_out_has "88%"
  ak check --kind near-duplicate --near-threshold 0.95
  need_out_has "No findings."

  t K07 "a memory that no ref, pin or edge keeps is an unreferenced suggestion"
  use_root check-unref
  mk "left alone"
  loose=$id
  ak check
  need_out_has "[suggestion] unreferenced"
  need_out_has "$loose"

  t K08 "a memory with many links is a hub, with --hub-degree"
  use_root check-hub
  mk "the hub"
  hub=$id
  ak ref set me/hub "$hub" --new
  for i in 1 2 3; do
    ak add --kind fact --agent tester --about "$hub" --ref "me/spoke$i" --body "spoke $i points at the hub"
  done
  ak check --kind hub --hub-degree 2
  need_out_has "hub"
  ak check --kind hub
  need_out_has "No findings."

  t K09 "a log with more episodes than --long-log is a long-log finding"
  use_root check-log
  for i in 1 2 3 4 5; do ak append me/log --kind episode --agent tester --body "episode $i"; done
  ak check --kind long-log --long-log 3
  need_out_has "long-log"
  ak check --kind long-log
  need_out_has "No findings."

  t K10 "--severity filters, and --strict exits 1 only when a problem is shown"
  use_root check-strict
  mk "origin"
  o=$id
  ak ref set me/o "$o" --new
  ak add --kind fact --agent tester --supersedes "$o" --body "one branch"
  ak add --kind fact --agent tester --supersedes "$o" --body "other branch"
  ak check --severity problem
  need_rc 0
  need_out_has "[problem]"
  need_out_lacks "[suggestion]"
  ak check --strict --severity problem
  need_rc 1
  ak check --strict --kind unreferenced
  need_rc 0

  t K11 "check --json prints a JSON array of findings with a kind, a severity, ids and a reason"
  ak check --json
  need_rc 0
  need_out_match '^\['
  need_out_has '"kind":"fork"'
  need_out_has '"severity":"problem"'
  need_out_has '"ids":['
  need_out_has '"why":'
  if command -v jq >/dev/null 2>&1; then
    jq -e 'type == "array" and length > 0' "$outf" >/dev/null || fail "jq does not accept the output as a non-empty array"
  fi

  t K12 "check changes nothing: the store and the refs are the same after it"
  before=$(find "$AKYUU_ROOT/store" "$AKYUU_ROOT/refs" -type f | sort | xargs cat | wc -c | tr -d ' ')
  ak check
  after=$(find "$AKYUU_ROOT/store" "$AKYUU_ROOT/refs" -type f | sort | xargs cat | wc -c | tr -d ' ')
  need_eq "$after" "$before" "bytes in store and refs"

  t K13 "check --kind with a kind that does not exist is bad usage (exit 2)"
  ak check --kind bogus
  need_rc 2

  t K14 "review hides a pair from check, reviews lists it, and unreview brings it back"
  use_root check-review
  ak add --kind fact --agent tester --ref me/a --body "The deploy runs every night at three and takes about ten minutes to finish on the big server."
  ra=$out
  ak add --kind fact --agent tester --ref me/b --body "The deploy runs every night at three and takes about ten minutes to finish on the big server!"
  rb=$out
  ak check
  need_out_has "near-duplicate"
  ak review "$ra" "$rb" --agent tester --note "same on purpose"
  need_rc 0
  ak check
  need_out_has "No findings."
  ak reviews
  need_rc 0
  need_out_has "$ra"
  need_out_has "by tester"
  need_out_has "same on purpose"
  ak unreview "$ra" "$rb"
  need_rc 0
  ak reviews
  need_out_empty
  ak check
  need_out_has "near-duplicate"

  t K15 "compare shows what each of two memories says that the other lacks"
  use_root check-compare
  ak add --kind fact --agent tester --body "The deploy runs every night at three."
  ca=$out
  ak add --kind fact --agent tester --body "Gardens need water in summer."
  cb=$out
  ak compare "$ca" "$cb"
  need_rc 0
  need_out_has "only in A"
  need_out_has "The deploy runs every night at three."
  need_out_has "only in B"
  need_out_has "Gardens need water in summer."
  ak compare --json "$ca" "$cb"
  need_rc 0
  need_out_has '"a":{'
  need_out_has '"b":{'

  xt K16 "a lost supersede race leaves nothing that check calls a problem" \
    "A supersede with a stale --expect fails, but it has already written its new memory. That memory supersedes the same old memory as the winner's, so check reports a [problem] fork until GC collects the orphan (after the grace period, 1 hour)."
  use_root check-race
  mk "base text of the topic"
  base=$id
  ak ref set me/race "$base" --new
  akin "the winner's text" supersede me/race --expect "$base" --kind fact --agent tester
  need_rc 0
  akin "the loser's text" supersede me/race --expect "$base" --kind fact --agent tester
  need_rc 1
  ak check --severity problem
  need_out_has "No findings."
}
