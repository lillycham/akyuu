# akyuu-embed-llama: an embedding command for akyuu that runs llama.cpp
# itself, so no other program (LM Studio, Ollama) has to be open.
#
# The first call starts `llama-server --embeddings` on 127.0.0.1 and waits for
# it. Each call sends the text to it. The server stops by itself after
# AKYUU_EMBED_IDLE seconds without a call, so it does not keep memory.
#
# Variables:
#   AKYUU_EMBED_GGUF             the model file (required)
#   AKYUU_EMBED_LLAMA_PORT       default 8767
#   AKYUU_EMBED_IDLE             seconds before the server stops (default 120)
#   AKYUU_EMBED_QUERY_PREFIX     put before the text of a search
#   AKYUU_EMBED_DOCUMENT_PREFIX  put before the text of a memory
#   AKYUU_EMBED_ROLE             query or document. akyuu sets it.

gguf=${AKYUU_EMBED_GGUF:-}
[ -f "$gguf" ] || { echo "akyuu-embed-llama: set AKYUU_EMBED_GGUF to a model file." >&2; exit 2; }
port=${AKYUU_EMBED_LLAMA_PORT:-8767}
idle=${AKYUU_EMBED_IDLE:-120}
state=${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}/akyuu-embed-llama-$port
mkdir -p "$state"
base=http://127.0.0.1:$port

up() { curl -sf --max-time 1 "$base/health" > /dev/null 2>&1; }

start() {
  # A lock that a crashed run left: no server is running under it.
  if [ -d "$state/lock" ] && ! kill -0 "$(cat "$state/pid" 2> /dev/null)" 2> /dev/null; then
    rm -rf "$state/lock"
  fi
  # One caller starts the server. The others wait for it.
  if mkdir "$state/lock" 2> /dev/null; then
    llama-server -m "$gguf" --embeddings --host 127.0.0.1 --port "$port" \
      -c 2048 -b 2048 -ub 2048 --log-disable > /dev/null 2>&1 &
    echo $! > "$state/pid"
    # The reaper stops the server when no call touched `last` for $idle seconds.
    (
      while sleep 5; do
        now=$(date +%s)
        last=$(stat -f %m "$state/last" 2> /dev/null || stat -c %Y "$state/last" 2> /dev/null || echo 0)
        if [ $((now - last)) -gt "$idle" ]; then
          kill "$(cat "$state/pid")" 2> /dev/null
          rm -rf "$state/lock"
          exit 0
        fi
        kill -0 "$(cat "$state/pid")" 2> /dev/null || { rm -rf "$state/lock"; exit 0; }
      done
    ) > /dev/null 2>&1 &
  fi
  for _ in $(seq 1 120); do
    up && return 0
    sleep 0.5
  done
  echo "akyuu-embed-llama: the server did not start." >&2
  return 1
}

touch "$state/last"
up || start || exit 1
touch "$state/last"

case ${AKYUU_EMBED_ROLE:-document} in
  query) prefix=${AKYUU_EMBED_QUERY_PREFIX:-} ;;
  *) prefix=${AKYUU_EMBED_DOCUMENT_PREFIX:-} ;;
esac

jq -Rs --arg p "$prefix" '{input: ($p + .)}' \
  | curl -sS --fail --max-time 30 -H 'Content-Type: application/json' -d @- "$base/v1/embeddings"
