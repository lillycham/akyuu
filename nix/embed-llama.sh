# akyuu-embed-llama: an embedding command for akyuu that runs llama.cpp
# itself, so no other program (LM Studio, Ollama) has to be open.
#
# The first call starts `llama-server --embeddings` on 127.0.0.1 and waits for
# it. Each call sends the text to it. The server stops by itself after
# AKYUU_EMBED_IDLE seconds without a call, so it does not keep memory. akyuu
# puts the prefix of the model before the text, so the text goes as it is.
#
# The args of the profile arrive as variables:
#   AKYUU_EMBED_GGUF        (args.gguf) the model file (required)
#   AKYUU_EMBED_LLAMA_PORT  (args.llama-port) default 8767
#   AKYUU_EMBED_IDLE        (args.idle) seconds before the server stops (default 120)

gguf=${AKYUU_EMBED_GGUF:-}
[ -f "$gguf" ] || { echo "akyuu-embed-llama: set AKYUU_EMBED_GGUF to a model file." >&2; exit 2; }
# /props reports the exact -m argument. Use an absolute, canonical path so
# callers in different directories agree; aliases and basenames are not proof.
gguf=$(realpath -- "$gguf")
port=${AKYUU_EMBED_LLAMA_PORT:-8767}
idle=${AKYUU_EMBED_IDLE:-120}
state=${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}/akyuu-embed-llama-$port
umask 077
mkdir -p "$state"
base=http://127.0.0.1:$port

# llama.cpp v0.5.0 documents GET /props.model_path as the -m argument:
# https://github.com/ggml-org/llama.cpp/blob/v0.5.0/tools/server/README.md#get-props-get-server-global-properties
# Read live identity on every call; old pid/model files never establish it.
same_model() {
  curl -sf --noproxy '*' --max-time 2 "$base/props" \
    | jq -e --arg model "$gguf" '.model_path == $model' > /dev/null
}

# 0: ready; 1: connection refused (safe to try starting); 2: occupied or
# unverifiable. A 503, a timeout or a non-HTTP listener is not an unused port.
probe() {
  local status=0 code
  code=$(curl -s --noproxy '*' --max-time 1 -o /dev/null -w '%{http_code}' "$base/health") || status=$?
  case "$status" in
    0) [ "$code" = 200 ] && return 0; return 2 ;;
    7) return 1 ;;
    *) return 2 ;;
  esac
}

identity_error() {
  echo "akyuu-embed-llama: port $port has a different or unverifiable model; no text sent. Stop that server yourself or choose another llama-port." >&2
}

# Kernel locks disappear when their holder exits. Never remove this file:
# unlinking it could let callers lock different inodes and both start a server.
exec 9> "$state/start.lock"
if ! flock -w 95 9; then
  echo "akyuu-embed-llama: timed out waiting for the server lock." >&2
  exit 1
fi

running_child() { [ "$(jobs -pr)" = "$1" ]; }

# This shell owns the server child for its whole lifetime. In particular, the
# idle timer must not kill a pid read from stale state or from another caller.
supervise() {
  llama-server -m "$gguf" --embeddings --host 127.0.0.1 --port "$port" \
    -c 2048 -b 2048 -ub 2048 --log-disable > /dev/null 2>&1 &
  server=$!
  trap '
    if running_child "$server"; then kill "$server" 2> /dev/null || true; fi
    wait "$server" 2> /dev/null || true
  ' EXIT
  trap 'exit 1' HUP INT TERM
  while running_child "$server"; do
    sleep 1
    # Calls retain the lock through their request, so the idle timer cannot
    # interrupt either startup or an embedding in flight.
    exec 8> "$state/start.lock"
    if flock -n 8; then
      now=$(date +%s)
      last=$(stat -c %Y "$state/last" 2> /dev/null || echo 0)
      [ $((now - last)) -le "$idle" ] || break
      flock -u 8
    fi
    exec 8>&-
  done
}

starting=
stop_startup() {
  if [ -n "$starting" ]; then
    if running_child "$starting"; then kill "$starting" 2> /dev/null || true; fi
    wait "$starting" 2> /dev/null || true
  fi
}
trap stop_startup EXIT
trap 'exit 1' HUP INT TERM

start() {
  # Do not give the persistent supervisor a copy of the caller's lock.
  supervise 9>&- > /dev/null 2>&1 &
  starting=$!
  for _ in $(seq 1 120); do
    if ! running_child "$starting"; then
      echo "akyuu-embed-llama: the server exited before it was ready." >&2
      return 1
    fi
    if probe; then
      same_model || { identity_error; return 1; }
      starting=
      return 0
    fi
    sleep 0.5
  done
  echo "akyuu-embed-llama: the server did not start." >&2
  return 1
}

if probe; then
  same_model || { identity_error; exit 1; }
else
  status=$?
  [ "$status" -eq 1 ] || { identity_error; exit 1; }
  start || exit 1
fi
touch "$state/last"

jq -Rs '{input: .}' \
  | curl -sS --noproxy '*' --fail --max-time 30 -H 'Content-Type: application/json' -d @- "$base/v1/embeddings"
