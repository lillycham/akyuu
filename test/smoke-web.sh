#!/usr/bin/env bash
# Smoke test of `akyuu serve` and `akyuu viz` against a temporary store.
#
# Run it from the project root, in the Nix shell:
#
#   nix develop -c cabal build exe:akyuu
#   nix develop -c bash test/smoke-web.sh
#
# It starts the server on a free port, calls each endpoint with curl (each
# call waits at most 5 seconds), checks the status codes, and stops the
# server at the end. The store is removed at the end.
set -euo pipefail

bin=${1:-$(cabal list-bin exe:akyuu)}
root=$(mktemp -d "${TMPDIR:-/tmp}/akyuu-web-smoke.XXXXXX")
srv=""
cleanup() {
  if [ -n "$srv" ]; then kill "$srv" 2>/dev/null || true; fi
  rm -rf "$root"
}
trap cleanup EXIT
mkdir "$root/store"
export AKYUU_ROOT=$root/store

v1=$("$bin" add --kind preference --agent claude --body "Lilly prefers Haskell.")
"$bin" ref set claude/lang "$v1" --new >/dev/null
v2=$(echo "Lilly prefers Haskell, and Nix for every tool." | "$bin" supersede claude/lang --expect "$v1" --kind preference --agent claude)
"$bin" add --kind note --agent codex --about "$v2" --body "</script><script>alert(1)</script>" >/dev/null
"$bin" search haskell >/dev/null # sync the cache

"$bin" serve --port 0 >"$root/url" 2>"$root/stderr" &
srv=$!
for _ in $(seq 1 50); do
  [ -s "$root/url" ] && break
  sleep 0.1
done
url=$(head -1 "$root/url")
case "$url" in
http://127.0.0.1:*/) echo "serving at $url" ;;
*)
  echo "FAIL: no address on stdout" >&2
  cat "$root/stderr" >&2
  exit 1
  ;;
esac

# Call a path and check the status code. Print the start of the body.
expect() {
  local want=$1 path=$2
  shift 2
  local got
  got=$(curl -sS -m 5 -o "$root/body" -w '%{http_code}' "$@" "$url$path")
  printf '%s %s -> %s  %.110s\n' "${*:-GET}" "$path" "$got" "$(tr -d '\n' <"$root/body")"
  if [ "$got" != "$want" ]; then
    echo "FAIL: expected $want" >&2
    exit 1
  fi
}

expect 200 ""
expect 200 "api/stats"
expect 200 "api/graph"
expect 200 "api/graph?all=1"
expect 200 "api/graph?focus=$v1&hops=1"
expect 200 "api/memory/${v2:7:12}"
expect 200 "api/refs"
expect 200 "api/search?q=haskell"
expect 200 "api/gc/plan"
expect 200 "api/gc/explain/$v1"
expect 200 "api/trash"
expect 200 "api/verify"
expect 404 "api/memory/sha256-$(printf '0%.0s' $(seq 1 64))"
expect 400 "api/graph?hops=99"
expect 404 "api/nothing"
expect 404 "../store" --path-as-is
expect 405 "api/stats" -X POST
expect 405 "api/stats" -X DELETE
expect 403 "api/stats" -H "Host: evil.example"

# The server listens on 127.0.0.1 only.
if command -v lsof >/dev/null; then
  lsof -nP -a -p "$srv" -iTCP -sTCP:LISTEN | tail -n +2
  if lsof -nP -a -p "$srv" -iTCP -sTCP:LISTEN | tail -n +2 | grep -v '127.0.0.1:' >/dev/null; then
    echo "FAIL: the server listens on an address that is not 127.0.0.1" >&2
    exit 1
  fi
fi

kill "$srv"
wait "$srv" 2>/dev/null || true
srv=""
echo "server stopped"

# The static export: one file, with the data, and the body escaped.
"$bin" viz >"$root/viz.html"
echo "viz: $(wc -c <"$root/viz.html") bytes"
grep -q 'id="akyuu-data"' "$root/viz.html" || {
  echo "FAIL: no data in the export" >&2
  exit 1
}
if grep -q '</script><script>alert' "$root/viz.html"; then
  echo "FAIL: a body ends the script element" >&2
  exit 1
fi
echo "smoke test passed"
