#!/usr/bin/env bash
# The MCP evaluation: the same tasks on two MCP tool sets, with a headless
# agent that has no shell. See docs/plans/mcp-eval.md.
#
#   eval/mcp/run.sh [options] list       What a run would do. No model, no cost.
#   eval/mcp/run.sh [options] selftest   The harness with a fake agent. No cost.
#   eval/mcp/run.sh [options] probe      One small call: is the agent isolated?
#   eval/mcp/run.sh [options] run        The evaluation. It needs a probe first.
#   eval/mcp/run.sh [options] tally      The table of an earlier run.
#
# Options (before the command):
#   --bin PATH          The akyuu executable to test (or AKYUU_BIN).
#   --claude PATH       The claude executable (default: claude on the PATH).
#   --model NAME        The model (default: sonnet).
#   --runs N            Runs for each scenario and set (default: 3).
#   --sets "A B"        The tool sets (default: "ordinary topic").
#   --scenarios "A B"   The scenarios (default: "S1 S2 S3 S6 S7").
#   --out DIR           Where transcripts and results go (default: a directory
#                       in $TMPDIR). Keep it outside the repository.
#   --max-run-usd X     The cost cap of one agent session (default: 1).
#   --max-total-usd X   The cost cap of the whole run (default: 15).
#   --max-seconds N     The time cap of one agent session (default: 300).
#   --skip-probe        Do not require a probe (the self-test uses this).
#
# Each run uses a fresh store, made by eval/scenarios.sh. The agent reaches it
# only through an MCP server that proxy.sh starts for that store. Nothing here
# reads or writes any other store.
#
# It needs bash 3.2 or newer, jq, and the usual tools.

set -u

here=$(cd "$(dirname "$0")" && pwd)
scen="$here/../scenarios.sh"

bin=${AKYUU_BIN:-akyuu}
claude=claude
model=sonnet
runs=3
sets="ordinary topic"
scenarios="S1 S2 S3 S6 S7"
out="${TMPDIR:-/tmp}/akyuu-mcp-eval-out"
max_run=1
max_total=15
max_seconds=300
skip_probe=no

while [ $# -gt 0 ]; do
  case $1 in
  --bin) bin=$2; shift 2 ;;
  --claude) claude=$2; shift 2 ;;
  --model) model=$2; shift 2 ;;
  --runs) runs=$2; shift 2 ;;
  --sets) sets=$2; shift 2 ;;
  --scenarios) scenarios=$2; shift 2 ;;
  --out) out=$2; shift 2 ;;
  --max-run-usd) max_run=$2; shift 2 ;;
  --max-total-usd) max_total=$2; shift 2 ;;
  --max-seconds) max_seconds=$2; shift 2 ;;
  --skip-probe) skip_probe=yes; shift ;;
  *) break ;;
  esac
done
cmd=${1:-}

die() {
  echo "run.sh: $*" >&2
  exit 3
}

