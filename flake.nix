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

      # The package to install: no tests (they run in `checks`), no haddock,
      # and only the executable. justStaticExecutables drops the references to
      # the Haskell libraries and to GHC, so the closure is the binary and a
      # few system libraries, and not the libraries and docs of every
      # dependency (it was about 3.5 GiB without it).
      akyuuFor = pkgs:
        let
          lib = pkgs.haskell.lib;
        in
        lib.justStaticExecutables (lib.dontHaddock (lib.dontCheck (withTests pkgs)));

      backupFor = pkgs:
        pkgs.writeShellApplication {
          name = "akyuu-backup";
          runtimeInputs = [ pkgs.rsync pkgs.coreutils pkgs.findutils ];
          text = builtins.readFile ./nix/backup.sh;
        };

      embedOpenaiFor = pkgs:
        pkgs.writeShellApplication {
          name = "akyuu-embed-openai";
          runtimeInputs = [ pkgs.curl pkgs.jq ];
          text = builtins.readFile ./nix/embed-openai.sh;
        };

      embedLlamaFor = pkgs:
        pkgs.writeShellApplication {
          name = "akyuu-embed-llama";
          runtimeInputs = [ pkgs.llama-cpp pkgs.curl pkgs.jq pkgs.coreutils ];
          text = builtins.readFile ./nix/embed-llama.sh;
        };

      # nomic-embed-text v1.5 at Q8_0 (146 MB), the model of docs/embeddings.md.
      # The file is fetched by hash, so it is in the Nix store and not in an app.
      nomicGgufFor = pkgs:
        pkgs.fetchurl {
          name = "nomic-embed-text-v1.5.Q8_0.gguf";
          url = "https://huggingface.co/nomic-ai/nomic-embed-text-v1.5-GGUF/resolve/main/nomic-embed-text-v1.5.Q8_0.gguf";
          hash = "sha256-PiQ0IWSz2UmRupaS/cDdCOP9c2Lgqsw5appcVKVEw7c=";
        };

      versionFor = pkgs:
        pkgs.writeShellApplication {
          name = "akyuu-version";
          runtimeInputs = [ pkgs.git pkgs.coreutils pkgs.gawk ];
          text = builtins.readFile ./nix/version.sh;
        };
    in
    {
      packages = forAllSystems (pkgs: {
        akyuu = akyuuFor pkgs;
        akyuu-backup = backupFor pkgs;
        akyuu-version = versionFor pkgs;
        akyuu-embed-openai = embedOpenaiFor pkgs;
        akyuu-embed-llama = embedLlamaFor pkgs;
        nomic-embed-text-gguf = nomicGgufFor pkgs;
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
        version = {
          type = "app";
          program = "${versionFor pkgs}/bin/akyuu-version";
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
        # The versioning script: the repository, one commit for a change, none for
        # no change, the ignore list, and a removed memory that stays in the history.
        version = pkgs.runCommand "akyuu-version-check"
          {
            nativeBuildInputs = [ (akyuuFor pkgs) (versionFor pkgs) pkgs.coreutils pkgs.git ];
          }
          (builtins.readFile ./nix/version-check.sh);
      });

      overlays.default = final: _prev: {
        akyuu = akyuuFor final;
        akyuu-backup = backupFor final;
        akyuu-version = versionFor final;
        akyuu-embed-openai = embedOpenaiFor final;
        akyuu-embed-llama = embedLlamaFor final;
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
