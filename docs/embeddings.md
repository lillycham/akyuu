# Search by meaning

Status: built 2026-10-11; settings in profiles of the config file since
2026-10-14. It is off until a profile is set. Without one, nothing changes.

Text search finds the words of a query. It does not find "my computer is
running out of room" when the memory says "the laptop is short of disk". An
embedding model turns a text into a vector, and texts with a near meaning have
near vectors. Akyuu keeps a vector for each memory, and a search joins the
nearest vectors with the text hits.

## The contract

Akyuu runs no model and names none. A command does the work, so any runtime can
sit behind it (LM Studio, Ollama, llama.cpp, MLX, a script). The command and
everything that goes with its model are a _profile_ in
`~/.config/akyuu/config.toml` (see CONFIGURATION in `man akyuu`):

```toml
[embed]
profile = "nomic"

[embed.profiles.nomic]
command = "akyuu-embed-llama"
key = "llama:nomic-v1.5-q8_0"
query-prefix = "search_query: "
document-prefix = "search_document: "
min = 0.55
timeout = 60
args = { gguf = "/models/nomic-embed-text-v1.5.Q8_0.gguf" }
```

| Key | Meaning |
|---|---|
| `command` | The command, run with `sh -c`. It reads a text on stdin and prints a vector. |
| `key` | The key of the vectors. Change it when the model **or its runtime or quantisation** changes. Vectors with different keys are never compared. |
| `query-prefix`, `document-prefix` | Text that akyuu puts before a search and before a memory, for the models that want one. |
| `min` | The lowest cosine similarity that counts as near (default: none). It depends on the model: see below. |
| `timeout` | Seconds for one call (default 10). |
| `max-chars` | The most characters sent in one call (default 4000). |
| `args` | Arguments for the command. Each key arrives as a variable: `gguf` as `AKYUU_EMBED_GGUF`. Akyuu does not read them. |

The command also gets `AKYUU_EMBED_ROLE=query` or `document`.

Accepted output: a JSON array of numbers, `{"embedding": [...]}`,
`{"embeddings": [[...]]}` or the OpenAI shape `{"data": [{"embedding": [...]}]}`.

The flake has two commands. `akyuu-embed-llama` runs llama.cpp itself (args
`gguf`, `idle`, `llama-port`). `akyuu-embed-openai` calls any server with the
OpenAI embeddings API (args `url`, `api-model`).

`akyuu-embed-llama` reuses a server only when its live `/props.model_path`
matches the canonical absolute path of `gguf`. A healthy server alone is
not sufficient. The helper refuses an occupied port with a different or
unverifiable model before it sends text. Stop that server yourself or choose
another `llama-port`.

This check verifies the reported model path, not the file content or the
honesty of an external server. Do not replace a model file while its server
is running. Use a new path and vector key for a different model.

A profile keeps the parts of one model together, so a change of model is a
change of one line (`profile`), and `akyuu --embed-profile NAME` tries another
model for one command. `embeddings.sqlite` keeps a fingerprint of the profile
that made the vectors of each key (the command, its args and the prefixes).
When the fingerprint changes but the key does not, `embed` and `status` warn:
the vectors of two models must not share a key.

The older way, `AKYUU_EMBED_COMMAND` and the other `AKYUU_EMBED_*` variables
in the environment or in `~/.config/akyuu/embed.env`, still works: it makes a
profile named `environment`. `AKYUU_EMBED_MIN`, `AKYUU_EMBED_TIMEOUT` and
`AKYUU_EMBED_MAX_CHARS` change the profile in use for one command.

## How it works

- The vectors are in `embeddings.sqlite` in the root of the store, next to
  `cache.sqlite`. They are not in the cache: the cache is thrown away often,
  and a vector costs a model call. A vector is never out of date, because an
  `Id` names one text.
- A new memory (`add`, `supersede`, `append`, so also `amend` and `note`) gets
  its vectors if the command works. Configuration, all chunks and vector
  writes share one five-second budget, or the shorter configured timeout.
  The first failed chunk stops the operation. SQLite contention skips the
  optional vectors. Command failures do not fail the memory write;
  cancellation still propagates. `akyuu embed` fills the missing vectors
  with the configured timeout for each command call.
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
3. `lms server start`, then add a profile to `~/.config/akyuu/config.toml`:

```toml
[embed.profiles.lmstudio]
command = "akyuu-embed-openai"
key = "lmstudio:nomic-v1.5-q8_0"
query-prefix = "search_query: "
document-prefix = "search_document: "
min = 0.55
args = { api-model = "text-embedding-nomic-embed-text-v1.5@q8_0" }
```

4. `akyuu embed` once (80 memories took 8 seconds), and `akyuu config` to see
   the profile in use.

With home-manager: `programs.akyuu.embed = { enable = true; model = "..."; apiModel = "..."; ... }`
makes a profile named `default`; `programs.akyuu.embed.profiles` adds more.

## Evaluation (2026-10-11)

25 searches in the memory `policy/embedding-eval`, run on a copy of a real
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

Limits of this evaluation: 25 searches that one AI model drafted, 5 of them
guesses, and 2 of the "nothing relevant" kind. It is enough to see a large
effect, not to tune a threshold to two decimals. Grow the set when a search
disappoints: add the line to `policy/embedding-eval`.

## Long memories, old vectors, the daily job

- A memory longer than `max-chars` (of the profile) is cut into chunks at blank
  lines, and each chunk gets a vector (at most 8). A search ranks a memory by
  its best chunk. On the eval set this took the paraphrases from 12 to 13 of
  13, because the long policy memory is now embedded whole.
- `akyuu embed --prune` removes the vectors of other models and of memories
  that GC deleted.
- The home-manager module runs `akyuu embed --prune` every day at 04:30 when
  `embed.enable` is set. New memories get their vectors when they are written,
  so this is a catch-up for the times when the model was not ready.
- The search of the MCP server takes `mode` (`fused`, `text` or `meaning`), and
  the web view searches by meaning too.
- After an upgrade from 0.1.0.0, run `akyuu embed` once: the table changed
  (`chunks` in place of `vectors`). The old table stays until `akyuu embed
  --prune`, so an older akyuu on the same store keeps working.

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
b11452 or later, with a bigger set of searches. Then the change is a second
profile (a new model file, new prefixes and a new key): compare the two with
`akyuu --embed-profile gemma search-eval`, and change `embed.profile` if it
wins.
