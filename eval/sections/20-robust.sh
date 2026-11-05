# shellcheck shell=bash
# shellcheck disable=SC2034,SC2154
# Section robust: odd input, and a store of a few hundred memories.

sec_robust() {
  use_root robust

  t O01 "two memories whose ids start the same: a short id is refused (exit 1), and both ids are listed"
  mk "source of the plants"
  src=$id
  f=$(ls "$AKYUU_ROOT"/store/*/"$src".md)
  h1=abcd$(printf '0%.0s' $(seq 1 60))
  h2=abcd$(printf '1%.0s' $(seq 1 60))
  mkdir -p "$AKYUU_ROOT/store/ab"
  cp "$f" "$AKYUU_ROOT/store/ab/sha256-$h1.md"
  cp "$f" "$AKYUU_ROOT/store/ab/sha256-$h2.md"
  ak get abcd
  need_rc 1
  need_text_has "More than one memory"
  need_text_has "sha256-$h1"
  need_text_has "sha256-$h2"
  rm -f "$AKYUU_ROOT/store/ab/sha256-$h1.md" "$AKYUU_ROOT/store/ab/sha256-$h2.md"

  t O02 "a memory with a long line, many lines, or non-ASCII words is stored and found"
  awk 'BEGIN { for (i = 0; i < 5000; i++) printf "w%d ", i; print "" }' >"$sandbox/line.txt"
  ak add --kind fact --agent tester --file "$sandbox/line.txt"
  need_rc 0
  ak add --kind fact --agent tester --body "naïve façade, Zürich, Ελληνικά, 日本語, emoji 🐰"
  need_rc 0
  ak search Zürich
  need_rc 0
  need_out_has "Zürich"

  t O03 "a kind and an agent with non-ASCII letters are accepted and come back"
  ak add --kind "décision" --agent "agente-ñ" --body "unicode headers"
  need_rc 0
  ak get "$out"
  need_out_has "kind: décision"
  need_out_has "agent: agente-ñ"

  t O04 "a few hundred memories: verify, search, check, gc --dry-run and reindex all work"
  i=0
  while [ $i -lt 200 ]; do
    i=$((i + 1))
    "$bin" add --kind fact --agent tester --body "bulk memory number $i, about topic$((i % 17)) and widget$i" >/dev/null 2>&1 || {
      fail "add number $i failed"
      break
    }
  done
  ak verify
  need_rc 0
  ak search widget150
  need_rc 0
  need_out_has "widget150"
  ak check
  need_rc 0
  ak gc --dry-run
  need_rc 0
  ak reindex
  need_rc 0
  ak search widget150
  need_out_has "widget150"

  t O05 "get of a memory by ref and by id print the same bytes"
  ak add --kind fact --agent tester --ref me/same --body "read two ways"
  byid=$out
  ak get "$byid"
  cp "$outf" "$sandbox/byid.txt"
  ak get --ref me/same
  cmp -s "$outf" "$sandbox/byid.txt" || fail "get --ref and get ID differ"
  t O06 "an add that is killed in the middle (kill -9) leaves no damaged memory: verify is clean afterwards"
  awk 'BEGIN { for (i = 0; i < 100000; i++) printf "crash test line %d with some padding words to make it long\n", i }' >"$sandbox/huge.txt"
  i=0
  while [ $i -lt 15 ]; do
    i=$((i + 1))
    "$bin" add --kind fact --agent tester --file "$sandbox/huge.txt" >/dev/null 2>&1 &
    pid=$!
    disown "$pid" 2>/dev/null
    sleep "0.0$((i % 9 + 1))"
    kill -9 "$pid" 2>/dev/null
  done
  sleep 0.3
  ak verify
  need_rc 0
  ak search widget150
  need_rc 0
  ak gc --dry-run
  need_rc 0

  xt O07 "control characters in a memory do not reach the terminal raw through get and search" \
    "get, search, context and the MCP results print ESC and BEL bytes as they are, so a memory can change the terminal title, clear the screen or hide text"
  use_root robust-ansi
  ak add --kind fact --agent tester --ref hx/ansi --body "red $(printf '\033[31m')RED$(printf '\033[0m') title $(printf '\033]0;TITLE\007') clear $(printf '\033[2J') end"
  ak get --ref hx/ansi
  esc=$(printf '\033')
  ! grep -q "$esc" "$outf" || fail "get printed a raw ESC byte"
  ak search red
  ! grep -q "$esc" "$outf" || fail "search printed a raw ESC byte"
}
