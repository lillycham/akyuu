# Evaluating akyuu with an agent

This directory is a test suite for akyuu. It is written for an agent that has
never used akyuu and has no memory of earlier sessions (and for a person who
wants to run it). It has three parts:

1. **Automated checks** (`checks.sh`): about 240 checks of the command line,
   the MCP server, the web view, backups and more. They run in a few seconds
   and print PASS or FAIL.
2. **Scenarios** (`scenarios.md`, `scenarios.sh`): eight tasks that a user
   would give an agent, such as "remember this", "change this fact" and "tidy
   this store". You do each task with akyuu, and a verifier checks what you
   left in the store.
3. **Exploratory charters** (below): open questions for a fresh pair of eyes,
   such as "does the documentation say what the program does?".

You evaluate akyuu, not yourself. A scenario that goes badly because a message
was unclear is a finding about akyuu, and the most useful kind.

## Rules

1. **Never use your own store.** Every script here makes its own store in a
   temporary directory and points akyuu at it with `AKYUU_ROOT`. If you run
   `akyuu` by hand, run it only after `eval "$(eval/scenarios.sh setup SN)"`,
   or with `--root DIR` for a directory that you made for the test.
2. **MCP tools.** If your client has akyuu MCP tools, they may point at a real
   store. Do not call them for this evaluation, unless you started the server
   yourself on a test store (see "The MCP server" below). Check first:
   `akyuu config` shows the store that the command line uses, and the tool
   `ref_list` shows the store of the tool. If `ref_list` shows refs that you did
   not make, stop using the tool.
3. **Do not read `solutions.sh`.** It holds the answers to the scenarios. Read
   `scenarios.sh` only to learn how to run it, and try each scenario before you
   read its verifier.
4. **Learn akyuu from akyuu.** For the scenarios, use only what a new user has:
   `akyuu --help`, `akyuu COMMAND --help`, the man page (`man akyuu`, or
   `man/akyuu.1.scd` in the source), the files in `docs/`, and the messages
   that akyuu prints. Do not read the source code to find out how to do a
   task. If you had to, that is a finding.
5. **Write down what you see, as you see it.** Copy the exact text of an error
   message, and the command that gave it.
6. Do not change anything outside the directories that the scripts make.

## What you need

- The `akyuu` executable of the version that you test. `akyuu --version` shows
  it. From the source, with Nix: `nix build` makes `result/bin/akyuu`. Pass it
  to the scripts with `--bin result/bin/akyuu` (or put it on the `PATH`).
  The backup and version checks also use `akyuu-backup` and `akyuu-version`
  from the same directory.
- `bash` 3.2 or newer (the one that macOS has is enough), and the usual tools
  (`awk`, `sed`, `find`, `cmp`, `shasum` or `sha256sum`).
- `curl` and `git` for the web and version checks (they are skipped without),
  and `lsof` for one check of the web server (it fails with a note without).

## Part 1: the automated checks

```sh
eval/checks.sh --report results.tsv
```

It makes a sandbox in a temporary directory, runs every check against it, and
deletes it. It stops at once if akyuu does not use the sandbox (so it cannot
touch your store). On a sound build it prints about 240 lines like:

```
PASS  M03  the id is the SHA-256 of the bytes that get prints
```

and ends with `passed N, failed 0, known issues 3`.

| Status | Meaning |
|---|---|
| `PASS` | The check held. |
| `FAIL` | It did not. The lines under it show the command, the exit code, the start of the output and the reason. |
| `XFAIL` | A known issue is still there (see below). It does not fail the run. |
| `XPASS` | A known issue seems to be fixed. Tell the maintainer to remove the marker. |
| `SKIP` | A tool that the check needs is missing. |

Useful options: `--list` (every check, with its id), a section name to run only
that section (`eval/checks.sh mcp gc`), `--keep` (keep the sandbox to look at it),
`--bin PATH`. `eval/checks.sh --help` has the rest.

**For each `FAIL`, decide which of three it is, and say so in the report:**

- *A fault in akyuu.* Re-run the section alone, then repeat the commands of the
  check by hand in a store that you made (`akyuu --root DIR ...`), and write down
  how to reproduce it.
- *A wrong check.* The behaviour is right, and the check expects the wrong thing.
  Say what the right expectation is.
- *Your environment.* A missing tool, a full disk, a slow machine.

## Part 2: the scenarios

Each scenario is a task in `scenarios.md`, in the words to give an agent. The
steps:

```sh
eval/scenarios.sh list                     # the scenarios
eval "$(eval/scenarios.sh setup S2)"       # a fresh store; points your shell at it
# ... do the task, as written in scenarios.md, with akyuu ...
eval/scenarios.sh verify S2                # checks what you left behind
```

