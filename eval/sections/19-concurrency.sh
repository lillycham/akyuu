# shellcheck shell=bash
# shellcheck disable=SC2034,SC2154
# Section concurrency: several writers at once, as when several agents share a store.

# Run COUNT copies of a command at once. The command gets the number as $1.
# The exit codes go to $sandbox/par/rcN. Usage: par COUNT NAME ...
par() {
  local count=$1
  shift
  rm -rf "$sandbox/par"
  mkdir -p "$sandbox/par"
  local i=0
  while [ $i -lt "$count" ]; do
    i=$((i + 1))
    (
      "$@" "$i" >/dev/null 2>&1
      echo $? >"$sandbox/par/rc$i"
    ) &
  done
  wait
  par_ok=$(grep -l '^0$' "$sandbox"/par/rc* 2>/dev/null | wc -l | tr -d ' ')
  par_bad=$(grep -L '^0$' "$sandbox"/par/rc* 2>/dev/null | wc -l | tr -d ' ')
}

race_supersede() { "$bin" supersede race/a --expect "$base" --kind fact --agent "w$1" --body "writer $1"; }
race_append() { "$bin" append race/log --kind episode --agent "w$1" --body "parallel episode $1"; }
race_claim() { "$bin" add --kind fact --agent "t$1" --ref race/new --body "claimant $1"; }
race_add() { "$bin" add --kind fact --agent tester --body "distinct body $1"; }
race_note() { "$bin" note --cwd "$sandbox" "parallel note $1"; }

sec_concurrency() {
  use_root concurrency
  ak init
  ak add --kind fact --agent tester --ref race/a --body "base"
  base=$out

  t Z01 "8 writers supersede one ref with the same --expect: exactly one wins, the others exit 1"
  par 8 race_supersede
  need_eq "$par_ok" 1 "writers that won"
  need_eq "$par_bad" 7 "writers that lost"
  ak ref get race/a --history
  need_eq "$(nlines "$out")" 2 "ids in the history (the base and the winner)"

  t Z02 "the winner's text is the current text, and it is one of the writers' texts"
  ak get --ref race/a
  need_out_match 'writer [1-8]$'

  t Z03 "10 writers append to one log at once: every episode is in the log"
  ak append race/log --kind episode --agent tester --body "start"
  par 10 race_append
  need_eq "$par_ok" 10 "appends that succeeded"
  ak log race/log -n 100
  need_eq "$(grep -c '^sha256-' "$outf")" 11 "episodes in the log"

  t Z04 "6 writers make the same new ref at once: exactly one wins"
  par 6 race_claim
  need_eq "$par_ok" 1 "claimants that won"
  need_eq "$par_bad" 5 "claimants that lost"

  t Z05 "10 writers add different memories at once: all succeed, and the store is sound"
  par 10 race_add
  need_eq "$par_ok" 10 "adds that succeeded"
  ak verify
  need_rc 0

  t Z06 "10 notes at once to one log: every note is in the log"
  par 10 race_note
  need_eq "$par_ok" 10 "notes that succeeded"
  ak log me/log -n 100
  need_eq "$(grep -c '^sha256-' "$outf")" 10 "notes in the log"

  t Z07 "searches that run while memories are added do not fail"
  (
    i=0
    while [ $i -lt 15 ]; do
      i=$((i + 1))
      "$bin" add --kind fact --agent tester --body "writer memory $i about cheese" >/dev/null 2>&1
    done
  ) &
  writer=$!
  fails=0
  j=0
  while [ $j -lt 15 ]; do
    j=$((j + 1))
    "$bin" search cheese >/dev/null 2>&1 || fails=$((fails + 1))
  done
  wait "$writer"
  need_eq "$fails" 0 "searches that failed"
  ak verify
  need_rc 0
}
