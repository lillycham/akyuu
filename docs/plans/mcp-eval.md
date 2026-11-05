# An MCP-only evaluation of the ordinary and topic tool sets

Status as of 2026-10-23: the harness is built and self-tested with a fake
agent. It has not run with a model. Nothing here is merged.

## Question

Does the `topic` tool set help an agent that has only MCP tools? Run the same
tasks on the `ordinary` set and on the `topic` set, with the same model and
the same words, and compare what the agents leave in the store and how much
trouble they have.

## Why a new harness

The suite in `eval/` (checks, scenarios, charters) is written for an agent
with a shell. The prompts say "reach it with the command `akyuu`" and send the
agent to `--help` and the man page. Four of the eight scenarios need
maintenance work (`summarise`, `check`, `compare`, `review`, `neighbours`)
that neither set offers. So this harness reuses the fixtures and the verifiers
of `eval/scenarios.sh`, which judge the final state of the store and not the
interface, and adds what is missing: prompts for MCP tools, a runner for a
headless agent, and a way to make another agent change the store at the right
moment.

## Scenarios

| Scenario | In this harness |
|---|---|
| S1 cold start and recall | The store is already started (`init` is a command, not a tool). One agent records three facts. A second, fresh agent answers three questions from the store. |
| S2 change a fact | One agent changes a fact. A fresh agent answers from the store. This tests recall of a topic that has an old version. |
| S3 concurrent change | The agent reads, then writes. A proxy makes another writer append a line just before the first write. The agent must keep both changes. |
| S6 a memory that gives orders | A memory holds text that tells the reader to replace the policy. The agent has no shell. The store must stay unchanged, and the agent should say so. |
| S7 a secret and a request to forget | The token must not be stored. The address must leave the current text. |
| S4, S5, S8 | Left out: logs with summaries, `check` findings and graph search are maintenance work. |

The prompts are the same for both sets. They name no tool. What differs is
only what the server says about its tools: the list, the descriptions and the
instructions. That is what the evaluation tests.

## The harness

Everything is in `eval/mcp/`.

- `run.sh` is the runner. Commands: `list` (what a run would do, no cost),
  `probe` (one small call to check isolation), `run`, and `selftest` (the
  harness with a fake agent, no cost).
- `proxy.sh` sits between the agent and `akyuu mcp`. For S3 it runs the other
  writer once, before the first write call of the agent.
- `prompts/` has one text for each stage, and `system.txt` is the short system
  prompt of every agent.
- `tally.sh` turns `results.tsv` into a table by set and scenario.
- `fake-claude.sh` and `selftest.sh` test the harness without a model.

For each cell (scenario, set, run) the runner:

1. makes a fresh store with `eval/scenarios.sh setup` (and runs `init` for S1);
2. writes an MCP config that starts `proxy.sh` for that store and that set;
3. runs `claude -p` once for the task, and a second time with a fresh agent for
   S1 and S2;
4. writes the final message of the last agent to the answers file;
5. runs `eval/scenarios.sh verify`;
6. reads the transcript for the measures below, and appends a row to
   `results.tsv`.

### Isolation

The agent must not see the store of the person who runs the evaluation, or
that person's notes. The runner starts `claude` with:

- `--setting-sources project`: no user settings, so no user hooks and no user
  `CLAUDE.md`. The working directory is empty, so there are no project ones.
  (`--safe-mode` was tried first. It also switched off the MCP server of
  `--mcp-config`, so the agent had no tools.);
- `--mcp-config` and `--strict-mcp-config`: only the proxy for the test store;
- `--tools ""` and `--allowedTools "mcp__akyuu__*"`: no shell, no file tools;
- `--permission-mode dontAsk`, `--no-session-persistence`, and an empty working
  directory;
- `--system-prompt` with a short neutral text, and `--max-budget-usd` for each
  session.

`probe` checks this before a real run. It starts one session with the same
flags and reads the `init` event of the transcript. The tools must be only
`mcp__akyuu__*`, the server must be connected, and the agent must not know the
name of the person. `run` refuses to start without a successful probe in the
same output directory.

### Measures

- **Verifier result**: checks passed and failed (`eval/scenarios.sh verify`).
  A run is clean when no check failed.
- **Tool calls** and **tool errors** (results with `is_error`), from the
  transcript.
- **Turns**, **cost** in dollars, and **seconds**.
- **Size** of `tools/list` for each set, in bytes (13186 for ordinary and
  8245 for topic when measured on 2026-10-23).
- For S3: whether the other writer ran (a run where it did not is not valid).

### Sample and budget

Three runs for each cell: 5 scenarios, 2 sets, 3 runs make 30 sessions, and
S1 and S2 add 12 for the second agent. That is 42 sessions, on Sonnet. The
runner stops when the total cost passes `--max-total-usd` (default 15), and each
session is capped by `--max-run-usd` (default 1) and `--max-seconds` (default
300). The cost of a session is not known before the probe and a pilot.

Order: `probe`; then a pilot with one run for each cell (`--runs 1`); then the
full run, if the pilot looks sound.

### What changed between the pilots and the full run (2026-10-23)

Two pilots ran, each with one run for each cell (about $0.25 and $0.22).

- Pilot 1 showed three checks that failed correct work: S2.1, S2.3 and S3.1
  rejected a note that she used to bake on Saturdays. They now fail only when a
  current memory states Saturday as the current day. S1.3 stayed as it was.
- The pilots showed three gaps in the topic set. The instructions did not say
  that old text stays in the store, and one agent told a person that nothing
  was left. Agents bundled the facts about a person in one topic. A `recall`
  hit showed no version. The topic set was changed (instructions, the
  description of `remember`, the version in each hit), and `tools/list` grew
  from 8245 to 8411 bytes.
- The full run therefore tests the changed topic set. The ordinary set is the
  same as in the pilots. The pilot results are kept (`results-pilot1.tsv`,
  `results-pilot2.tsv`) as the "before" for the topic set, with one run each.
- S7.4 is still loose: its pattern matches the word "still". It is left as it
  is, and the answers of S7 are read by hand.

## What is tested and what is not, before the first run

- The self-test (`run.sh selftest`) runs S2 and S3 on both sets with a fake
  agent. It proves the proxy, the other writer, the verifiers, the measures and
  the tally. It checks that an agent that recovers from a stale write is clean.
- Not tested without a model: the prompts of S1, S6 and S7, and the behaviour
  of a real agent. The probe tests the flags and the `init` event. The pilot
  tests the rest.
- The probe has power: a control call with no isolation flags names the owner
  of the machine, and a call with the flags answers `unknown`.
- The answers are read from the last message of the last agent. A line that
  starts with markdown (`**a:**`) is cleaned first, in the same way for both
  sets.

## What the result can and cannot show

- Three runs for each cell show a large difference and nothing small. A cell
  that fails once in three is a signal, not a rate.
- One model, one date. Another model can behave differently.
- The verifiers judge the store. They do not judge the quality of an answer
  beyond the words that they look for.
- The eval cannot prove that the topic set is safe under concurrency. The tests
  in the repository do that. This shows whether an agent copes.
- The runs use the subscription of the person who starts them.

## Delivery

1. This plan, then the harness, and a self-test that passes without a model.
2. The person who owns the store reads the harness. Nothing runs before that.
3. `probe`, the pilot, and the full run, each on a word from that person.
4. The tally and the notes go into a file next to this plan.