abs() { # abs NAME: the full path of an executable, or nothing
  local p
  p=$(command -v "$1" 2>/dev/null) || return 1
  case $p in
  /*) echo "$p" ;;
  *) echo "$(pwd)/$p" ;;
  esac
}

command -v jq >/dev/null 2>&1 || die "jq is needed"
bin=$(abs "$bin") || die "cannot find the akyuu executable (use --bin PATH)"
claude_path=$(abs "$claude") || die "cannot find claude (use --claude PATH)"
case $out in /*) ;; *) out="$(pwd)/$out" ;; esac

# The prompts of the stages of a scenario. A second stage is a fresh agent that
# answers from the store.
stages() {
  case $1 in
  S1) echo "S1 S1b" ;;
  S2) echo "S2 S2b" ;;
  *) echo "$1" ;;
  esac
}

# --- one agent session -----------------------------------------------------

# run_claude CFG PROMPT_FILE TRANSCRIPT STDERR_FILE
# Start the agent with no shell, no file tools, no settings and no other MCP
# server, in an empty directory, with the prompt on its standard input. It is
# stopped after $max_seconds.
run_claude() {
  local cfg=$1 prompt=$2 transcript=$3 errfile=$4 cwd pid dog rc
  cwd=$(mktemp -d "${TMPDIR:-/tmp}/akyuu-mcp-cwd.XXXXXX")
  (
    cd "$cwd" || exit 3
    exec "$claude_path" -p \
      --model "$model" \
      --safe-mode \
      --mcp-config "$cfg" --strict-mcp-config \
      --tools "" --allowedTools "mcp__akyuu__*" \
      --permission-mode dontAsk \
      --no-session-persistence \
      --output-format stream-json --verbose \
      --max-budget-usd "$max_run" \
      --system-prompt "$(cat "$here/system.txt")" \
      <"$prompt" >"$transcript" 2>"$errfile"
  ) &
  pid=$!
  (
    sleep "$max_seconds"
    kill "$pid" 2>/dev/null
  ) &
  dog=$!
  wait "$pid" 2>/dev/null
  rc=$?
  kill "$dog" 2>/dev/null
  wait "$dog" 2>/dev/null
  rm -rf "$cwd"
  return $rc
}

# The MCP config for one store and one tool set.
write_config() { # write_config FILE ROOT SET INTERFERE
  jq -n --arg cmd "$here/proxy.sh" --arg bin "$bin" --arg root "$2" --arg set "$3" --arg interfere "$4" \
    '{mcpServers: {akyuu: {command: $cmd, args: ["--bin", $bin, "--root", $root, "--tool-set", $set, "--interfere", $interfere]}}}' >"$1"
}

# The text of the last message of an agent.
final_text() { jq -rs 'map(select(.type == "result")) | last | (.result // "")' "$1" 2>/dev/null; }

# The scenarios read answers as lines that start with "a:". An agent may
# write them with markdown. Take that away, for every agent in the same way.
normalise() { sed -E 's/^[[:space:]*_>#-]+//; s/^([A-Ca-c])[*_]*:[*_]*[[:space:]]*/\1: /'; }

# --- measures --------------------------------------------------------------

calls_in() { jq -s '[.[] | select(.type == "assistant") | .message.content[]? | select(.type == "tool_use" and ((.name // "") | startswith("mcp__akyuu__")))] | length' "$1" 2>/dev/null || echo 0; }
errors_in() { jq -s '[.[] | select(.type == "user") | .message.content[]? | select(.type == "tool_result" and .is_error == true)] | length' "$1" 2>/dev/null || echo 0; }
turns_in() { jq -s 'map(select(.type == "result")) | last | (.num_turns // 0)' "$1" 2>/dev/null || echo 0; }
cost_in() { jq -s 'map(select(.type == "result")) | last | (.total_cost_usd // 0)' "$1" 2>/dev/null || echo 0; }
status_in() { jq -rs 'map(select(.type == "result")) | last | (if . == null then "no-result" elif .is_error == true then (.subtype // "error") else "ok" end)' "$1" 2>/dev/null || echo no-result; }
tools_in() { jq -rs '[.[] | select(.type == "assistant") | .message.content[]? | select(.type == "tool_use") | .name | sub("^mcp__akyuu__"; "")] | unique | join(",")' "$1" 2>/dev/null; }

# --- one run ---------------------------------------------------------------

header=$(printf 'set\tscenario\trun\tpassed\tfailed\tcalls\terrors\tturns\tcost\tseconds\tstatus\tinterfered\ttools')

# one_run SET SCENARIO K: one cell of the evaluation, in a subshell. It adds a
# row to results.tsv.
one_run() {
  local set=$1 sn=$2 k=$3 dir interfere cfg t stage start calls=0 errors=0 turns=0 cost=0 status=ok tools="" last="" answers res pass fail interfered=no
  dir="$out/$set/$sn/run$k"
  rm -rf "$dir"
  mkdir -p "$dir"
  export AKYUU_EVAL_DIR="$dir/scenario"
  eval "$("$scen" --bin "$bin" setup "$sn" | grep -E '^(export|unset) ')" || die "setup failed for $sn"
  answers=$AKYUU_EVAL_ANSWERS
  [ "$sn" = S1 ] && { "$bin" init >/dev/null 2>&1 || die "init failed for S1"; }
  interfere=none
  [ "$sn" = S3 ] && interfere=S3
  cfg="$dir/mcp.json"
  write_config "$cfg" "$AKYUU_ROOT" "$set" "$interfere"

  start=$SECONDS
  for stage in $(stages "$sn"); do
    t="$dir/$stage.jsonl"
    run_claude "$cfg" "$here/prompts/$stage.txt" "$t" "$dir/$stage.stderr"
    calls=$((calls + $(calls_in "$t")))
    errors=$((errors + $(errors_in "$t")))
    turns=$((turns + $(turns_in "$t")))
    cost=$(awk -v a="$cost" -v b="$(cost_in "$t")" 'BEGIN { printf "%.4f", a + b }')
    s=$(status_in "$t")
    [ "$s" = ok ] || status=$s
    tools="$tools,$(tools_in "$t")"
    last=$t
  done
  # The answers are the last message of the last agent.
  final_text "$last" | normalise >"$answers"

  "$scen" --bin "$bin" verify "$sn" >"$dir/verify.txt" 2>&1
  res=$(sed -n 's/^passed \([0-9]*\), failed \([0-9]*\).*/\1 \2/p' "$dir/verify.txt" | tail -1)
  pass=${res% *}
  fail=${res#* }
  [ -n "$res" ] || { pass=0; fail=99; }
  [ -e "$AKYUU_EVAL_DIR/$sn/interfered" ] && interfered=yes
  [ "$sn" = S3 ] || interfered=n/a
  tools=$(printf '%s' "$tools" | tr ',' '\n' | sed '/^$/d' | sort -u | tr '\n' ',' | sed 's/,$//')
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$set" "$sn" "$k" "$pass" "$fail" "$calls" "$errors" "$turns" "$cost" "$((SECONDS - start))" "$status" "$interfered" "$tools" >>"$out/results.tsv"
}

total_cost() { awk -F'\t' 'NR > 1 { s += $9 } END { printf "%.4f", s + 0 }' "$out/results.tsv" 2>/dev/null; }

# --- commands --------------------------------------------------------------

do_list() {
  local set sn n=0 sessions=0
  echo "akyuu:     $bin ($("$bin" --version 2>&1 | head -1))"
  echo "claude:    $claude_path, model $model"
  echo "sets:      $sets"
  echo "scenarios: $scenarios"
  for set in $sets; do
    printf '%s tools/list: %s bytes\n' "$set" "$(printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' | "$bin" mcp --tool-set "$set" 2>/dev/null | wc -c | tr -d ' ')"
  done
  for sn in $scenarios; do
    n=$(echo $(stages "$sn") | wc -w | tr -d ' ')
    sessions=$((sessions + n))
    echo "  $sn: $n agent session(s) per run: $(stages "$sn")"
  done
  local nsets
  nsets=$(echo $sets | wc -w | tr -d ' ')
  echo "per run of the whole matrix: $((sessions * nsets)) sessions; with $runs runs: $((sessions * nsets * runs)) sessions"
  echo "caps: \$$max_run a session, \$$max_total in total, $max_seconds s a session"
  echo "output: $out"
  [ -e "$out/.probed" ] && echo "probe: done" || echo "probe: not done (run: probe)"
}

do_probe() {
  local dir="$out/probe" cfg t init final tools
  rm -rf "$dir"
  mkdir -p "$dir"
  export AKYUU_EVAL_DIR="$dir/scenario"
  eval "$("$scen" --bin "$bin" setup S2 | grep -E '^(export|unset) ')" || die "setup failed"
  cfg="$dir/mcp.json"
  write_config "$cfg" "$AKYUU_ROOT" topic none
  printf '%s\n' 'Reply with exactly one line: the name of the person you are helping, or the word unknown if nobody has told you. Do not use any tool.' >"$dir/prompt.txt"
  t="$dir/probe.jsonl"
  echo "probe: one small call of $claude_path ($model)..."
  run_claude "$cfg" "$dir/prompt.txt" "$t" "$dir/stderr.txt"
  init=$(jq -cs 'map(select(.type == "system" and .subtype == "init")) | first' "$t" 2>/dev/null)
  [ -n "$init" ] && [ "$init" != null ] || die "probe failed: no init event. See $dir/stderr.txt and $t"
  tools=$(printf '%s' "$init" | jq -r '.tools | join(" ")')
  echo "tools the agent has: $tools"
  printf '%s' "$init" | jq -e '(.tools | length) > 0 and all(.tools[]; startswith("mcp__akyuu__"))' >/dev/null || die "probe failed: the agent has a tool that is not an akyuu tool"
  printf '%s' "$init" | jq -e '[.mcp_servers[]? | select(.name == "akyuu" and .status == "connected")] | length == 1' >/dev/null || die "probe failed: the akyuu server is not connected"
  final=$(final_text "$t")
  echo "the agent says: $final"
  printf '%s' "$final" | tr 'A-Z' 'a-z' | grep -q 'unknown' || die "probe failed: the agent knows a name that the prompt did not give it"
  : >"$out/.probed"
  echo "probe: ok (cost $(cost_in "$t") dollars)"
}

do_run() {
  local k sn set
  [ "$skip_probe" = yes ] || [ -e "$out/.probed" ] || die "no probe in $out: run the probe first"
  mkdir -p "$out"
  [ -e "$out/results.tsv" ] || printf '%s\n' "$header" >"$out/results.tsv"
  k=1
  while [ "$k" -le "$runs" ]; do
    for sn in $scenarios; do
      for set in $sets; do
        if awk -v c="$(total_cost)" -v m="$max_total" 'BEGIN { exit !(c >= m) }'; then
          echo "stopping: the total cost passed $max_total dollars" >&2
          do_tally
          return 1
        fi
        printf 'run %s: %s %s ... ' "$k" "$sn" "$set"
        (one_run "$set" "$sn" "$k")
        tail -1 "$out/results.tsv" | awk -F'\t' '{ printf "passed %s, failed %s, %s calls, %s errors, $%s, %s\n", $4, $5, $6, $7, $9, $11 }'
      done
    done
    k=$((k + 1))
  done
  do_tally
}

do_tally() { "$here/tally.sh" "$out/results.tsv"; }

case $cmd in
list) do_list ;;
probe) do_probe ;;
run) do_run ;;
tally) do_tally ;;
selftest) exec "$here/selftest.sh" "$bin" ;;
*)
  sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//' >&2
  exit 2
  ;;
esac
