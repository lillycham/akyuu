# A home-manager module for akyuu.
#
#   imports = [ inputs.akyuu.homeModules.default ];
#   programs.akyuu = {
#     enable = true;
#     gc.enable = true;
#     backup.enable = true;
#   };
#
# It installs the binary, writes ~/.config/akyuu/config.toml (the root, the
# refs and the embedding profiles), and makes the store directory (the program
# needs the root to exist, so that a typo cannot make a new store). Every
# client reads the same file: a shell, a desktop app and a service. The jobs
# also get the root as an argument.
#
# The daily jobs are launchd agents on macOS and systemd user timers on Linux.
# They are the same jobs: one list, `jobs`, makes both. A timer has
# Persistent=true, so a run that was missed (the machine was off) happens at
# the next start, like a launchd calendar job.
self:
{ config, lib, pkgs, ... }:
let
  cfg = config.programs.akyuu;
  inherit (lib) mkEnableOption mkIf mkMerge mkOption optional types;
  system = pkgs.stdenv.hostPlatform.system;
  home = config.home.homeDirectory;
  logs = "${home}/Library/Logs";

  backupPackage = self.packages.${system}.akyuu-backup;
  versionPackage = self.packages.${system}.akyuu-version;
  embedPackage = self.packages.${system}.akyuu-embed-openai;
  embedLlamaPackage = self.packages.${system}.akyuu-embed-llama;
  nomicGguf = self.packages.${system}.nomic-embed-text-gguf;

  isDarwin = pkgs.stdenv.hostPlatform.isDarwin;
  isLinux = pkgs.stdenv.hostPlatform.isLinux;
  calendar = hour: minute: [{ Hour = hour; Minute = minute; }];
  two = n: lib.fixedWidthNumber 2 n;

  # The jobs, for both systems. A job with `at` runs every day at that time.
  # A job with no `at` is a service that stays up.
  jobs = lib.filterAttrs (_: j: j.enable) {
    gc = {
      enable = cfg.gc.enable;
      description = "akyuu garbage collection";
      exec = [
        "${cfg.package}/bin/akyuu"
        "--root" cfg.root
        "gc"
        "--keep-generations" (toString cfg.gc.keepGenerations)
        "--grace" cfg.gc.gracePeriod
        "--trash-ttl" cfg.gc.trashTTL
      ];
      at = { inherit (cfg.gc) hour minute; };
    };
    version = {
      enable = cfg.versioning.enable;
      description = "akyuu versioning of the memories";
      exec = [ "${versionPackage}/bin/akyuu-version" "--root" cfg.root ] ++ optional cfg.versioning.push "--push";
      at = { inherit (cfg.versioning) hour minute; };
    };
    backup = {
      enable = cfg.backup.enable;
      description = "akyuu backup";
      exec = [
        "${backupPackage}/bin/akyuu-backup"
        "--root" cfg.root
        "--dest" cfg.backup.directory
        "--keep" (toString cfg.backup.keep)
      ];
      at = { inherit (cfg.backup) hour minute; };
    };
    # A catch-up for search by meaning: a new memory gets its vectors when it
    # is written, unless the model was not ready. This also removes the
    # vectors of memories that GC deleted.
    embed = {
      enable = embedOn;
      description = "akyuu vectors for search by meaning";
      exec = [ "${cfg.package}/bin/akyuu" "--root" cfg.root "embed" "--prune" ];
      at = { hour = 4; minute = 30; };
    };
    serve = {
      enable = cfg.serve.enable;
      description = "akyuu web view (read-only, 127.0.0.1)";
      exec = [ "${cfg.package}/bin/akyuu" "--root" cfg.root "serve" "--port" (toString cfg.serve.port) ];
      at = null;
    };
  };

  # A length of time as `akyuu gc` reads it: a whole number and a unit.
  durationType = types.strMatching "[0-9]+[smhd]";

  toml = pkgs.formats.toml { };

  # One embedding profile, as in the [embed.profiles.NAME] table of the file.
  profileType = types.submodule {
    options = {
      command = mkOption { type = types.str; description = "The command: it reads a text on stdin and prints a vector."; };
      key = mkOption { type = types.str; description = "The key of the vectors. Change it when the model, its runtime or its quantisation changes."; };
      queryPrefix = mkOption { type = types.str; default = ""; description = "Text that akyuu puts before a search."; };
      documentPrefix = mkOption { type = types.str; default = ""; description = "Text that akyuu puts before a memory."; };
      min = mkOption { type = types.nullOr types.float; default = null; description = "The lowest cosine similarity that counts as near. Find it with akyuu search-eval."; };
      timeout = mkOption { type = types.nullOr types.ints.positive; default = null; description = "Seconds for one call (default 10)."; };
      maxChars = mkOption { type = types.nullOr types.ints.positive; default = null; description = "The most characters of a text in one call (default 4000)."; };
      args = mkOption {
        type = types.attrsOf (types.oneOf [ types.str types.int types.bool ]);
        default = { };
        description = "Arguments for the command. `gguf` arrives as AKYUU_EMBED_GGUF; akyuu does not read them.";
      };
    };
  };

  profileToml = p:
    { inherit (p) command key; }
    // lib.optionalAttrs (p.queryPrefix != "") { query-prefix = p.queryPrefix; }
    // lib.optionalAttrs (p.documentPrefix != "") { document-prefix = p.documentPrefix; }
    // lib.optionalAttrs (p.min != null) { inherit (p) min; }
    // lib.optionalAttrs (p.timeout != null) { inherit (p) timeout; }
    // lib.optionalAttrs (p.maxChars != null) { max-chars = p.maxChars; }
    // lib.optionalAttrs (p.args != { }) { inherit (p) args; };

  # The profile that the older options (embed.enable, embed.command, ...)
  # describe. It is named "default".
  defaultProfile = {
    inherit (cfg.embed) command queryPrefix documentPrefix;
    key = cfg.embed.model;
    min = cfg.embed.minScore;
    # The first start of a local model compiles shaders and takes longer.
    timeout = if cfg.embed.local.enable then 60 else null;
    maxChars = null;
    args =
      if cfg.embed.local.enable
      then { gguf = toString cfg.embed.local.gguf; idle = cfg.embed.local.idleSeconds; }
      else { url = cfg.embed.url; } // lib.optionalAttrs (cfg.embed.apiModel != null) { api-model = cfg.embed.apiModel; };
  };

  profiles = cfg.embed.profiles // lib.optionalAttrs cfg.embed.enable { default = defaultProfile; };
  profileName = if cfg.embed.profile != null then cfg.embed.profile else if cfg.embed.enable then "default" else null;

  # Search by meaning is on when a profile is in use: one that embed.profile
  # names, or the only one (akyuu then takes it, see Akyuu.Config). Not only
  # with embed.enable, so that embed.profiles alone also gets the daily job.
  embedOn = profileName != null || builtins.length (builtins.attrNames profiles) == 1;

  # The helper commands that the profiles call, by name or by path.
  commands = map (p: p.command) (builtins.attrValues profiles);
  calls = name: lib.any (c: c == name || lib.hasSuffix "/bin/${name}" c) commands;
  helperPackages =
    lib.optional (calls "akyuu-embed-llama") embedLlamaPackage
    ++ lib.optional (calls "akyuu-embed-openai") embedPackage;

  configToml = lib.recursiveUpdate
    ({ inherit (cfg) root; }
      // lib.optionalAttrs (cfg.policyRef != null) { policy-ref = cfg.policyRef; }
      // lib.optionalAttrs (cfg.tiersRef != null) { tiers-ref = cfg.tiersRef; }
      // lib.optionalAttrs (profiles != { }) {
        embed = { profiles = lib.mapAttrs (_: profileToml) profiles; }
          // lib.optionalAttrs (profileName != null) { profile = profileName; };
      })
    cfg.settings;
