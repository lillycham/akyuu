{
  description = "akyuu";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

  outputs = { self, nixpkgs }:
    let
      systems = [ "aarch64-darwin" "x86_64-darwin" "aarch64-linux" "x86_64-linux" ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});

      # akyuu.nix comes from `cabal2nix . > akyuu.nix`.
      # Rerun it when akyuu.cabal changes.
      # Avoids IFD problem w/flake show.
      #
      # The package with its test suite on. `checks.tests` builds this, and
      # the dev shell takes its dependencies (the test libraries too).
      withTests = pkgs: pkgs.haskellPackages.callPackage ./akyuu.nix { };

      # The package to install: no tests (they run in `checks`), no haddock.
      akyuuFor = pkgs:
        pkgs.haskell.lib.dontHaddock (pkgs.haskell.lib.dontCheck (withTests pkgs));

      backupFor = pkgs:
        pkgs.writeShellApplication {
          name = "akyuu-backup";
          runtimeInputs = [ pkgs.rsync pkgs.coreutils pkgs.findutils ];
          text = builtins.readFile ./nix/backup.sh;
        };
    in
    {
      packages = forAllSystems (pkgs: {
        akyuu = akyuuFor pkgs;
        akyuu-backup = backupFor pkgs;
        default = akyuuFor pkgs;
      });

      apps = forAllSystems (pkgs: {
        default = {
          type = "app";
          program = "${akyuuFor pkgs}/bin/akyuu";
        };
        backup = {
          type = "app";
          program = "${backupFor pkgs}/bin/akyuu-backup";
        };
      });

      checks = forAllSystems (pkgs: {
        # The unit tests, in the Nix sandbox.
        tests = withTests pkgs;
        # The backup script on a small store: the copy, a restore, a second
        # snapshot that links to the first, and the keep limit.
        backup = pkgs.runCommand "akyuu-backup-check"
          {
            nativeBuildInputs = [ (akyuuFor pkgs) (backupFor pkgs) pkgs.coreutils ];
          }
          (builtins.readFile ./nix/backup-check.sh);
      });

      overlays.default = final: _prev: {
        akyuu = akyuuFor final;
        akyuu-backup = backupFor final;
      };

      # A home-manager module: the binary, AKYUU_ROOT, and optional launchd
      # agents for GC, backup and the web UI. See nix/home-module.nix.
      homeModules.default = import ./nix/home-module.nix self;

      devShells = forAllSystems (pkgs: {
        default = pkgs.haskellPackages.shellFor {
          packages = _: [ (withTests pkgs) ];
          nativeBuildInputs = with pkgs.haskellPackages; [
            cabal-install
            haskell-language-server
          ];
        };
      });
    };
}
