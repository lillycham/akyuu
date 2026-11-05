# shellcheck shell=bash
# shellcheck disable=SC2034,SC2154
# Section mcp: the MCP server, over pipes.
#
# The server speaks JSON-RPC 2.0, one JSON object on each line. The checks
# write all the requests of a phase to a file, run `akyuu mcp --tool-set maintenance` on it (the
# server stops when its input ends), and read the answers from a file of their
# own. The answers have their keys in sorted order, so "id":N,"jsonrpc" finds
# the answer to request N. No JSON tool is needed.

mcp_reset() {
  : >"$sandbox/mcp.req"
  mcp_n=0
}
mcp_raw() { printf '%s\n' "$1" >>"$sandbox/mcp.req"; }
mcp_init() {
  mcp_raw '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"eval","version":"0"}}}'
  mcp_raw '{"jsonrpc":"2.0","method":"notifications/initialized"}'
  mcp_n=1
}
# Add a numbered tool call: mcp_call TOOL 'JSON ARGUMENTS'.
mcp_call() {
  mcp_n=$((mcp_n + 1))
  printf '{"jsonrpc":"2.0","id":%s,"method":"tools/call","params":{"name":"%s","arguments":%s}}\n' \
    "$mcp_n" "$1" "$2" >>"$sandbox/mcp.req"
}
mcp_run() {
  lastcmd="akyuu mcp --tool-set maintenance < $sandbox/mcp.req"
  "$bin" mcp --tool-set maintenance <"$sandbox/mcp.req" >"$sandbox/mcp.resp" 2>"$errf"
  rc=$?
  cp "$sandbox/mcp.resp" "$outf"
  err=$(cat "$errf")
}
# The answer to request N goes in $reply.
mcp_reply() { reply=$(grep -F "\"id\":$1,\"jsonrpc\"" "$sandbox/mcp.resp" | head -1); }
# The text of the first content item of $reply (no escaped quotes inside).
mcp_text() { printf '%s' "$reply" | sed -n 's/.*"text":"\([^"]*\)".*/\1/p'; }
r_has() { printf '%s' "$reply" | grep -F -q -- "$1" || fail "answer lacks: $1"; }
r_lacks() { ! printf '%s' "$reply" | grep -F -q -- "$1" || fail "answer has, and must not: $1"; }
# The answer is a tool result that is not an error, or that is one.
r_ok() { r_has '"isError":false'; }
r_err() { r_has '"isError":true'; }