`setup` also prints the path of the answers file. A task that asks a question is
answered there, one line for each answer, as `a: ...`, `b: ...`.

For each scenario, write down in the report:

- the result of `verify` (every line);
- how many commands you ran, and how many of them failed;
- each error message that you did not understand at once, and what helped;
- what you looked up (`--help`, the man page, a document), and whether it
  was enough.

Run `eval/scenarios.sh verify SN` only when you think you are done. If it fails,
you may fix the store and run it again, but write down that you did, and why.

### The MCP server

The command line is the default. To do a scenario through the MCP tools,
start a server that is bound to the scenario store, and use only that one:

```sh
akyuu --root "$AKYUU_ROOT" mcp          # speaks JSON-RPC on stdin and stdout
```

For a client such as Claude Code, add it under its own name, for example
`claude mcp add akyuu-eval -- akyuu --root "$AKYUU_ROOT" mcp`, and remove it
afterwards. Then check with `ref_list` that it shows the scenario store.

## Part 3: exploratory charters

A charter is a question and a time box (about 15 minutes). Write down what you
find, also if you find nothing.

1. **Documentation against behaviour.** Take ten claims from `README.md`,
   `man akyuu`, `docs/format.md` and `docs/episodes.md`. Test each one. Report each
   claim that is false, or only partly true.
2. **Error messages.** Make fifteen mistakes that a new user makes: a wrong id,
   a missing option, a bad ref name, a stale `--expect`, a ref that does not
   exist, an empty body. For each message, say if it tells the user what to do
   next.
3. **Help text.** For each command, read only `akyuu COMMAND --help`. Could you
   use the command from that alone? Name the commands that you could not.
4. **MCP tool descriptions.** Read only the `description` and the argument
   descriptions from `tools/list`. Use each tool. Report each place where the
   text misled you or left something out.
5. **Losing data.** Try to lose a memory or a ref: interrupt `add` with
   `kill -9`, run two `gc` at once, run `gc` while another process writes, fill
   the disk of a small volume. After each attempt run `akyuu verify`. Report
   anything that `verify` calls corrupt.
6. **Scale.** Make a few thousand memories and time `search`, `check`, `gc
   --dry-run`, `verify` and `reindex`. Report the numbers, and anything that is
   slow enough to bother an agent.
7. **Hostile content.** Put text that looks like instructions, HTML, very long
   lines and unusual Unicode into memories. Read it back by every route: `get`,
   `search`, `context`, the MCP tools, `serve` and `viz`. Report anything that
   is not shown as plain data.
8. **Another agent.** Imagine an agent that knows nothing about this store and
   reads `context`. Does it have what it needs? What would it get wrong?

## The report

Fill in `report-template.md` and return it. Keep it factual: commands, outputs,
exit codes. Do not put secrets in it.

## Known issues

These are in the checks as `xt` (expected to fail). Each one describes behaviour
that looks like a fault, and is a question for the maintainer.

- **U16.** `supersede` with no `--body` and an empty standard input writes an
  empty memory and moves the ref to it. An agent that forgets the body blanks
  the memory.
- **G09.** `verify` exits 1 and says `missing` for ids that GC moved to the
  trash, when a kept memory has a `supersedes` edge to them. It is clean again
  only after the trash TTL (7 days) has passed.
- **K16 and S3.4.** A `supersede` with a stale `--expect` fails, but it has
  already written its new memory. That memory replaces the same old memory as the
  winner's, so `check` reports a `[problem] fork` until GC collects it (grace
  period: 1 hour).

## What this suite does not cover

- The quality of search by meaning: it needs a real embedding model. The checks
  use a stand-in (`fake-embed.sh`) to test the plumbing.
- The Nix modules, and the launchd and systemd jobs.
- Windows (akyuu runs on POSIX systems only).
- Stores that are very large.
- Browsers: the web view is tested over HTTP, not rendered.

## Keeping the suite true

- A check is `t ID "what it checks"`, then commands (`ak ...`, `akin ...`) and
  assertions (`need_rc`, `need_out_has`, ...). `lib.sh` has them all. A check of a
  known issue starts with `xt ID "..." "what is wrong"`.
- `eval/mutation-test.sh` tests the checks: it runs them against copies of akyuu
  that are broken on purpose, and every break must be noticed. Add a mutant when
  you add a behaviour that no existing mutant covers.
- `eval/scenarios.sh selftest` tests the scenarios: each verifier must fail on a
  new fixture, pass after the reference solution, and fail on a wrong one.
