#!/usr/bin/env bash
# Smoke test of the akyuu executable against a temporary store.
#
# Run it from the project root, in the Nix shell:
#
#   nix develop -c cabal build exe:akyuu
#   nix develop -c bash test/smoke-cli.sh
#
# It prints each command and its output, checks the exit codes, and stops at
# the first surprise. The store is removed at the end.
set -euo pipefail

bin=${1:-$(cabal list-bin exe:akyuu)}
root=$(mktemp -d "${TMPDIR:-/tmp}/akyuu-smoke.XXXXXX")
trap 'rm -rf "$root"' EXIT
export AKYUU_ROOT=$root

# Run akyuu, show the command and its output, and check the exit code.
expect() {
  local want=$1
  shift
  echo "\$ akyuu $*"
  set +e
  "$bin" "$@"
  local got=$?
  set -e
  if [ "$got" -ne "$want" ]; then
    echo "FAIL: exit $got, expected $want" >&2
    exit 1
  fi
  echo "[exit $got]"
}

v1=$("$bin" add --kind preference --agent claude --body "Lilly prefers Haskell for tools.")
echo "\$ akyuu add --kind preference --agent claude --body ...   -> $v1"
expect 0 get "$v1"
echo
expect 0 ref set claude/lang "$v1" --new
expect 1 ref set claude/lang "$v1" --new

v2=$(echo "Lilly prefers Haskell, and Nix for every tool." |
  "$bin" supersede claude/lang --expect "$v1" --kind preference --agent claude)
echo "\$ echo ... | akyuu supersede claude/lang --expect v1 ...   -> $v2"
expect 1 supersede claude/lang --expect "$v1" --kind preference --agent claude --body "stale"

note=$("$bin" add --kind fact --agent claude --about "$v2" --body "The flake pins nixpkgs.")
echo "\$ akyuu add --kind fact --agent claude --about v2 ...   -> $note"

expect 0 ref get claude/lang --history
expect 0 ref list
expect 0 search haskell
expect 0 search --hops 0 nix
expect 0 search hask
expect 0 append claude/episodes --kind episode --agent claude --body "first episode"
expect 0 append claude/episodes --kind episode --agent claude --body "second episode"
expect 0 log claude/episodes --full
expect 0 neighbours "$v2"
expect 0 gc --dry-run
expect 0 gc
expect 0 reindex
expect 0 verify
expect 0 check
expect 0 check --json --severity problem

# Failures and bad usage.
expect 1 get sha256-0000000000000000000000000000000000000000000000000000000000000000
expect 2 get not-an-id
expect 2 add --kind "two
lines" --agent claude --body x
expect 2 add --kind " fact" --agent claude --body x
(
  unset AKYUU_ROOT
  expect 2 ref list
)
expect 1 --root "$root/missing" ref list

echo "smoke test passed"
