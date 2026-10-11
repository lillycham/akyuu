# akyuu-embed-openai: an embedding command for akyuu that calls a server with
# the OpenAI embeddings API (LM Studio, Ollama's /v1, llama.cpp's
# llama-server, vLLM and others). It reads a text on stdin and prints the
# answer of the server, which akyuu reads.
#
# Set it as the command of akyuu:
#
#   export AKYUU_EMBED_COMMAND=akyuu-embed-openai
#   export AKYUU_EMBED_MODEL=lmstudio:nomic-embed-text-v1.5   # the key of the vectors
#   export AKYUU_EMBED_API_MODEL=text-embedding-nomic-embed-text-v1.5   # the name for the server
#
# Variables:
#   AKYUU_EMBED_URL              the endpoint (default http://localhost:1234/v1/embeddings)
#   AKYUU_EMBED_API_MODEL        the model name that the server knows (required)
#   AKYUU_EMBED_QUERY_PREFIX     put before the text of a search (for example "search_query: ")
#   AKYUU_EMBED_DOCUMENT_PREFIX  put before the text of a memory (for example "search_document: ")
#   AKYUU_EMBED_ROLE             query or document. akyuu sets it.

url=${AKYUU_EMBED_URL:-http://localhost:1234/v1/embeddings}
model=${AKYUU_EMBED_API_MODEL:-}
[ -n "$model" ] || { echo "akyuu-embed-openai: set AKYUU_EMBED_API_MODEL to the model name of the server." >&2; exit 2; }

case ${AKYUU_EMBED_ROLE:-document} in
  query) prefix=${AKYUU_EMBED_QUERY_PREFIX:-} ;;
  *) prefix=${AKYUU_EMBED_DOCUMENT_PREFIX:-} ;;
esac

jq -Rs --arg m "$model" --arg p "$prefix" '{model: $m, input: ($p + .)}' \
  | curl -sS --fail --max-time 30 -H 'Content-Type: application/json' -d @- "$url"
