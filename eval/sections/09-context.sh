# shellcheck shell=bash
# shellcheck disable=SC2034,SC2154
# Section context: what a session reads first, the tiers, and notes.

sec_context() {
  use_root context
  ak init
  ak add --kind fact --agent tester --ref me/profile --body "I am the profile text."
  ak add --kind fact --agent tester --ref me/proj --body "Project notes for proj."
  ak add --kind fact --agent tester --ref me/elsewhere --body "A ref that no tier names."
  long=$(awk 'BEGIN { for (i = 0; i < 400; i++) printf "padding words number %d. ", i }')
  ak add --kind fact --agent tester --ref me/big --body "$long"
  proj="$sandbox/work/proj"
  mkdir -p "$proj/sub" "$sandbox/work/other"
  printf 'always: policy/memory me/profile\nat %s: me/proj\nlog %s: me/projlog\nlog *: me/log\n' "$proj" "$proj" |
    "$bin" supersede policy/tiers --kind instruction --agent tester >/dev/null

  t X01 "context prints the tier always: the policy and the refs that the manifest names"
  ak context --cwd "$sandbox/work/other"
  need_rc 0
  need_out_has "tier: always"
  need_out_has "== policy/memory ("
  need_out_has "How to use this store for memory"
  need_out_has "== me/profile ("
  need_out_has "I am the profile text."

  t X02 "context ends with the names of the refs that it did not show"
  need_out_has "other refs:"
  need_out_has "me/elsewhere"
  need_out_lacks "me/profile,"

  t X03 "a line 'at DIR:' adds refs for a session in DIR or below it, and for no other directory"
  ak context --cwd "$proj/sub"
  need_rc 0
  need_out_has "Project notes for proj."
  ak context --cwd "$sandbox/work/other"
  need_out_lacks "Project notes for proj."

  t X04 "note writes an episode to the log that the manifest names for the directory"
  ak note --cwd "$proj/sub" "a note inside the project"
  need_rc 0
  need_out_match '^noted in me/projlog sha256-[0-9a-f]{64}$'
  ak log me/projlog --full
  need_out_has "a note inside the project"
  need_out_has "note"

  t X05 "note in another directory goes to the log for every directory"
  ak note --cwd "$sandbox/work/other" "a note elsewhere"
  need_rc 0
  need_out_has "noted in me/log "
  ak log me/log --full
  need_out_has "a note elsewhere"
  ak log me/projlog --full
  need_out_lacks "a note elsewhere"

  t X06 "the words of a note can be several arguments, and the agent comes from AKYUU_AGENT"
  lastcmd="AKYUU_AGENT=noter akyuu note several words"
  env AKYUU_AGENT=noter "$bin" note --cwd "$sandbox/work/other" several words here >"$outf" 2>"$errf" </dev/null
  rc=$?
  out=$(cat "$outf")
  need_rc 0
  ak log me/log --full -n 1
  need_out_has "noter"
  need_out_has "several words here"

  t X07 "context --tier with a tier that the manifest lacks fails (exit 1) and lists the tiers"
  ak context --tier nothere
  need_rc 1
  need_text_has "always"

  t X08 "context --ref adds a ref"
  ak context --cwd "$sandbox/work/other" --ref me/elsewhere
  need_rc 0
  need_out_has "A ref that no tier names."

  t X09 "with --page, a memory too long for a page is shown as its first line, with how to read the rest"
  : >"$sandbox/pages.txt"
  for p in 1 2 3 4 5 6; do
    ak context --cwd "$sandbox/work/other" --ref me/big --budget 2000 --page $p
    need_rc 0
    cat "$outf" >>"$sandbox/pages.txt"
  done
  grep -F -q "== me/big (" "$sandbox/pages.txt" || fail "me/big is on no page"
  grep -F -q "padding words number 399" "$sandbox/pages.txt" && fail "the whole long memory was printed"
  grep -F -q "too long for one page" "$sandbox/pages.txt" || fail "no note that the memory is too long"

  t X10 "--budget splits the output into pages, and a page after the last prints nothing"
  ak context --cwd "$sandbox/work/other" --budget 600 --page 1
  need_rc 0
  need_out_has "more on page 2"
  ak context --cwd "$sandbox/work/other" --budget 600 --page 2
  need_rc 0
  need_out_has "other refs:"
  ak context --cwd "$sandbox/work/other" --budget 600 --page 99
  need_rc 0
  need_out_empty

  t X11 "a store with no manifest gives an error that says what to do, not a crash"
  use_root context-empty
  ak context
  need_ne "$rc" 139 "the program crashed"
  [ "$rc" = 0 ] || [ "$rc" = 1 ] || fail "exit code $rc, expected 0 or 1"
}
