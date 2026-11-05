# shellcheck shell=bash
# shellcheck disable=SC2034,SC2154
# Section logs: episodes that are added and never replaced, and summaries of them.

sec_logs() {
  use_root logs

  t L01 "append makes a log, and log lists the episodes newest first"
  ak append me/episodes --kind episode --agent tester --body "episode number 1"
  need_rc 0
  e1=$out
  need_id "$e1"
  ak append me/episodes --kind episode --agent tester --body "episode number 2"
  e2=$out
  ak append me/episodes --kind episode --agent tester --body "episode number 3"
  e3=$out
  ak ref get me/episodes
  need_out_eq "$e3"
  ak log me/episodes
  need_rc 0
  need_eq "$(nlines "$out")" 3 "number of episodes"
  need_eq "$(line_n 1 | cut -d' ' -f1)" "$e3" "newest first"
  need_eq "$(line_n 3 | cut -d' ' -f1)" "$e1" "oldest last"
  need_out_has "episode number 2"
  need_out_has "tester"

  t L02 "each episode follows the one before it, and the first follows none"
  ak neighbours "$e3"
  need_out_has "out follows $e2"
  ak neighbours "$e2"
  need_out_has "out follows $e1"
  ak neighbours "$e1"
  need_out_lacks "out follows"

  t L03 "no episode is replaced: all of them can be read, and none supersedes another"
  for e in "$e1" "$e2" "$e3"; do
    ak get "$e"
    [ "$rc" = 0 ] || fail "get $e exits $rc"
  done
  ak neighbours "$e3"
  need_out_lacks "supersedes"

  t L04 "log -n limits the count, and a line says where the rest starts"
  ak log me/episodes -n 2
  need_rc 0
  need_out_has "more: $e1"
  need_eq "$(grep -c '^sha256-' "$outf")" 2 "episodes shown"

  t L05 "log --full prints the bodies too"
  ak log me/episodes --full -n 1
  need_rc 0
  need_out_has "  episode number 3"

  t L06 "log --since keeps the episodes of the last period, and a bad duration is bad usage (exit 2)"
  ak log me/episodes --since 1h
  need_rc 0
  need_eq "$(grep -c '^sha256-' "$outf")" 3 "episodes in the last hour"
  ak log me/episodes --since 5x
  need_rc 2

  t L07 "log of a ref that does not exist fails (exit 1)"
  ak log no/such
  need_rc 1

  t L08 "log --todo says nothing needs a summary for a short log"
  ak log me/episodes --todo
  need_rc 0
  need_out_has "Nothing needs a summary"

  i=3
  while [ $i -lt 22 ]; do
    i=$((i + 1))
    ak append me/episodes --kind episode --agent tester --body "episode number $i: something happened"
  done

  t L09 "log --todo lists the oldest run of 8 episodes that have no summary"
  ak log me/episodes --todo
  need_rc 0
  need_out_has "level 1: 8 memories"
  need_eq "$(grep -c '^  sha256-' "$outf")" 8 "episodes listed"
  need_out_has "episode number 1"
  need_out_has "episode number 8: something happened"
  need_out_lacks "episode number 9"
  srcs=""
  for s in $(grep '^  sha256-' "$outf" | awk '{ print $1 }'); do srcs="$srcs --source $s"; done

  t L10 "summarise records a summary in the log NAME.l1, and the log keeps every episode"
  # shellcheck disable=SC2086
  ak summarise me/episodes $srcs --agent tester --body "Episodes 1 to 8: things happened."
  need_rc 0
  sum=$out
  need_id "$sum"
  ak ref get me/episodes.l1
  need_out_eq "$sum"
  ak log me/episodes -n 100
  need_eq "$(grep -c '^sha256-' "$outf")" 22 "episodes still in the log"
  ak get "$sum"
  need_out_has "kind: summary"
  ak neighbours "$sum"
  need_eq "$(grep -c '^out derived-from' "$outf")" 8 "derived-from edges"

  t L11 "after the summary, log --todo has nothing for those episodes"
  ak log me/episodes --todo
  need_rc 0
  need_out_has "Nothing needs a summary"

  t L12 "log --resolution shows recent episodes whole and the old stretch as its summary"
  ak log me/episodes --resolution
  need_rc 0
  need_out_has "level 1  8 episodes"
  need_out_has "Episodes 1 to 8: things happened."
  need_out_has "episode number 22: something happened"
  need_out_lacks "episode number 3"
  need_out_has "unfold"

  t L13 "unfold prints the sources of a summary, newest first, whole"
  ak unfold "$sum"
  need_rc 0
  need_eq "$(grep -c '^sha256-' "$outf")" 8 "sources"
  need_eq "$(line_n 1 | cut -d' ' -f1)" "$("$bin" log me/episodes -n 100 | sed -n 15p | cut -d' ' -f1)" "newest source first (episode 8)"
  need_out_has "episode number 8: something happened"
  need_out_has "episode number 1"

  t L14 "log --resolution --budget: too small is bad usage (exit 2), too small for the log fails loudly (exit 1)"
  ak log me/episodes --resolution --budget 100
  need_rc 2
  ak log me/episodes --resolution --budget 1500
  need_rc 1
  need_text_has "does not fit"
  need_out_empty

  t L15 "log --resolution --budget with room prints the log"
  ak log me/episodes --resolution --budget 20000
  need_rc 0
  need_out_has "episode number 22"

  t L16 "summarise refuses sources that are not the oldest stretch without a summary"
  newest=$("$bin" log me/episodes -n 8 | grep '^sha256-' | awk '{ print $1 }')
  bad=""
  for s in $newest; do bad="$bad --source $s"; done
  # shellcheck disable=SC2086
  ak summarise me/episodes $bad --agent tester --body "wrong stretch"
  need_ne "$rc" 0 "summarise accepted a stretch that is not the oldest"
}
