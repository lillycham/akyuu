#!/usr/bin/env bash
# Automated checks of akyuu, for an agent or a person to run.
#
#   eval/checks.sh [OPTIONS] [SECTION ...]
#
# Options:
#   --bin PATH     The akyuu executable. The default is $AKYUU_BIN, then the
#                  akyuu on the PATH.
#   --report FILE  Also write one line for each check to FILE (tab separated:
#                  id, status, description).
#   --keep         Do not delete the sandbox at the end. Its path is printed.
#   --list         Print the id and the description of every check, and stop.
#   -h, --help     Print this text.
#
# With no SECTION, every section runs. The sections are, in order:
#
#   setup init memories refs supersede edges search logs context gc check
#   verify embed config mcp web seed backup concurrency robust
#
# Safety: the checks never touch your own store or settings. They run in a
# temporary directory that they delete at the end. They set HOME,
# XDG_CONFIG_HOME, AKYUU_ROOT and AKYUU_CONFIG to places in it, they unset
# every other AKYUU_* variable, and they stop at once if `akyuu config` does
# not show the sandbox as the store.
#
# Each check prints one line:
#
#   PASS   the check held
#   FAIL   it did not (the lines under it say what the command did)
#   XFAIL  a known issue is still there (it does not fail the run)
#   XPASS  a known issue seems to be fixed
#   SKIP   a tool that the check needs is missing
#
# The exit status is 0 if no check failed, 1 if one did, and 3 if the run
# could not start. The README in this directory says how to read the results.

set -u

here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib.sh
. "$here/lib.sh"

bin=${AKYUU_BIN:-akyuu}
keep=0
list=0
report=""
wanted=""

usage() {
  sed -n '2,/^set -u/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'
}

while [ $# -gt 0 ]; do
  case $1 in
  --bin)
    bin=$2
    shift 2
    ;;
  --report)
    report=$2
    shift 2
    ;;
  --keep)
    keep=1
    shift
    ;;
  --list)
    list=1
    shift
    ;;
  -h | --help)
    usage
    exit 0
    ;;
  -*)
    echo "unknown option: $1 (see --help)" >&2
    exit 3
    ;;
  *)
    wanted="$wanted $1"
    shift
    ;;
  esac
done

all_sections="setup init memories refs supersede edges search logs context gc check verify embed config mcp web seed backup concurrency robust"

for f in "$here"/sections/*.sh; do
  # shellcheck disable=SC1090
  . "$f"
done

if [ "$list" = 1 ]; then
  grep -h -E '^[[:space:]]*(x?t|skip) [A-Z][0-9]+ ' "$here"/sections/*.sh |
    sed -E 's/^[[:space:]]*(x?t|skip) ([A-Z][0-9]+) "([^"]*)".*/\2  \3/'
  exit 0
fi

for s in $wanted; do
  case " $all_sections " in
  *" $s "*) ;;
  *)
    echo "unknown section: $s (sections: $all_sections)" >&2
    exit 3
    ;;
  esac
done
[ -n "$wanted" ] || wanted=$all_sections

resolved=$(command -v "$bin" 2>/dev/null || true)
if [ -z "$resolved" ] || [ ! -x "$resolved" ]; then
  echo "cannot find the akyuu executable: $bin (use --bin PATH)" >&2
  exit 3
fi
case $resolved in
/*) bin=$resolved ;;
*) bin="$(pwd)/$resolved" ;;
esac

# --- the sandbox -----------------------------------------------------------

sandbox=$(mktemp -d "${TMPDIR:-/tmp}/akyuu-eval.XXXXXX") || exit 3
servers=""
cleanup() {
  for p in $servers; do kill "$p" 2>/dev/null; done
  if [ "$keep" = 1 ]; then
    echo "sandbox kept: $sandbox"
  else
    rm -rf "$sandbox"
  fi
}
trap cleanup EXIT

for v in $(env | sed -n 's/^\(AKYUU_[A-Za-z_]*\)=.*/\1/p'); do
  unset "$v"
done
export HOME="$sandbox/home"
export XDG_CONFIG_HOME="$HOME/.config"
export XDG_DATA_HOME="$HOME/.local/share"
mkdir -p "$HOME"
export AKYUU_ROOT="$sandbox/root"
export AKYUU_CONFIG="$sandbox/none.toml"
export GIT_CONFIG_GLOBAL=/dev/null
export GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME=eval GIT_AUTHOR_EMAIL=eval@example.invalid
export GIT_COMMITTER_NAME=eval GIT_COMMITTER_EMAIL=eval@example.invalid
mkdir -p "$AKYUU_ROOT"

outf="$sandbox/out"
errf="$sandbox/err"
if [ -n "$report" ]; then
  : >"$report" || exit 3
fi

# Stop at once if akyuu does not use the sandbox.
"$bin" config >"$outf" 2>"$errf" </dev/null
if ! grep -F -q "root = $AKYUU_ROOT" "$outf" || ! grep -q '^file: none' "$outf"; then
  echo "refusing to run: akyuu config does not show the sandbox as the store." >&2
  cat "$outf" "$errf" >&2
  exit 3
fi

echo "akyuu: $("$bin" --version 2>&1 | head -1)  ($bin)"
echo "sandbox: $sandbox"
echo

for s in $wanted; do
  echo "== $s"
  "sec_$s"
  finish
done
finish

echo
echo "passed $n_pass, failed $n_fail, known issues $n_xfail, fixed known issues $n_xpass, skipped $n_skip"
if [ "$n_fail" -gt 0 ]; then exit 1; fi
exit 0
