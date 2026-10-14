#!/usr/bin/env bash
# Check that the man pages describe the command line. Every command and every
# flag that `akyuu --help` shows must be named in man/akyuu.1.scd, as *name*.
# Both pages must render with scdoc and have no mandoc errors.
#
#   bash test/check-man.sh [AKYUU-BINARY] [MAN-DIRECTORY]
#
# The pages are written by hand, so this is what keeps them from drifting: a
# new command or flag fails the check until the page describes it.
set -euo pipefail
bin=${1:-akyuu}
dir=${2:-man}
page=$dir/akyuu.1.scd
fail=0

missing() {
  echo "man/akyuu.1.scd does not name $1"
  fail=1
}
# The commands that `akyuu WORDS... --help` lists.
commands() { "$bin" "$@" --help | awk '/^Available commands:/ { f = 1; next } f && /^  [a-z]/ { print $1 }'; }
# The flags that `akyuu WORDS... --help` shows, without -h and --help.
flags() { "$bin" "$@" --help | grep -oE '(^|[ ,])--?[a-z][a-z-]*' | sed 's/^[ ,]*//' | grep -vxE -- '-h|--help' | sort -u; }
command_and_flags() {
  grep -qE "\*$*[* ]" "$page" || missing "the command '$*'"
  for f in $(flags "$@"); do grep -qF -- "*$f*" "$page" || missing "$f (of '$*')"; done
}

for f in $(flags); do grep -qF -- "*$f*" "$page" || missing "$f"; done
for c in $(commands); do
  subs=$(commands "$c")
  if [ -n "$subs" ]; then
    for s in $subs; do command_and_flags "$c" "$s"; done
  else
    command_and_flags "$c"
  fi
done

for p in "$dir"/*.scd; do
  out=$(mktemp)
  scdoc <"$p" >"$out"
  mandoc -Tlint -W error "$out" || { echo "$p: mandoc reports errors"; fail=1; }
  rm -f "$out"
done

[ "$fail" = 0 ] && echo "man pages: every command and flag is described"
exit "$fail"
