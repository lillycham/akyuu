# shellcheck shell=bash
# shellcheck disable=SC2034,SC2154
# Section setup: the executable, its help, and the safety of the sandbox.

# Run akyuu with no store set.
ak_noroot() {
  lastcmd="akyuu $* (AKYUU_ROOT unset)"
  env -u AKYUU_ROOT "$bin" "$@" >"$outf" 2>"$errf" </dev/null
  rc=$?
  out=$(cat "$outf")
  err=$(cat "$errf")
}

sec_setup() {
  use_root setup

  t S01 "--version prints the program name and a version"
  ak --version
  need_rc 0
  need_out_match '^akyuu [0-9]+(\.[0-9]+)+'

  t S02 "--help exits 0 and lists the main commands"
  ak --help
  need_rc 0
  for c in add get supersede amend ref append note log context search gc check verify mcp serve; do
    need_out_has "  $c "
  done

  t S03 "every command in --help has a help text of its own"
  ak --help
  commands=$(sed -n '/^Available commands:/,/^Exit codes/p' "$outf" | awk '/^  [a-z]/ { print $1 }')
  need_ne "$commands" "" "the list of commands is empty"
  for c in $commands; do
    ak "$c" --help
    [ "$rc" = 0 ] || fail "akyuu $c --help exits $rc"
    [ -n "$out" ] || fail "akyuu $c --help prints nothing"
  done

  t S04 "the sandbox is in effect: config names it as the store"
  ak config
  need_rc 0
  need_out_has "root = $AKYUU_ROOT"
  need_out_has "(\$AKYUU_ROOT)"

  t S05 "status of an empty store works and says it is empty"
  ak status
  need_rc 0
  need_out_has "memories: 0, refs: 0"

  t S06 "with no store set, a command that needs one exits 2 and says how to set it"
  ak_noroot ref list
  need_rc 2
  need_text_has "AKYUU_ROOT"

  t S07 "a root that does not exist makes a read fail with exit 1"
  ak --root "$sandbox/does-not-exist" ref list
  need_rc 1

  t S08 "an unknown command exits 2"
  ak frobnicate
  need_rc 2

  t S09 "an unknown option exits 2"
  ak ref list --frobnicate
  need_rc 2
}