sec_mcp() {
  use_root mcp
  ak init
  ak add --kind fact --agent tester --ref me/seeded --body "A memory that was there before the server started."

  # Phase 1: the protocol, and the first tool calls.
  mcp_reset
  mcp_init
  mcp_raw '{"jsonrpc":"2.0","id":2,"method":"tools/list"}'
  mcp_n=2
  mcp_call add '{"kind":"fact","agent":"mcp-eval","body":"first via mcp","ref":"mcp/a"}'           # 3
  mcp_call add '{"agent":"mcp-eval","body":"no kind"}'                                              # 4
  mcp_call add '{"kind":"fact","agent":"mcp-eval","bodyy":"typo in the name"}'                     # 5
  mcp_call get '{"ref":"mcp/a"}'                                                                    # 6
  mcp_raw '{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"nosuchtool","arguments":{}}}'
  mcp_raw '{"jsonrpc":"2.0","id":8,"method":"nosuchmethod"}'
  mcp_raw 'this line is not json at all'
  mcp_n=8
  mcp_call ref_list '{}'                                                                            # 9
  mcp_call search '{"query":"first"}'                                                               # 10
  mcp_call context '{}'                                                                             # 11
  mcp_call note '{"body":"a note over mcp"}'                                                        # 12
  mcp_call get '{"id":"sha256-0000000000000000000000000000000000000000000000000000000000000000"}'  # 13
  mcp_call get '{}'                                                                                 # 14
  mcp_run
  p1_rc=$rc
  n_requests=$mcp_n

  t P01 "initialize answers with the protocol version, the server name and the tools capability"
  mcp_reply 1
  r_has '"protocolVersion":"2025-06-18"'
  r_has '"serverInfo":{"name":"akyuu"'
  r_has '"tools":'


  t P03 "tools/list names all 18 tools"
  mcp_reply 2
  for tool in add get supersede amend search compare review append log summarise unfold context note neighbours ref_get ref_set ref_list check; do
    r_has "\"name\":\"$tool\""
  done


  t P05 "add returns the id of the new memory, and it is not an error"
  mcp_reply 3
  r_ok
  id1=$(mcp_text)
  need_id "$id1"

  t P06 "a missing required argument is a tool error that names the argument"
  mcp_reply 4
  r_err
  r_has "'kind' is missing"

  t P07 "an argument that the tool lacks is a tool error that lists the real arguments, with a hint for a near name"
  mcp_reply 5
  r_err
  r_has "has no argument 'bodyy'"
  r_has "did you mean 'body'"
  r_has "Its arguments are:"

  t P08 "get of a ref starts with a line id: ID, then the memory as stored"
  mcp_reply 6
  r_ok
  r_has "\"text\":\"id: $id1\\nkind: fact"
  r_has "first via mcp"

  t P09 "an unknown tool is a JSON-RPC error -32602, and an unknown method is -32601"
  mcp_reply 7
  r_has '"code":-32602'
  r_has "nosuchtool"
  mcp_reply 8
  r_has '"code":-32601'

  t P10 "a line that is not JSON is answered with -32700 and id null, and the server goes on"
  reply=$(grep -F '"id":null,"jsonrpc"' "$sandbox/mcp.resp" | head -1)
  r_has '"code":-32700'
  mcp_reply 9
  r_ok
  r_has "mcp/a"
  r_has "me/seeded"

  t P11 "a notification (no id) gets no answer: one line for each request with an id, plus the parse error"
  need_eq "$(wc -l <"$sandbox/mcp.resp" | tr -d ' ')" "$((n_requests + 1))" "number of answer lines"
  [ -z "$(grep -v '^{.*}$' "$sandbox/mcp.resp")" ] || fail "stdout has a line that is not one JSON object"

  t P12 "search finds the memory that the server wrote, and context returns the policy"
  mcp_reply 10
  r_ok
  r_has "via mcp"
  mcp_reply 11
  r_ok
  r_has "tier: always"
  r_has "How to use this store for memory"

  t P13 "note answers with the log it went to"
  mcp_reply 12
  r_ok
  r_has "noted in me/log"

  t P14 "get of an id that is not there, or with no id and no ref, is a tool error"
  mcp_reply 13
  r_err
  mcp_reply 14
  r_err

  t P15 "the server stops with exit 0 when its input ends"
  need_eq "$p1_rc" 0 "exit code of the server"
  need_err_has "stdin closed"

  t P16 "what the server wrote is there for the command line: same store, same memory"
  ak get --ref mcp/a
  need_rc 0
  need_out_has "first via mcp"
  need_out_has "agent: mcp-eval"

  # Phase 2: the tools that change refs.
  ak add --kind fact --agent tester --body "a second memory to compare with"
  other=$out
  mcp_reset
  mcp_init
  mcp_call get "{\"id\":\"${id1:0:15}\"}"                                                                                              # 2
  mcp_call supersede "{\"ref\":\"mcp/a\",\"expected\":\"$id1\",\"kind\":\"fact\",\"agent\":\"mcp-eval\",\"body\":\"second via mcp\"}"   # 3
  mcp_call supersede "{\"ref\":\"mcp/a\",\"expected\":\"$id1\",\"kind\":\"fact\",\"agent\":\"mcp-eval\",\"body\":\"a stale write\"}"   # 4
  mcp_run
  mcp_reply 3
  id2=$(mcp_text)
  cp "$sandbox/mcp.resp" "$sandbox/mcp.phase2"
  mcp_reset
  mcp_init
  mcp_n=4
  mcp_call amend "{\"ref\":\"mcp/a\",\"expected\":\"$id2\",\"replace\":[{\"from\":\"second\",\"to\":\"2nd\"}]}"                            # 5
  mcp_call neighbours "{\"id\":\"$id1\"}"                                                                                              # 6
  mcp_call ref_set "{\"ref\":\"mcp/b\",\"id\":\"$other\",\"create\":true}"                                                             # 7
  mcp_call ref_set "{\"ref\":\"mcp/b\",\"id\":\"$other\",\"create\":true}"                                                             # 8
  mcp_call ref_get '{"ref":"mcp/a","history":true}'                                                                                    # 9
  mcp_call check '{}'                                                                                                                  # 10
  mcp_call append '{"ref":"mcp/log","kind":"episode","agent":"mcp-eval","body":"an episode"}'                                          # 11
  mcp_call log '{"ref":"mcp/log"}'                                                                                                     # 12
  mcp_call compare "{\"a\":\"$id1\",\"b\":\"$other\"}"                                                                                 # 13
  mcp_call review "{\"a\":\"$id1\",\"b\":\"$other\",\"agent\":\"mcp-eval\",\"note\":\"checked\"}"                                      # 14
  mcp_call search '{"query":"second","limit":1,"hops":0,"mode":"text"}'                                                               # 15
  mcp_call check '{"kinds":["fork"],"severity":"problem"}'                                                                             # 16
  mcp_call get '{"id":"5bf"}'                                                                                                      # 17
  mcp_run
  cp "$sandbox/mcp.resp" "$sandbox/mcp.phase3"
  cat "$sandbox/mcp.phase2" "$sandbox/mcp.phase3" >"$sandbox/mcp.resp"

  t P17 "get takes a whole id, or sha256- and the first 8 or more hex digits"
  mcp_reply 2
  r_ok
  r_has "first via mcp"

  t P18 "supersede with the expected id returns the new id, and the ref moves to it"
  mcp_reply 3
  r_ok
  id2=$(mcp_text)
  need_id "$id2"
  ak ref get mcp/a --history
  need_out_has "$id2"
  need_out_has "$id1"

  t P19 "supersede with a stale expected id is a tool error that says the ref moved, and the stale text is not current"
  mcp_reply 4
  r_err
  r_has "not at the expected value"
  r_has "$id2"
  ak get --ref mcp/a
  need_out_lacks "a stale write"

  t P20 "amend with replace changes the text, and neighbours (ids cut to 12 digits) shows the edge to the older memory"
  mcp_reply 5
  r_ok
  mcp_reply 6
  r_ok
  r_has "in supersedes ${id2:0:19}"
  ak get --ref mcp/a
  need_out_has "2nd via mcp"

  t P21 "ref_set with create makes a ref, and a second create fails"
  mcp_reply 7
  r_ok
  mcp_reply 8
  r_err

  t P22 "ref_get with history lists the ids"
  mcp_reply 9
  r_ok
  r_has "$id1"
  r_has "$id2"

  t P23 "check, append, log, compare, review and search answer without an error"
  for n in 10 11 12 13 14 15 16; do
    mcp_reply "$n"
    printf '%s' "$reply" | grep -F -q '"isError":false' || fail "request $n is an error: $(printf '%s' "$reply" | cut -c1-200)"
  done
  mcp_reply 12
  r_has "an episode"
  mcp_reply 13
  r_has "only in"

  t P24 "search over MCP takes limit, hops and mode"
  mcp_reply 15
  r_ok
  r_has "[second]"
  need_eq "$(printf '%s' "$reply" | grep -o 'sha256-' | wc -l | tr -d ' ')" 1 "hits with limit 1 and no neighbours"

}
