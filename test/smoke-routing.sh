#!/usr/bin/env bash
# Check the edge routing of the web page on real exports.
#
# Run it from the project root, in the Nix shell:
#
#   nix develop -c cabal build exe:akyuu
#   nix develop -c bash test/smoke-routing.sh
#
# It makes the demo store and a bigger store with the real CLI (N memories,
# 150 by default), writes the page with `akyuu viz`, and runs the node checks
# on the pure functions (check-routing.js) and on the page in a fake DOM
# (check-page.js). Node comes from Nix (`nix shell nixpkgs#nodejs`), not from
# the system. Each node run has a time limit. The stores are removed at the end.
set -euo pipefail

bin=${1:-$(cabal list-bin exe:akyuu)}
n=${N:-150}
root=$(mktemp -d "${TMPDIR:-/tmp}/akyuu-routing-smoke.XXXXXX")
trap 'rm -rf "$root"' EXIT
node() { timeout 280 nix shell nixpkgs#nodejs -c node "$@"; }

# 1. The demo store.
"$bin" seed --demo --root "$root/demo" >/dev/null
"$bin" --root "$root/demo" viz >"$root/demo.html"

# 2. A store with chains, notes and many edges to a few old memories.
mkdir "$root/big"
export AKYUU_ROOT=$root/big
kinds=(fact note preference decision todo)
agents=(claude codex lilly)
prev=""
all=()
for i in $(seq 1 "$n"); do
  args=(add --kind "${kinds[$((i % 5))]}" --agent "${agents[$((i % 3))]}" --body "Memory $i: text about topic $((i % 97)).")
  if [ $((i % 3)) -ne 1 ] && [ -n "$prev" ]; then args+=(--supersedes "$prev"); fi
  if [ $((i % 4)) -eq 0 ] && [ ${#all[@]} -gt 5 ]; then args+=(--about "${all[$((i % 6))]}"); fi
  prev=$(timeout 20 "$bin" "${args[@]}")
  all+=("$prev")
done
unset AKYUU_ROOT
"$bin" --root "$root/big" viz >"$root/big.html"

# 3. The checks. The pages must be the page of this build.
node test/check-routing.js web/index.html "$root/demo.html" "$root/big.html"
node test/check-page.js "$root/demo.html" "$root/demo.html"
node test/check-page.js "$root/big.html" "$root/big.html"
echo "routing smoke test: ok"
