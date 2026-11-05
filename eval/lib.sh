# shellcheck shell=bash
# shellcheck disable=SC2034,SC2154
# Helpers for checks.sh. Source this file; do not run it.
#
# It needs bash 3.2 or newer (the bash that macOS ships), and no other tool
# than the ones that every POSIX system has. The checks use curl and git where
# they test the web view and versioning, and skip those checks if the tool is
# missing.

n_pass=0
n_fail=0
n_xfail=0
n_xpass=0
n_skip=0
cur_id=""
cur_desc=""
cur_fail=""
cur_known=""

ID_RE='^sha256-[0-9a-f]{64}$'
ZERO_ID=sha256-0000000000000000000000000000000000000000000000000000000000000000

# --- running akyuu ---------------------------------------------------------

# Run akyuu with no input. Sets: out, err, rc, and the files $outf, $errf.
ak() {
  lastcmd="akyuu $*"
  "$bin" "$@" >"$outf" 2>"$errf" </dev/null
  rc=$?
  out=$(cat "$outf")
  err=$(cat "$errf")
}

# Run akyuu with a text on the standard input: akin TEXT ARG...
akin() {
  local text=$1
  shift
  lastcmd="akyuu $* (with input)"
  printf '%s' "$text" | "$bin" "$@" >"$outf" 2>"$errf"
  rc=$?
  out=$(cat "$outf")
  err=$(cat "$errf")
}

# Add a memory: mk BODY [ARG...]. The kind is fact and the agent is tester.
# Sets $id to the new id (or to nothing, if the command failed).
mk() {
  local body=$1
  shift
  ak add --kind fact --agent tester --body "$body" "$@"
  id=""
  if [ "$rc" = 0 ]; then id=$out; fi
}

# Use a fresh, empty store for the checks that follow.
use_root() {
  export AKYUU_ROOT="$sandbox/$1"
  rm -rf "$AKYUU_ROOT"
  mkdir -p "$AKYUU_ROOT"
}

# The SHA-256 of a file, as 64 hex digits.
sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  else
    shasum -a 256 "$1" | cut -d' ' -f1
  fi
}

# The number of lines of a text (0 for the empty text).
nlines() {
  if [ -z "$1" ]; then echo 0; else printf '%s\n' "$1" | wc -l | tr -d ' '; fi
}

# --- reporting -------------------------------------------------------------

finish() {
  [ -n "$cur_id" ] || return 0
  local status
  if [ -n "$cur_known" ]; then
    if [ -z "$cur_fail" ]; then
      status=XPASS
      n_xpass=$((n_xpass + 1))
    else
      status=XFAIL
      n_xfail=$((n_xfail + 1))
    fi
  elif [ -z "$cur_fail" ]; then
    status=PASS
    n_pass=$((n_pass + 1))
  else
    status=FAIL
    n_fail=$((n_fail + 1))
  fi
  printf '%-5s %s  %s\n' "$status" "$cur_id" "$cur_desc"
  case $status in
  FAIL) printf '%s\n' "$cur_fail" ;;
  XFAIL) printf '      known issue: %s\n' "$cur_known" ;;
  XPASS) printf '      the known issue looks fixed: %s\n      Remove the xt marker in checks.sh.\n' "$cur_known" ;;
  esac
  if [ -n "${report:-}" ]; then
    printf '%s\t%s\t%s\n' "$cur_id" "$status" "$cur_desc" >>"$report"
  fi
  cur_id=""
}

# Start a check: t ID "what it checks".
t() {
  finish
  cur_id=$1
  cur_desc=$2
  cur_fail=""
  cur_known=""
  rc=""
  out=""
  err=""
  lastcmd=""
}

# Start a check of a known issue: xt ID "what it checks" "what is wrong".
# The check is reported as XFAIL while the issue is there, and as XPASS when
# it is fixed. XFAIL does not make the run fail.
xt() {
  t "$1" "$2"
  cur_known=$3
}

# Skip a check: skip ID "what it checks" "why".
skip() {
  finish
  n_skip=$((n_skip + 1))
  printf 'SKIP  %s  %s (%s)\n' "$1" "$2" "$3"
  if [ -n "${report:-}" ]; then
    printf '%s\tSKIP\t%s\n' "$1" "$2" >>"$report"
  fi
}

# Record a failed condition for the current check, with the last command.
fail() {
  if [ -z "$cur_fail" ]; then
    cur_fail="      command: ${lastcmd:-none}
      exit code: ${rc:-none}
      output: $(printf '%s' "$out" | head -5 | tr '\n' '|' | cut -c1-300)
      errors: $(printf '%s' "$err" | head -3 | tr '\n' '|' | cut -c1-300)"
  fi
  cur_fail="$cur_fail
      - $1"
}

# --- assertions ------------------------------------------------------------

need_rc() { [ "$rc" = "$1" ] || fail "exit code $rc, expected $1"; }
need_out_has() { grep -F -q -- "$1" "$outf" || fail "the output lacks: $1"; }
need_out_lacks() { ! grep -F -q -- "$1" "$outf" || fail "the output has, and must not: $1"; }
need_out_eq() { [ "$out" = "$1" ] || fail "the output is not: $1"; }
need_out_empty() { [ -z "$out" ] || fail "the output is not empty"; }
need_out_match() { grep -E -q -- "$1" "$outf" || fail "the output does not match: $1"; }
need_err_has() { grep -F -q -- "$1" "$errf" || fail "the error text lacks: $1"; }
# The text on either stream (a note can go to one or the other).
need_text_has() {
  if ! grep -F -q -- "$1" "$outf" && ! grep -F -q -- "$1" "$errf"; then
    fail "neither the output nor the error text has: $1"
  fi
}
need_id() { printf '%s' "$1" | grep -E -q "$ID_RE" || fail "not an id: $1"; }
need_eq() { [ "$1" = "$2" ] || fail "${3:-values differ}: '$1' is not '$2'"; }
need_ne() { [ "$1" != "$2" ] || fail "${3:-values equal}: '$1'"; }
need_true() { "$@" || fail "condition false: $*"; }
need_file() { [ -e "$1" ] || fail "no such file: $1"; }
need_no_file() { [ ! -e "$1" ] || fail "file exists, and must not: $1"; }
# The nth line of the output (1 is the first).
line_n() { sed -n "${1}p" "$outf"; }

# Run a command with changes to the environment: ake VAR=value ... COMMAND ARG...
# (or -u VAR to unset one). Like ak, it sets out, err and rc.
ake() {
  lastcmd="env $*"
  env "$@" >"$outf" 2>"$errf" </dev/null
  rc=$?
  out=$(cat "$outf")
  err=$(cat "$errf")
}