in
{
  options.programs.akyuu = {
    enable = mkEnableOption "akyuu, a memory store for agents";

    package = mkOption {
      type = types.package;
      default = self.packages.${system}.akyuu;
      defaultText = "akyuu from the flake of akyuu";
      description = "The akyuu package.";
    };

    policyRef = mkOption {
      type = types.nullOr (types.strMatching "[a-z0-9._-]+(/[a-z0-9._-]+)*");
      default = null;
      example = "me/memory-policy";
      description = ''
        The name of the ref that holds the policy of the store: how agents
        use it for memory. `akyuu mcp` tells a client to read it first. With
        null the server uses `policy/memory`. The value goes in the config
        file as `policy-ref`.
      '';
    };

    tiersRef = mkOption {
      type = types.nullOr (types.strMatching "[a-z0-9._-]+(/[a-z0-9._-]+)*");
      default = null;
      example = "policy/tiers";
      description = ''
        The name of the ref that holds the manifest of the tiers: which refs
        a session reads at the start (`akyuu context`). With null the
        default is `policy/tiers`. The value goes in the config file as
        `tiers-ref`.
      '';
    };

    generatedConfig = mkOption {
      type = types.attrs;
      internal = true;
      readOnly = true;
      default = configToml;
      description = "What the module writes to config.toml (for the check of the module).";
    };

    settings = mkOption {
      type = toml.type;
      default = { };
      example = lib.literalExpression ''{ agent = "me"; }'';
      description = ''
        More settings for ~/.config/akyuu/config.toml (see akyuu(1)). They
        go over what the other options write.
      '';
    };

    root = mkOption {
      type = types.str;
      default = "${home}/.local/share/akyuu";
      defaultText = "~/.local/share/akyuu";
      description = ''
        The root directory of the store. Keep it out of a folder that a
        service syncs: the cache is a SQLite database in WAL mode.
      '';
    };

    gc = {
      enable = mkEnableOption "a daily run of `akyuu gc`";
      hour = mkOption { type = types.ints.between 0 23; default = 3; description = "Hour of the run."; };
      minute = mkOption { type = types.ints.between 0 59; default = 30; description = "Minute of the run."; };
      keepGenerations = mkOption {
        type = types.ints.unsigned;
        default = 5;
        description = "How many older values of each ref GC keeps, as well as the current one.";
      };
      gracePeriod = mkOption {
        type = durationType;
        default = "1h";
        description = "GC keeps a memory that is younger than this. A number and a unit (s, m, h or d).";
      };
      trashTTL = mkOption {
        type = durationType;
        default = "7d";
        description = "GC deletes a file in trash that is older than this. A number and a unit (s, m, h or d).";
      };
    };

    versioning = {
      enable = mkEnableOption "a daily commit of the memories to a git repository in the root of the store (akyuu-version)";
      hour = mkOption { type = types.ints.between 0 23; default = 4; description = "Hour of the run."; };
      minute = mkOption { type = types.ints.between 0 59; default = 15; description = "Minute of the run. The default is after GC and the backup."; };
      push = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Push to the first remote of the repository after each run. The
          repository must have a remote (git -C ROOT remote add origin URL)
          and it should be private: it holds all the memories. A push that
          fails is a warning.
        '';
      };
    };

    embed = {
      enable = mkEnableOption "search by meaning with the profile that the options below describe, named \"default\"";
      profiles = mkOption {
        type = types.attrsOf profileType;
        default = { };
        example = lib.literalExpression ''
          {
            gemma = {
              command = "akyuu-embed-llama";
              key = "llama:embeddinggemma-2";
              queryPrefix = "task: search result | query: ";
              documentPrefix = "title: none | text: ";
              args.gguf = "/models/embeddinggemma-2.gguf";
            };
          }
        '';
        description = "More embedding profiles. Pick one with embed.profile, or for one command with akyuu --embed-profile NAME.";
      };
      profile = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "The profile in use. The default is \"default\" when embed.enable is set.";
      };
      local = {
        enable = mkEnableOption "a model that Nix provides, run by llama.cpp from Nix when a search needs it (akyuu-embed-llama), with no other program open. The server starts at the first call and stops when it is idle";
        gguf = mkOption {
          type = types.path;
          default = nomicGguf;
          defaultText = "nomic-embed-text v1.5 at Q8_0, fetched by hash";
          description = "The model file (GGUF). Change embed.model too, and the prefixes if the model needs others.";
        };
        idleSeconds = mkOption { type = types.ints.positive; default = 120; description = "Seconds without a call before the server stops."; };
      };
      command = mkOption {
        type = types.str;
        default = if cfg.embed.local.enable then "${embedLlamaPackage}/bin/akyuu-embed-llama" else "${embedPackage}/bin/akyuu-embed-openai";
        defaultText = "akyuu-embed-llama with embed.local, else akyuu-embed-openai";
        description = ''
          The command: it reads a text on stdin and prints a vector (see
          docs/embeddings.md). The default calls a server with the OpenAI
          embeddings API, such as LM Studio, Ollama or llama-server.
        '';
      };
      model = mkOption {
        type = types.str;
        example = "lmstudio:nomic-embed-text-v1.5";
        description = ''
          The key of the vectors. Vectors with another key are not compared,
          so change it when you change the model or its runtime.
        '';
      };
      apiModel = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "The model name that the server knows (args.api-model), for the default command.";
      };
      url = mkOption {
        type = types.str;
        default = "http://localhost:1234/v1/embeddings";
        description = "The endpoint of the server, for the default command.";
      };
      minScore = mkOption {
        type = types.nullOr types.float;
        default = null;
        description = "The lowest cosine similarity that counts as near. It depends on the model: find it with akyuu search-eval.";
      };
      queryPrefix = mkOption { type = types.str; default = ""; description = "Text before a search, for models that want one (for example \"search_query: \")."; };
      documentPrefix = mkOption { type = types.str; default = ""; description = "Text before a memory (for example \"search_document: \")."; };
    };

    backup = {
      enable = mkEnableOption "a daily snapshot of the store (akyuu-backup)";
      directory = mkOption {
        type = types.str;
        default = "${home}/.local/share/akyuu-backups";
        defaultText = "~/.local/share/akyuu-backups";
        description = ''
          The directory for the snapshots. Put it on another disk or in a
          synced folder if you want it to survive the loss of this one.
        '';
      };
      keep = mkOption { type = types.ints.positive; default = 14; description = "How many snapshots to keep."; };
      hour = mkOption { type = types.ints.between 0 23; default = 4; description = "Hour of the run."; };
      minute = mkOption { type = types.ints.between 0 59; default = 0; description = "Minute of the run."; };
    };

    serve = {
      enable = mkEnableOption "the read-only web UI, as a user service on 127.0.0.1";
      port = mkOption { type = types.port; default = 7420; description = "The port of the web UI."; };
    };
  };

  config = mkIf cfg.enable (mkMerge [
    {
      home.packages = [ cfg.package ] ++ optional cfg.backup.enable backupPackage ++ optional cfg.versioning.enable versionPackage;

      # The settings are in a file that akyuu reads (see Akyuu.Config), and
      # not in session variables: a desktop app and a service do not start in
      # a shell, and they must get the same settings.
      xdg.configFile."akyuu/config.toml".source = toml.generate "akyuu-config.toml" configToml;
    }

    { home.packages = helperPackages; }

    {

      home.activation.akyuuRoot = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
        run mkdir -p ${lib.escapeShellArg cfg.root}
      '';
    }

    # macOS: launchd agents.
    (mkIf isDarwin {
      launchd.agents = lib.mapAttrs' (name: j: lib.nameValuePair "akyuu-${name}" {
        enable = true;
        config = {
          Label = "akyuu-${name}";
          ProgramArguments = j.exec;
          StandardOutPath = "${logs}/akyuu-${name}.log";
          StandardErrorPath = "${logs}/akyuu-${name}.log";
          ProcessType = "Background";
        }
        // (if j.at == null
          then { RunAtLoad = true; KeepAlive = true; }
          else { StartCalendarInterval = calendar j.at.hour j.at.minute; LowPriorityIO = true; });
      }) jobs;
    })

    # Linux: systemd user services, and a timer for each daily job. The output
    # goes to the journal: `journalctl --user -u akyuu-gc`.
    (mkIf isLinux {
      systemd.user.services = lib.mapAttrs' (name: j: lib.nameValuePair "akyuu-${name}" {
        Unit.Description = j.description;
        Service = {
          ExecStart = lib.escapeShellArgs j.exec;
        }
        // (if j.at == null
          then { Restart = "on-failure"; }
          else { Type = "oneshot"; Nice = 19; IOSchedulingClass = "idle"; });
        Install = lib.optionalAttrs (j.at == null) { WantedBy = [ "default.target" ]; };
      }) jobs;

      systemd.user.timers = lib.mapAttrs' (name: j: lib.nameValuePair "akyuu-${name}" {
        Unit.Description = "${j.description}, daily";
        Timer = {
          OnCalendar = "*-*-* ${two j.at.hour}:${two j.at.minute}:00";
          Persistent = true;
        };
        Install.WantedBy = [ "timers.target" ];
      }) (lib.filterAttrs (_: j: j.at != null) jobs);
    })
  ]);
}
