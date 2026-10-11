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

## Not done

- Re-embedding when `AKYUU_EMBED_MODEL` changes happens by `akyuu embed`. The
  vectors of the old model stay in the file and are not used. A `--prune` is
  not written.
- A memory longer than `AKYUU_EMBED_MAX_CHARS` is cut: only its start is
  embedded. Chunking is not done.
- A launchd job for `akyuu embed`: new memories get their vector when they are
  written, so the job is only a catch-up.
