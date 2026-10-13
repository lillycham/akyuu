# Search by meaning

Status: built on a branch, 2026-10-11. It is off until `AKYUU_EMBED_COMMAND` is
set. Without it, nothing changes.

Text search finds the words of a query. It does not find "her computer is
running out of room" when the memory says "mirai is short of disk". An
embedding model turns a text into a vector, and texts with a near meaning have
near vectors. Akyuu keeps a vector for each memory, and a search joins the
nearest vectors with the text hits.

## The contract

Akyuu runs no model and names none. A command does the work, so any runtime can
sit behind it (LM Studio, Ollama, llama.cpp, MLX, a script):

| Variable | Meaning |
|---|---|
| `AKYUU_EMBED_COMMAND` | The command, run with `sh -c`. It reads a text on stdin and prints a vector. |
| `AKYUU_EMBED_MODEL` | The key of the vectors (default: the command). Change it when the model **or its runtime or quantisation** changes. Vectors with different keys are never compared. |
| `AKYUU_EMBED_TIMEOUT` | Seconds for one call (default 10). |
| `AKYUU_EMBED_MAX_CHARS` | The most characters sent for one memory (default 4000). |
| `AKYUU_EMBED_MIN` | The lowest cosine similarity that counts as near (default: none). It depends on the model: see below. |

The command also gets `AKYUU_EMBED_ROLE=query` or `document`, because some
models want a different prefix for each.

Accepted output: a JSON array of numbers, `{"embedding": [...]}`,
`{"embeddings": [[...]]}` or the OpenAI shape `{"data": [{"embedding": [...]}]}`.

`akyuu-embed-openai` (in this flake) is a command for any server with the
OpenAI embeddings API. It also takes `AKYUU_EMBED_URL`, `AKYUU_EMBED_API_MODEL`,
`AKYUU_EMBED_QUERY_PREFIX` and `AKYUU_EMBED_DOCUMENT_PREFIX`.

## How it works

- The vectors are in `embeddings.sqlite` in the root of the store, next to
  `cache.sqlite`. They are not in the cache: the cache is thrown away often,
  and a vector costs a model call. A vector is never out of date, because an
  `Id` names one text.
- A new memory (`add`, `supersede`, `append`, so also `amend` and `note`) gets
  its vector at once if the command works. This waits at most 5 seconds and
  ignores every failure. `akyuu embed` gives a vector to each memory that has
  none for the model.
- `akyuu search` embeds the query and joins two ranked lists by reciprocal rank
  fusion (a memory scores `1 / (60 + rank)` in each list). The scores of the two
  lists are not compared, so bm25 and cosine need no common scale. The current
  memories still go before old versions.
- If the command is missing, fails or is too slow, the search is a text
  search. The result says so (`note: the search by meaning did not run...`).
- `akyuu search --mode text|meaning|fused` chooses what is used.

## How to set it up with LM Studio

1. Install the llama.cpp runtime: `lms runtime get llama.cpp-mac-arm64-apple-metal-advsimd`.
   Without a runtime the server says `No LM Runtime found for model format 'gguf'`.
2. Download a model at **Q8_0**: `lms get https://huggingface.co/nomic-ai/nomic-embed-text-v1.5-GGUF/blob/main/nomic-embed-text-v1.5.Q8_0.gguf --gguf -y`
   (146 MB).
3. `lms server start`, then in the environment:

```sh
export AKYUU_EMBED_COMMAND=akyuu-embed-openai
export AKYUU_EMBED_MODEL=lmstudio:nomic-v1.5-q8_0
export AKYUU_EMBED_API_MODEL=text-embedding-nomic-embed-text-v1.5@q8_0
export AKYUU_EMBED_QUERY_PREFIX="search_query: "
export AKYUU_EMBED_DOCUMENT_PREFIX="search_document: "
export AKYUU_EMBED_MIN=0.55
akyuu embed          # one time: 80 memories took 8 seconds
```

With home-manager: `programs.akyuu.embed = { enable = true; model = "..."; apiModel = "..."; ... }`.

## Evaluation (2026-10-11)

