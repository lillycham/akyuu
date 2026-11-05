#!/usr/bin/env bash
# A fake `claude -p` for the self-test of the MCP evaluation. It is not a
# model: it plays a short fixed script for scenarios S2 and S3, through the
# MCP server of the config, and prints a transcript in the stream-json shape
# that run.sh reads. It takes the prompt on its standard input, and ignores
# every option except --mcp-config.
#
# The script depends on the tool set: with the ordinary tools it reads an id,
# and passes it back as expected (and recovers from a stale one); with the
# topic tools it names the topic. That is what a careful agent does, so the
# self-test can check the whole pipeline: the proxy, the other writer, the
# verifier and the measures.

set -u
cfg=""
while [ $# -gt 0 ]; do
  case $1 in
  --mcp-config)
    cfg=$2
    shift 2
    ;;
  *) shift ;;
  esac
done
[ -r "$cfg" ] || {
  echo "fake-claude: no --mcp-config" >&2
  exit 2
}
prompt=$(cat)

command=$(jq -r '.mcpServers.akyuu.command' "$cfg")
args=()
while IFS= read -r a; do args+=("$a"); done < <(jq -r '.mcpServers.akyuu.args[]' "$cfg")
set_name=ordinary
for ((i = 0; i < ${#args[@]}; i++)); do
  [ "${args[$i]}" = "--tool-set" ] && set_name=${args[$((i + 1))]}
done

tmp=$(mktemp -d "${TMPDIR:-/tmp}/akyuu-fake.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
mkfifo "$tmp/in" "$tmp/out"
"$command" "${args[@]}" <"$tmp/in" >"$tmp/out" &
server=$!
exec 4>"$tmp/in"
exec 5<"$tmp/out"

n=0
calls=0
reply=""
text=""
failed=""

rpc() { # rpc METHOD PARAMS: send a request, read the answer into $reply
  n=$((n + 1))
  printf '%s\n' "$(jq -nc --argjson id "$n" --arg m "$1" --argjson p "$2" '{jsonrpc: "2.0", id: $id, method: $m, params: $p}')" >&4
  IFS= read -r reply <&5
}

# tool NAME ARGS: call a tool, and write the two events of a transcript.
tool() {
  rpc tools/call "$(jq -nc --arg n "$1" --argjson a "$2" '{name: $n, arguments: $a}')"
  text=$(printf '%s' "$reply" | jq -r '.result.content[0].text // .error.message // ""')
  failed=$(printf '%s' "$reply" | jq -r 'if .error then "true" else (.result.isError | tostring) end')
  calls=$((calls + 1))
  jq -nc --arg n "mcp__akyuu__$1" --argjson a "$2" '{type: "assistant", message: {content: [{type: "tool_use", name: $n, input: $a}]}}'
  jq -nc --arg t "$text" --argjson e "$failed" '{type: "user", message: {content: [{type: "tool_result", is_error: $e, content: $t}]}}'
}

version_of() { printf '%s' "$text" | sed -n 's/^id: //p' | head -1; }

swap='[{"from": "Saturdays", "to": "Sundays"}]'
final=""

jq -nc '{type: "system", subtype: "init", tools: ["mcp__akyuu__fake"], mcp_servers: [{name: "akyuu", status: "connected"}]}'
rpc initialize '{"protocolVersion": "2025-06-18", "clientInfo": {"name": "fake"}}'

case $prompt in
*"may change it while you work"*) # S3
  if [ "$set_name" = topic ]; then
    tool recall '{"topic": "people/mira/routine"}'
    tool revise "{\"topic\": \"people/mira/routine\", \"replace\": $swap}"
    final="a: Nothing went wrong. The revision applied to the current text."
  else
    tool get '{"ref": "people/mira/routine"}'
    v=$(version_of)
    tool amend "{\"ref\": \"people/mira/routine\", \"expected\": \"$v\", \"replace\": $swap}"
    final="a: The change went through."
    if [ "$failed" = true ]; then
      tool get '{"ref": "people/mira/routine"}'
      v=$(version_of)
      tool amend "{\"ref\": \"people/mira/routine\", \"expected\": \"$v\", \"replace\": $swap}"
      final="a: The first change was refused because the other agent had changed the memory. I read it again and repeated the change."
    fi
  fi
  ;;
*"She told you today"*) # S2, the first stage
  if [ "$set_name" = topic ]; then
    tool recall '{"topic": "people/mira/routine"}'
    tool revise "{\"topic\": \"people/mira/routine\", \"replace\": $swap}"
  else
    tool get '{"ref": "people/mira/routine"}'
    v=$(version_of)
    tool amend "{\"ref\": \"people/mira/routine\", \"expected\": \"$v\", \"replace\": $swap}"
  fi
  final="I changed the routine."
  ;;
*"do not remember anything about her"*) # S2, the second stage
  if [ "$set_name" = topic ]; then
    tool recall '{"query": "sourdough"}'
  else
    tool search '{"query": "sourdough"}'
  fi
  final="**a:** Sundays."
  ;;
*)
  echo "fake-claude: no script for this prompt" >&2
  exit 3
  ;;
esac

exec 4>&-
wait "$server" 2>/dev/null
jq -nc --arg r "$final" --argjson t "$((calls + 1))" '{type: "result", subtype: "success", is_error: false, num_turns: $t, total_cost_usd: 0, duration_ms: 1, result: $r}'
