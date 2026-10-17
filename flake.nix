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
      #
      # The man pages (man/*.scd, see test/check-man.sh) and the shell
      # completions (from optparse-applicative) go in at install time. The
      # date of a page is the date of the last commit.
      akyuuFor = pkgs:
        let
          lib = pkgs.haskell.lib;
          base = lib.justStaticExecutables (lib.dontHaddock (lib.dontCheck (withTests pkgs)));
        in
        lib.overrideCabal base (drv: {
          buildTools = (drv.buildTools or [ ]) ++ [ pkgs.scdoc pkgs.installShellFiles ];
          postInstall = (drv.postInstall or "") + ''
            export SOURCE_DATE_EPOCH=${toString (self.lastModified or 1)}
            for p in man/*.scd; do scdoc < "$p" > "''${p%.scd}"; done
            installManPage man/akyuu.1 man/akyuu.5
            installShellCompletion --cmd akyuu \
              --bash <($out/bin/akyuu --bash-completion-script $out/bin/akyuu) \
              --zsh <($out/bin/akyuu --zsh-completion-script $out/bin/akyuu) \
              --fish <($out/bin/akyuu --fish-completion-script $out/bin/akyuu)
          '';
        });

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
        # The Haskell sources are formatted with ormolu (the same version as in
        # the dev shell). Fix with: ormolu -i $(git ls-files '*.hs')
        format = pkgs.runCommand "akyuu-format-check"
          {
            nativeBuildInputs = [ pkgs.haskellPackages.ormolu ];
            src = ./.;
          }
          ''
            cd $src
            ormolu --mode check $(find app src test -name '*.hs' | sort)
            touch $out
          '';
        # The man pages name every command and flag of `akyuu --help`, and
        # render with no mandoc errors.
        man = pkgs.runCommand "akyuu-man-check"
          {
            nativeBuildInputs = [ (akyuuFor pkgs) pkgs.scdoc pkgs.mandoc ];
            src = ./.;
          }
          ''
            bash $src/test/check-man.sh akyuu $src/man
            touch $out
          '';
        module =
          let
            lib = nixpkgs.lib;
            linux = self.moduleEvals.x86_64-linux;
            mac = self.moduleEvals.aarch64-darwin;
            expect = what: ok: lib.assertMsg ok "module check failed: ${what}";
            ok =
              expect "darwin has five agents and no timer" (mac.launchd == [ "akyuu-backup" "akyuu-embed" "akyuu-gc" "akyuu-serve" "akyuu-version" ] && mac.timers == [ ] && mac.services == [ ])
              && expect "linux has five services, four timers and no agent" (linux.services == [ "akyuu-backup" "akyuu-embed" "akyuu-gc" "akyuu-serve" "akyuu-version" ] && linux.timers == [ "akyuu-backup" "akyuu-embed" "akyuu-gc" "akyuu-version" ] && linux.launchd == [ ])
              && expect "the timers are at the hours of the options" (linux.calendars.gc == "*-*-* 03:30:00" && linux.calendars.backup == "*-*-* 04:00:00" && linux.calendars.version == "*-*-* 04:15:00")
              && expect "a missed run is made up" linux.calendars.persistent
              && expect "a daily job is a one-shot, the web view restarts" (linux.oneshot == "oneshot" && linux.serveRestarts == "on-failure")
              && expect "config.toml is written on both, and embed.env no more" (linux.hasConfigFile && mac.hasConfigFile && !linux.hasEmbedFile && !mac.hasEmbedFile)
              && expect "the older embed options make the profile default" (mac.settings.embed.profile == "default" && mac.settings.embed.profiles.default.key == "m" && mac.settings.embed.profiles.default.timeout == 60 && mac.settings.embed.profiles.default.args ? gguf)
              && expect "the root is in the file" (mac.settings.root == "/home/test/.local/share/akyuu")
              && expect "push is passed on macOS" mac.pushFlag
              && expect "a profile alone gets the daily embed job and its helper" (mac.profileJob && linux.profileJob && lib.elem "akyuu-embed-openai" mac.profileHelpers);
          in
          assert ok;
          pkgs.runCommand "akyuu-module-check" { } "touch $out";
        # The versioning script: the repository, one commit for a change, none for
        # no change, the ignore list, and a removed memory that stays in the history.
        version = pkgs.runCommand "akyuu-version-check"
          {
            nativeBuildInputs = [ (akyuuFor pkgs) (versionFor pkgs) pkgs.coreutils pkgs.git ];
          }
          (builtins.readFile ./nix/version-check.sh);
      });

      # The module makes the jobs for each system: launchd agents on macOS, and
      # systemd user services and timers on Linux. This is an evaluation only
      # (no home-manager, nothing is built). It runs on every host, because
      # it uses the package set of the system that it asks for.
      moduleEvals = nixpkgs.lib.genAttrs systems (system: import ./nix/module-check.nix { inherit self nixpkgs system; });

      overlays.default = final: _prev: {
        akyuu = akyuuFor final;
        akyuu-backup = backupFor final;
        akyuu-version = versionFor final;
        akyuu-embed-openai = embedOpenaiFor final;
        akyuu-embed-llama = embedLlamaFor final;
      };

      # A home-manager module: the binary, config.toml, and optional launchd
      # agents for GC, backup and the web UI. See nix/home-module.nix.
      homeModules.default = import ./nix/home-module.nix self;

      devShells = forAllSystems (pkgs: {
        default = pkgs.haskellPackages.shellFor {
          packages = _: [ (withTests pkgs) ];
          nativeBuildInputs = with pkgs.haskellPackages; [
            cabal-install
            haskell-language-server
            ormolu
          ];
        };
      });
    };
}
