# Replica experiments

These tools use synthetic stores in fresh temporary directories. They do not
use the configured memory store. Run them through Nix.

## Build

From the repository, enter `nix develop`, then run:

```sh
cabal build --offline lib:akyuu exe:akyuu
cabal exec -- ghc -O2 -Wall -threaded -rtsopts -package akyuu \
  -outputdir /tmp/akyuu-sync-bench-build \
  -o /tmp/akyuu-sync-bench bench/SyncV1.hs
akyuu_bench_cli="$(cabal list-bin exe:akyuu)"
```

The experiment compiler needs the local library. A release executable alone
does not supply that library. Haskell Language Server is not required.

## Local measurements

```sh
nix shell --inputs-from . nixpkgs#nodejs nixpkgs#git nixpkgs#bash \
  nixpkgs#coreutils nixpkgs#openssh -c \
  node bench/run-sync-v1.cjs /tmp/akyuu-sync-bench "$akyuu_bench_cli" \
  /tmp/akyuu-performance.json 100 1000 5000
```

Each fixture has topic revisions across at most 32 topic refs, a log with
three quarters of the entries, and summaries of 20 older episodes. Two
control memories select one topic and the log. Bodies have a marker and
1000 padding characters. Summary bodies are short.

The default body profile repeats one character. Set `AKYUU_BENCH_BODY=varied`
to use fixed text and deterministic hash tokens instead. This control reduces
shared text between objects. It is not natural-language or private user data.

The fixture's base events, payloads and checkpoint are deterministic. Local
writer registration uses a fresh identity. The seed output describes the base
inventory before that registration. Complete measurements add five topic revisions,
five direct commits, and up to two successful concurrent commits.

The driver records five samples per local operation and three unchanged syncs.
It records initial publication and join once. Metric timers exclude process
startup, but include JSON evaluation. CLI timers include startup. Reads use
normal filesystem caches; no cache flush occurs. Initial archive population
and later archive checks remain separate observations in the raw samples.
These small samples do not establish tail latency or statistical confidence.

The uncontended direct-commit timer excludes event preparation. It encloses
the repository transaction, including lock acquisition and release. It is an
approximation of the uncontended lock window. Two independent writes then
start at a barrier. The harness checks that accepted state matches both
outcomes, including a `RepositoryBusy` result.

Each fixture command has a 120-second deadline and a 2 GiB Haskell heap cap.
The driver permits 125 seconds for cleanup. CLI calls have a 65-second outer
limit. A timeout is a result, not proof of a product deadline failure.
Set `AKYUU_BENCH_SPLIT=1` to run each local metric in a separate process with
the same deadline. This preserves earlier measurements when a later operation
fails. The driver saves completed stages before it advances and returns a
nonzero exit code if any profile fails.

The driver removes its disposable fixtures, including failed ones. Set
`AKYUU_BENCH_KEEP=1` to retain them for inspection. Direct `measure`, `metric`
and `race` commands require the marker that `seed` creates. Do not add that
marker to an ordinary store.

## Two-machine SSH experiment

Use an authorised SSH alias and a native executable on each machine:

```sh
nix shell --inputs-from . nixpkgs#nodejs nixpkgs#git nixpkgs#bash \
  nixpkgs#coreutils nixpkgs#openssh -c \
  node bench/ssh-sync-v1.cjs linux-test-host "$akyuu_bench_cli" \
  /absolute/path/to/native/akyuu /tmp/akyuu-ssh-result.json
```

The remote machine needs `git`, `mktemp`, `env`, `mv`, `test` and `rm` on its
SSH command path. The harness uses existing SSH configuration and batch-mode
authentication. It does not copy credentials or change SSH configuration.

The local replica uses Git over SSH. The Linux replica uses the same bare
remote through its local path. The test covers distinct identity, concurrent
topic alternatives, explicit resolution, DAG branches, summary evidence,
pending work after remote unavailability, and archived pin restoration after GC.
The unavailable-remote test temporarily moves only its own bare repository.
It does not simulate packet loss, stop SSH, or stop any existing service.

The harness removes only its own fresh local and remote temporary directories.
Its timing log is diagnostic. Use a separate controlled run for SSH latency.

See [the measured results](results/2026-11-03.md) for observations and limits.

## Archive and writer barrier

Use `seed` to make a fresh fixture, then run:

```sh
/tmp/akyuu-sync-bench archive-writer /tmp/fresh-fixture +RTS -N2 -M2G -RTS
```

The fixture must have no archive. The experiment pauses its first archive
payload write and runs an ordinary topic replacement before it permits
archive progress. It records the writer duration. The total archive timer
includes this deliberate pause and is not an independent archive latency.
Acknowledgement must preserve the later write as pending. The command uses
the same 120-second deadline as the other fixture commands.
