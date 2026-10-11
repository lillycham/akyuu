# A home-manager module for akyuu.
#
#   imports = [ inputs.akyuu.homeModules.default ];
#   programs.akyuu = {
#     enable = true;
#     gc.enable = true;
#     backup.enable = true;
#   };
#
# It installs the binary, sets AKYUU_ROOT, and makes the store directory (the
# program needs the root to exist, so that a typo cannot make a new store).
# The launchd agents get the root as an argument, because an agent does not
# see the session variables.
#
# Only launchd (macOS) agents are written. On Linux the module installs the
# package and sets the variable, and the timers are not done yet.
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

  calendar = hour: minute: [{ Hour = hour; Minute = minute; }];

  # A length of time as `akyuu gc` reads it: a whole number and a unit.
  durationType = types.strMatching "[0-9]+[smhd]";
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
      example = "claude/memory-policy";
      description = ''
        The name of the ref that holds the policy of the store: how agents
        use it for memory. `akyuu mcp` tells a client to read it first. With
        null the server uses `policy/memory`. The value is set as
        AKYUU_POLICY_REF.
      '';
    };

    tiersRef = mkOption {
      type = types.nullOr (types.strMatching "[a-z0-9._-]+(/[a-z0-9._-]+)*");
      default = null;
      example = "policy/tiers";
      description = ''
        The name of the ref that holds the manifest of the tiers: which refs
        a session reads at the start (`akyuu context`). With null the
        default is `policy/tiers`. The value is set as AKYUU_TIERS_REF.
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
      enable = mkEnableOption "search by meaning: a command that makes vectors, set in the environment of akyuu (AKYUU_EMBED_COMMAND)";
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
        description = "The model name that the server knows (AKYUU_EMBED_API_MODEL), for the default command.";
      };
      url = mkOption {
        type = types.str;
        default = "http://localhost:1234/v1/embeddings";
        description = "The endpoint of the server, for the default command.";
      };
      minScore = mkOption {
        type = types.nullOr types.float;
        default = null;
        description = "The lowest cosine similarity that counts as near (AKYUU_EMBED_MIN). It depends on the model: find it with akyuu search-eval.";
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
      home.sessionVariables.AKYUU_ROOT = cfg.root;
      home.sessionVariables.AKYUU_POLICY_REF = mkIf (cfg.policyRef != null) cfg.policyRef;
      home.sessionVariables.AKYUU_TIERS_REF = mkIf (cfg.tiersRef != null) cfg.tiersRef;
    }

    # The settings are in a file that akyuu reads (see Akyuu.Embed), and not
    # in session variables: a desktop app and a service do not start in a
    # shell, and they must get the same settings.
    (mkIf cfg.embed.enable {
      home.packages = if cfg.embed.local.enable then [ embedLlamaPackage ] else [ embedPackage ];
      xdg.configFile."akyuu/embed.env".text =
        let
          vars = {
            AKYUU_EMBED_COMMAND = cfg.embed.command;
            AKYUU_EMBED_MODEL = cfg.embed.model;
            AKYUU_EMBED_QUERY_PREFIX = cfg.embed.queryPrefix;
            AKYUU_EMBED_DOCUMENT_PREFIX = cfg.embed.documentPrefix;
          }
          // lib.optionalAttrs cfg.embed.local.enable {
            AKYUU_EMBED_GGUF = toString cfg.embed.local.gguf;
            AKYUU_EMBED_IDLE = toString cfg.embed.local.idleSeconds;
            # The first start of the model compiles shaders and takes longer.
            AKYUU_EMBED_TIMEOUT = "60";
          }
          // lib.optionalAttrs (!cfg.embed.local.enable) { AKYUU_EMBED_URL = cfg.embed.url; }
          // lib.optionalAttrs (cfg.embed.apiModel != null) { AKYUU_EMBED_API_MODEL = cfg.embed.apiModel; }
          // lib.optionalAttrs (cfg.embed.minScore != null) { AKYUU_EMBED_MIN = toString cfg.embed.minScore; };
        in
        "# Made by the akyuu module. akyuu reads this file for AKYUU_EMBED_*.\n"
        + lib.concatStringsSep "\n" (lib.mapAttrsToList (k: v: "${k}=${v}") vars)
        + "\n";
    })

    {

      home.activation.akyuuRoot = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
        run mkdir -p ${lib.escapeShellArg cfg.root}
      '';
    }

    (mkIf (pkgs.stdenv.hostPlatform.isDarwin && cfg.gc.enable) {
      launchd.agents.akyuu-gc = {
        enable = true;
        config = {
          Label = "akyuu-gc";
          ProgramArguments = [
            "${cfg.package}/bin/akyuu"
            "--root" cfg.root
            "gc"
            "--keep-generations" (toString cfg.gc.keepGenerations)
            "--grace" cfg.gc.gracePeriod
            "--trash-ttl" cfg.gc.trashTTL
          ];
          StartCalendarInterval = calendar cfg.gc.hour cfg.gc.minute;
          StandardOutPath = "${logs}/akyuu-gc.log";
          StandardErrorPath = "${logs}/akyuu-gc.log";
          ProcessType = "Background";
          LowPriorityIO = true;
        };
      };
    })

    (mkIf (pkgs.stdenv.hostPlatform.isDarwin && cfg.versioning.enable) {
      launchd.agents.akyuu-version = {
        enable = true;
        config = {
          Label = "akyuu-version";
          ProgramArguments = [
            "${versionPackage}/bin/akyuu-version"
            "--root" cfg.root
          ] ++ optional cfg.versioning.push "--push";
          StartCalendarInterval = calendar cfg.versioning.hour cfg.versioning.minute;
          StandardOutPath = "${logs}/akyuu-version.log";
          StandardErrorPath = "${logs}/akyuu-version.log";
          ProcessType = "Background";
          LowPriorityIO = true;
        };
      };
    })

    (mkIf (pkgs.stdenv.hostPlatform.isDarwin && cfg.backup.enable) {
      launchd.agents.akyuu-backup = {
        enable = true;
        config = {
          Label = "akyuu-backup";
          ProgramArguments = [
            "${backupPackage}/bin/akyuu-backup"
            "--root" cfg.root
            "--dest" cfg.backup.directory
            "--keep" (toString cfg.backup.keep)
          ];
          StartCalendarInterval = calendar cfg.backup.hour cfg.backup.minute;
          StandardOutPath = "${logs}/akyuu-backup.log";
          StandardErrorPath = "${logs}/akyuu-backup.log";
          ProcessType = "Background";
          LowPriorityIO = true;
        };
      };
    })

    (mkIf (pkgs.stdenv.hostPlatform.isDarwin && cfg.serve.enable) {
      launchd.agents.akyuu-serve = {
        enable = true;
        config = {
          Label = "akyuu-serve";
          ProgramArguments = [
            "${cfg.package}/bin/akyuu"
            "--root" cfg.root
            "serve" "--port" (toString cfg.serve.port)
          ];
          RunAtLoad = true;
          KeepAlive = true;
          StandardOutPath = "${logs}/akyuu-serve.log";
          StandardErrorPath = "${logs}/akyuu-serve.log";
          ProcessType = "Background";
        };
      };
    })
  ]);
}
