# Install, backup and versioning

## Install

With Nix and home-manager, take the flake as an input and import its module:

```nix
inputs.akyuu.url = "github:lillycham/akyuu";

# in the home-manager configuration
imports = [ inputs.akyuu.homeModules.default ];
programs.akyuu = {
  enable = true;        # the binary, AKYUU_ROOT, and the store directory
  gc.enable = true;     # `akyuu gc` once a day (03:30)
  backup.enable = true; # `akyuu-backup` once a day (04:00)
  # gc.keepGenerations = 5;  # older values of each ref that GC keeps
  # gc.gracePeriod = "1h";   # GC keeps a memory younger than this
  # gc.trashTTL = "7d";      # GC deletes trash files older than this
  # root = "~/.local/share/akyuu";
  # serve.enable = true;  # the web UI as a user service, on port 7420
};
```

The three `gc` options are passed to `akyuu gc` as `--keep-generations`, `--grace` and `--trash-ttl`.
A time is a number and a unit (`s`, `m`, `h` or `d`). The values above are the defaults.

The daily jobs are launchd agents on macOS, with their logs in `~/Library/Logs`.
On Linux they are systemd user timers (`systemctl --user list-timers 'akyuu-*'`,
logs with `journalctl --user -u akyuu-gc`). A timer that was missed, because the
machine was off, runs at the next start.

On NixOS or nix-darwin without home-manager, add the package. The daily jobs
are in the home-manager module only, so run `akyuu gc` by hand:

```nix
inputs.akyuu.url = "github:lillycham/akyuu";

environment.systemPackages = [ inputs.akyuu.packages.${pkgs.stdenv.hostPlatform.system}.default ];
environment.variables.AKYUU_ROOT = "/home/you/.local/share/akyuu";
```

The flake also has an overlay (`overlays.default`) that adds `pkgs.akyuu`.

To try akyuu without installing it: `nix run github:lillycham/akyuu -- --help`.
`nix profile install github:lillycham/akyuu` works too, but it is an imperative
install, outside your configuration.

Then give an agent the store as in [Quick start](../README.md#quick-start).

## Backup

`akyuu-backup --root DIR --dest DIR [--keep N]` makes a snapshot of `store`,
`trash`, `tombstones`, `pins`, `reviewed` and `refs`. It does not copy the cache, because
`akyuu reindex` makes that again. A file that did not change is a hard link to
the one in the last snapshot, so a snapshot of an unchanged store costs almost
nothing. The objects are copied first and the refs last, so every ref in a
snapshot points to an object in it.

To restore, copy the directories of a snapshot into an empty root and run
`akyuu --root ROOT reindex`. Then `akyuu --root ROOT verify` checks the store.

## Versioning

`akyuu-version [--root DIR] [--message TEXT]` keeps the memories in a git
repository in the root of the store. It holds `store`, `refs`, `pins`,
`reviewed` and `tombstones`. The cache, the locks and `trash` are not in it
(a `.gitignore` is made). One run makes one commit of what changed, and none if
nothing did. The message says what changed: `3 memories added, 1 removed, 2
refs changed`.

The history is the history of the memory. A memory that GC removed is still in
git, and a ref that moved can be put back. It is also a copy that can go to a
remote: add one with `git -C ROOT remote add …`. The script pushes only with
`--push` (`programs.akyuu.versioning.push = true`), to the first remote, and a
failed push is a warning. Keep that remote private.

With the home-manager module: `programs.akyuu.versioning.enable = true;` runs it
daily at 04:15, after GC (03:30) and the backup (04:00).
