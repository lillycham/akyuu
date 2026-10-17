# A check of the home-manager module without home-manager.
#
# It evaluates the module for one system, with stubs for the options of
# home-manager that the module sets, and returns a small attribute set of what
# the module made. Nothing is built: the paths of the packages are only
# names. `flake.nix` compares the result for macOS and for Linux.
{ self, nixpkgs, system }:
let
  pkgs = nixpkgs.legacyPackages.${system};
  lib = pkgs.lib // {
    hm.dag.entryAfter = after: data: { inherit after data; };
  };
  stub = lib.mkOption { type = lib.types.lazyAttrsOf lib.types.anything; default = { }; };
  evalWith = akyuu: lib.evalModules {
    specialArgs = { inherit pkgs lib; };
    modules = [
      (import ./home-module.nix self)
      {
        options = {
          home.homeDirectory = lib.mkOption { type = lib.types.str; };
          home.packages = lib.mkOption { type = lib.types.listOf lib.types.package; default = [ ]; };
          home.sessionVariables = stub;
          home.activation = stub;
          launchd.agents = stub;
          systemd.user.services = stub;
          systemd.user.timers = stub;
          xdg.configFile = stub;
        };
        config = {
          home.homeDirectory = "/home/test";
          programs.akyuu = akyuu;
        };
      }
    ];
  };
  evaluated = evalWith {
    enable = true;
    gc.enable = true;
    backup.enable = true;
    versioning = { enable = true; push = true; };
    serve.enable = true;
    embed = { enable = true; local.enable = true; model = "m"; };
  };
  # A profile of its own, with no embed.enable.
  profilesOnly = (evalWith {
    enable = true;
    embed.profiles.mine = { command = "akyuu-embed-openai"; key = "k"; args.api-model = "m"; };
  }).config;
  c = evaluated.config;
  timer = n: c.systemd.user.timers.${n}.Timer;
in
{
  inherit system;
  launchd = lib.sort (a: b: a < b) (builtins.attrNames c.launchd.agents);
  services = lib.sort (a: b: a < b) (builtins.attrNames c.systemd.user.services);
  timers = lib.sort (a: b: a < b) (builtins.attrNames c.systemd.user.timers);
  # The times, to see that a timer is the time of the option.
  calendars = lib.optionalAttrs (c.systemd.user.timers != { }) {
    gc = (timer "akyuu-gc").OnCalendar;
    backup = (timer "akyuu-backup").OnCalendar;
    version = (timer "akyuu-version").OnCalendar;
    persistent = (timer "akyuu-gc").Persistent;
  };
  serveRestarts = lib.optionalAttrs (c.systemd.user.services != { }) c.systemd.user.services.akyuu-serve.Service.Restart;
  # A timer and its service must have the same name, so that systemd pairs them.
  oneshot = lib.optionalAttrs (c.systemd.user.services != { }) c.systemd.user.services.akyuu-gc.Service.Type;
  hasConfigFile = c.xdg.configFile ? "akyuu/config.toml";
  hasEmbedFile = c.xdg.configFile ? "akyuu/embed.env";
  settings = c.programs.akyuu.generatedConfig;
  pushFlag = lib.optionalAttrs (c.launchd.agents != { }) (lib.elem "--push" c.launchd.agents.akyuu-version.config.ProgramArguments);
  # With embed.profiles alone: the daily embed job, and the helper it calls.
  profileJob = profilesOnly.launchd.agents ? akyuu-embed || profilesOnly.systemd.user.timers ? akyuu-embed;
  profileHelpers = map lib.getName profilesOnly.home.packages;
}
