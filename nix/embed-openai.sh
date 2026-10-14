# akyuu-embed-openai: an embedding command for akyuu that calls a server with
# the OpenAI embeddings API (LM Studio, Ollama's /v1, llama.cpp's
# llama-server, vLLM and others). It reads a text on stdin and prints the
# answer of the server, which akyuu reads. akyuu puts the prefix of the model
# before the text, so this command sends the text as it is.
#
# Make it the command of a profile in ~/.config/akyuu/config.toml:
#
#   [embed.profiles.lmstudio]
#   command = "akyuu-embed-openai"
#   key = "lmstudio:nomic-embed-text-v1.5"   # the key of the vectors
#   args = { api-model = "text-embedding-nomic-embed-text-v1.5" }
#
# The args of the profile arrive as variables:
#   AKYUU_EMBED_URL        (args.url) the endpoint (default http://localhost:1234/v1/embeddings)
#   AKYUU_EMBED_API_MODEL  (args.api-model) the model name that the server knows (required)

url=${AKYUU_EMBED_URL:-http://localhost:1234/v1/embeddings}
model=${AKYUU_EMBED_API_MODEL:-}
[ -n "$model" ] || { echo "akyuu-embed-openai: set api-model in the args of the profile (AKYUU_EMBED_API_MODEL)." >&2; exit 2; }

jq -Rs --arg m "$model" '{model: $m, input: .}' \
  | curl -sS --fail --max-time 30 -H 'Content-Type: application/json' -d @- "$url"