25 searches in the memory `policy/embedding-eval`, run on a copy of the real
store (80 memories) with `akyuu search-eval`. A search passes if a memory that
a ref holds, and that the set expects, is among the first 3 hits. The set itself
and memories that no ref holds (old versions, episodes of logs) do not count.

| Category | Searches | Text | Fused (Q8_0, min 0.55) |
|---|---|---|---|
| exact words | 4 | 4 | 4 |
| paraphrase (no shared word) | 13 | 1 | 12 |
| vague question | 5 | 0 | 4 |
| typing mistake | 2 | 0 | 1 |
| nothing relevant (no hit is a pass) | 2 | 2 | 2 |

Findings:

- **The quantisation decides.** The same model at Q2_K (49 MB) passed 0 of the
  exact searches by meaning, and fused only 3 of 13 paraphrases. Q8_0 (146 MB)
  passed 12. A small file is not worth it: use Q8_0 or better.
- **The threshold matters for "nothing relevant".** A model always has a nearest
  memory. With no minimum, both of those searches returned three memories. With
  0.55 they return none, and 0.6 starts to lose real answers. The value is for
  this model. Find yours with `AKYUU_EMBED_MIN=... akyuu search-eval`.
- **No regression.** The exact searches still pass, because fusion keeps the
  text hits.
- **A pure meaning search is as good as the fused one on this set.** Fusion is
  still the default: the words are the safer signal for a name or a command.

Limits of this evaluation: 25 searches that one model (me) drafted, 5 of them
guesses, and 2 of the "nothing relevant" kind. It is enough to see a large
effect, not to tune a threshold to two decimals. Grow the set when a search
disappoints: add the line to `policy/embedding-eval`.

## Long memories, old vectors, the daily job

- A memory longer than `AKYUU_EMBED_MAX_CHARS` is cut into chunks at blank
  lines, and each chunk gets a vector (at most 8). A search ranks a memory by
  its best chunk. On the eval set this took the paraphrases from 12 to 13 of
  13, because the long memory policy is now embedded whole.
- `akyuu embed --prune` removes the vectors of other models and of memories
  that GC deleted.
- The home-manager module runs `akyuu embed --prune` every day at 04:30 when
  `embed.enable` is set. New memories get their vectors when they are written,
  so this is a catch-up for the times when the model was not ready.
- The search of the MCP server takes `mode` (`fused`, `text` or `meaning`), and
  the web view searches by meaning too.
- After an upgrade from 0.1.0.0, run `akyuu embed` once: the table changed
  (`chunks` in place of `vectors`) and the old one is dropped.

## EmbeddingGemma 2 (2026-10-13)

Google released EmbeddingGemma 2 on 2026-10-06 (740M parameters with optional
vision and audio encoders, 768 dimensions, 8K context, Apache 2.0). It was
tried with the GGUF `unsloth/embeddinggemma-2-GGUF` (`UD-Q4_K_XL`, 176 MB) and
the same 25 searches.

- It needs a llama.cpp with the architecture `gemma-embedding2`, which was
  merged in build b11452 (2026-10-06). nixpkgs had 0.4.1 (b10964) and failed
  with `unknown model architecture`. An override of `llama-cpp` to b11452
  works (a new `src` hash and `npmDepsHash`; it compiles locally in some
  minutes, there is no binary cache for it).
- Prefixes: `task: search result | query: ` and `title: none | text: `.
- Result: the same passes as nomic (12 of 13 paraphrases, 4 of 5 vague, 1 of
  2 typos, no regression, and "nothing relevant" works with a minimum).
  The minimum that keeps every pass is 0.60 to 0.64 for Gemma and 0.54 to
  0.56 for nomic. That is a slightly wider safe range, which is not much
  evidence on 25 searches.
- Cost: 176 MB file against 146 MB, about 335 MB of memory in use against
  235 MB, and a llama.cpp that nixpkgs does not have yet.

Conclusion: no reason to switch now. Try again when nixpkgs has llama.cpp
b11452 or later, with a bigger set of searches. Then the change is a new model
file, new prefixes and a new `AKYUU_EMBED_MODEL` key.
