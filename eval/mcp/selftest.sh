#!/usr/bin/env bash
# Self-test of the MCP evaluation harness. It runs scenarios S2 and S3 on both
# tool sets with a fake agent (fake-claude.sh), and checks the pipeline: the
# proxy, the other writer, the verifiers, the measures and the tally. It uses
# no model and costs nothing.
#
#   eval/mcp/selftest.sh AKYUU

set -u
here=$(cd "$(dirname "$0")" && pwd)
bin=${1:-}
[ -n "$bin" ] && [ -x "$bin" ] || {
  echo "usage: selftest.sh AKYUU" >&2
  exit 2
}
out=$(mktemp -d "${TMPDIR:-/tmp}/akyuu-mcp-selftest.XXXXXX")
trap 'rm -rf "$out"' EXIT

failures=0
check() { # check DESCRIPTION CONDITION...
  local d=$1
  shift
  if "$@"; then
    echo "ok    $d"
  else
    echo "FAIL  $d"
    failures=$((failures + 1))
  fi
}

"$here/run.sh" --bin "$bin" --claude "$here/fake-claude.sh" --skip-probe --runs 1 --scenarios "S2 S3" --sets "ordinary topic" --out "$out" run >"$out/run.log" 2>&1
tsv="$out/results.tsv"
cell() { awk -F'\t' -v s="$1" -v n="$2" -v c="$3" '$1 == s && $2 == n { print $c }' "$tsv"; }

check "four rows" test "$(($(wc -l <"$tsv") - 1))" = 4
for set in ordinary topic; do
  for sn in S2 S3; do
    check "$sn on $set: no check of the verifier failed" test "$(cell $set $sn 5)" = 0
    check "$sn on $set: the agent finished" test "$(cell $set $sn 11)" = ok
    check "$sn on $set: the calls were counted" test "$(cell $set $sn 6)" -gt 0
  done
  check "S3 on $set: the other writer ran" test "$(cell $set S3 12)" = yes
done
# The ordinary tools meet the other writer with a stale version: one error.
check "S3 on ordinary: one tool error, from the stale write" test "$(cell ordinary S3 7)" = 1
check "S3 on topic: no tool error" test "$(cell topic S3 7)" = 0
check "S2 on ordinary: no tool error" test "$(cell ordinary S2 7)" = 0
check "the tally has a row for each cell" test "$("$here/tally.sh" "$tsv" | wc -l | tr -d ' ')" = 5
check "the tally counts every run as clean" test "$("$here/tally.sh" "$tsv" | awk 'NR > 1 && $4 != 1 { bad++ } END { print bad + 0 }')" = 0
check "run refuses to start without a probe" test "$("$here/run.sh" --bin "$bin" --claude "$here/fake-claude.sh" --out "$out/none" run 2>&1 | grep -c 'no probe')" = 1

if [ "$failures" -gt 0 ]; then
  echo "$failures check(s) failed. The log of the run:" >&2
  cat "$out/run.log" >&2
  exit 1
fi
echo "selftest: ok"
