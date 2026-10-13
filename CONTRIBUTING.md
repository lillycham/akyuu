# Contributing

Thanks for looking. Akyuu is a small project and this is a short guide.

## Build and test

You need Nix with flakes.

```sh
nix develop            # GHC, cabal, ormolu and the tools of the checks
cabal build all
cabal test             # the unit tests
nix flake check        # the unit tests, the shell checks and the module check
ormolu -i $(git ls-files '*.hs')  # the formatter; nix flake check checks it
```

The tests do not touch your own store or your own embedding settings.

## Changes

- Open an issue first for a big change, so that we can agree on the shape.
- Keep a change small and say why. Add a test with it (there is a test module
  for each source module).
- `docs/format.md` says what is stable. A change to the format of the store
  needs a note in `CHANGELOG.md` and a way to move an existing store.
- Commit subjects use Conventional Commits (`feat:`, `fix:`, `docs:`, ...).
  Write the bodies in short, plain sentences.

## Good places to start

See [ROADMAP.md](ROADMAP.md). A real run of the Linux systemd timers, and
reports from Linux in general, would help.
