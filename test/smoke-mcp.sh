#!/usr/bin/env bash
# Smoke test of `akyuu mcp` over real pipes, against a temporary store.
#
# Run it from the project root, in the Nix shell:
#
#   nix develop -c cabal build exe:akyuu
#   nix develop -c bash test/smoke-mcp.sh
#
# It starts the server as a coprocess, sends JSON-RPC lines, and prints each
# request (>) and answer (<). Each read waits at most 5 seconds. At the end it
# closes stdin, waits for the server to stop, and prints its stderr.
set -euo pipefail

bin=${1:-$(cabal list-bin exe:akyuu)}
root=$(mktemp -d "${TMPDIR:-/tmp}/akyuu-mcp-smoke.XXXXXX")
trap 'rm -rf "$root"' EXIT
mkdir "$root/store-root"

coproc SRV { "$bin" --root "$root/store-root" mcp 2>"$root/stderr.log"; }
srv_pid=$SRV_PID
to_srv=${SRV[1]}
from_srv=${SRV[0]}

line=""
send() {
  echo "> $1"
  printf '%s\n' "$1" >&"$to_srv"
}
recv() {
  if ! IFS= read -r -t 5 line <&"$from_srv"; then
    echo "FAIL: no answer within 5 seconds" >&2
    exit 1
  fi
  if [ "${#line}" -gt 400 ]; then
    echo "< ${line:0:400}... (${#line} bytes)"
  else
    echo "< $line"
  fi
}
must() {
  case "$line" in
  *"$1"*) ;;
  *)
    echo "FAIL: expected $1" >&2
    exit 1
    ;;
  esac
}

send '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"smoke","version":"0"}}}'
recv
must '"protocolVersion":"2025-06-18"'
send '{"jsonrpc":"2.0","method":"notifications/initialized"}'
send '{"jsonrpc":"2.0","id":2,"method":"tools/list"}'
recv
must '"name":"ref_set"'

send '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"add","arguments":{"kind":"preference","agent":"claude","body":"Lilly prefers Haskell.\nAnd Nix for every tool."}}}'
recv
must '"isError":false'
id=$(printf '%s' "$line" | grep -o 'sha256-[0-9a-f]\{64\}')

send '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"ref_set","arguments":{"ref":"claude/lang","id":"'"$id"'","create":true}}}'
recv
must '"isError":false'
send '{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"supersede","arguments":{"ref":"claude/lang","expected":"'"$id"'","kind":"preference","agent":"claude","body":"Lilly prefers Haskell, and Nix for every tool and dependency."}}}'
recv
must '"isError":false'
send '{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"search","arguments":{"query":"haskell"}}}'
recv
must 'superseded by'
send '{"jsonrpc":"2.0","id":"seven","method":"tools/call","params":{"name":"get","arguments":{"ref":"claude/lang"}}}'
recv
must 'dependency.'

# Errors: a stale expected value, a bad id, an unknown tool, an unknown
# method, and a line that is not JSON.
send '{"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"supersede","arguments":{"ref":"claude/lang","expected":"'"$id"'","kind":"preference","agent":"claude","body":"stale"}}}'
recv
must '"isError":true'
send '{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"neighbours","arguments":{"id":"sha256-zz"}}}'
recv
must '"isError":true'
send '{"jsonrpc":"2.0","id":10,"method":"tools/call","params":{"name":"rm","arguments":{}}}'
recv
must '-32602'
send '{"jsonrpc":"2.0","id":11,"method":"ping"}'
recv
must '"result":{}'
send '{"jsonrpc":"2.0","id":12,"method":"resources/list"}'
recv
must '-32601'
send 'this is not json'
recv
must '-32700'

exec {to_srv}>&-
wait "$srv_pid"
echo "server exit code: $?"
echo "--- stderr of the server"
cat "$root/stderr.log"
echo "smoke test passed"
