# Install akyuu: a guide for agents

This guide is for an AI agent that a person asked to install akyuu. A person
can read it too, but [install.md](install.md) is the guide for people.

Agent: follow the steps in order. Each step starts with a check. If the check
passes, skip the step, so that a second run of the guide changes nothing.

## Rules

- **Ask** where a step says so. These steps change files that the person owns,
  or install software. Show the exact change, and wait for a yes.
- Never delete a store, a memory or a config file. Before you edit a config
  file that is not in git, copy it to `FILE.bak`.
- Read this guide from a release tag, and install that same tag. If the person
  gave you a link to `main`, tell them, and use the newest tag:
  `git ls-remote --tags https://github.com/lillycham/akyuu`. Below, `TAG` is
  that tag, for example `v0.2.0.0`.
- Use full paths in config files: apps do not get the `PATH` of a shell, and
  JSON and TOML do not expand `~`. Below, `AKYUU` is the full path of the binary
  (`command -v akyuu`), and `ROOT` is the full path of the store.
- At the end, report to the person (step 7).

## 1. Nix

Check: `nix --version` works, and `nix flake --help` works.

- No Nix: **Ask** the person to install it (<https://nixos.org/download>). Do
  not install it yourself. Stop until it is there.
- No flakes: **Ask** to add `experimental-features = nix-command flakes` to
  `~/.config/nix/nix.conf`.

## 2. The binary

Check: `command -v akyuu` finds it, and `akyuu --version` prints the version of
`TAG`.

Most Nix users keep their software in a configuration, not in an imperative
profile. Ask the person how they manage their setup, and where its files are.
Then use the first choice that fits:

1. **home-manager.** Use the module of the flake: it installs the binary, sets
   `AKYUU_ROOT` and makes the store directory, and it has the daily jobs of
   step 6.3. **Ask**, then add the input and the module:

   ```nix
   # flake.nix of the configuration
   inputs.akyuu.url = "github:lillycham/akyuu/TAG";

   # the home-manager configuration
   imports = [ inputs.akyuu.homeModules.default ];
   programs.akyuu = {
     enable = true;
     root = "ROOT";   # see step 3
   };
   ```

2. **NixOS or nix-darwin, with no home-manager.** **Ask**, then add the input
   and the package:

   ```nix
   inputs.akyuu.url = "github:lillycham/akyuu/TAG";

   environment.systemPackages = [ inputs.akyuu.packages.${pkgs.stdenv.hostPlatform.system}.default ];
   environment.variables.AKYUU_ROOT = "ROOT";
   ```

   (Or add `inputs.akyuu.overlays.default` and use `pkgs.akyuu`.)

3. **Nix with no configuration.** Install into the profile, and tell the person
   that this is imperative:

   ```sh
   nix profile install github:lillycham/akyuu/TAG
   ```

For a configuration: show the diff, and do not run `home-manager switch`,
`darwin-rebuild switch` or `nixos-rebuild switch` without a yes. A switch can
need `sudo`: then the person runs it. If the configuration is a git repository,
ask before you commit. A flake sees only files that git knows, so a new file
must be added with `git add` before the build.

If the configuration is not a flake, do not convert it. Ask the person what
they want.

## 3. The store

Ask the person where the store goes. The usual place is
`~/.local/share/akyuu`.

Check: `akyuu --root ROOT status`. If it shows memories, a store is there: tell
the person what it shows, and keep it. `akyuu init` keeps existing refs, so it
is safe on a store, but it is not needed.

```sh
akyuu --root ROOT init
akyuu --root ROOT status
```

`init` writes a policy for agents (`policy/memory`) and a manifest of the tiers
(`policy/tiers`). The person can change both later.

For the command line, `AKYUU_ROOT` must be set. A configuration from step 2
sets it. With a profile install, **ask** before you add
`export AKYUU_ROOT=ROOT` to a shell profile.

## 4. Connect the agent

Akyuu is an MCP server on stdio: the command is `AKYUU --root ROOT mcp`. Connect
the client that the person uses. A client sees a new server only in a new
session: tell the person.

### Claude Code

Check: `claude mcp list` shows `akyuu`.

```sh
claude mcp add --scope user akyuu -- AKYUU --root ROOT mcp
```

### Claude Desktop

**Ask** first. The file is
`~/Library/Application Support/Claude/claude_desktop_config.json` on macOS and
`%APPDATA%\Claude\claude_desktop_config.json` on Windows. Check: it has
`mcpServers.akyuu`. Add this entry to `mcpServers`, and keep the other entries:

```json
{ "mcpServers": { "akyuu": { "command": "AKYUU", "args": ["--root", "ROOT", "mcp"] } } }
```

The person must quit and open Claude Desktop again.

### Codex

Check: `codex mcp list` shows `akyuu`.

```sh
codex mcp add akyuu -- AKYUU --root ROOT mcp
```

If your Codex has no `mcp add`, **ask**, then add this to `~/.codex/config.toml`:

```toml
[mcp_servers.akyuu]
command = "AKYUU"
args = ["--root", "ROOT", "mcp"]
```

### Another MCP client

Follow the documents of the client, with the command above. Tell the person
that this guide does not test that client.

## 5. Check that it works

```sh
akyuu --root ROOT status
akyuu --root ROOT note --agent YOUR-NAME "Installed akyuu TAG."
akyuu --root ROOT search installed
```

The search must find the note. Then, in a new session of the client, call the
tool `context`. It must return the policy `policy/memory`. If you cannot start
a new session, tell the person how to do this check.

## 6. Extras

Tell the person about each extra, and ask which ones they want. Do only those.

### 6.1 Memories at the start of each session

The policy tells an agent to call `context` first. A client can also do this by
itself:

- **Claude Code.** **Ask**, then add a `SessionStart` hook to
  `~/.claude/settings.json` (keep the hooks that are there). Each hook prints
  one page, because Claude Code keeps only about 10,000 characters of the
  output of one hook ([hooks.md](hooks.md)):

  ```json
  { "hooks": { "SessionStart": [ { "hooks": [
    { "type": "command", "command": "AKYUU --root ROOT context --page 1" },
    { "type": "command", "command": "AKYUU --root ROOT context --page 2" },
    { "type": "command", "command": "AKYUU --root ROOT context --page 3" }
  ] } ] } }
  ```

- **Codex.** **Ask**, then add this line to `~/.codex/AGENTS.md`: "At the start
  of each task, call the akyuu tool `context` with `cwd` set to the working
  directory, and follow the policy that it returns."
- **Claude Desktop.** Give the person the same sentence for their instructions
  in the app. You cannot set it.

### 6.2 A profile of the person

Ask the person if they want a short profile that every session reads. Write
only what they tell you, in their words. Then put it in the tier `always`:

```sh
akyuu --root ROOT add --ref me/profile --kind user --agent YOUR-NAME --body "TEXT"
akyuu --root ROOT amend policy/tiers --from "always: policy/memory" --to "always: policy/memory me/profile"
```

### 6.3 Daily jobs, the web view and search by meaning

These need the home-manager module (step 2, choice 1). **Ask**, then add the
options that the person wants to `programs.akyuu`, with the same rules for the
diff and the switch as in step 2:

```nix
programs.akyuu = {
  enable = true;
  root = "ROOT";
  gc.enable = true;           # akyuu gc, daily at 03:30
  backup.enable = true;       # akyuu-backup, daily at 04:00
  versioning.enable = true;   # akyuu-version: a git commit of the memories, daily at 04:15
  serve.enable = true;        # the web view on http://127.0.0.1:7420
};
```

[install.md](install.md) explains each option. Search by meaning needs a model,
and the person must choose it: see [embeddings.md](embeddings.md).

Without home-manager, these jobs do not run. Tell the person that `akyuu gc`
and `akyuu serve` work by hand.

## 7. Report

Tell the person:

- the version, the root and the clients that you connected;
- the extras that you set up, and the ones that you skipped;
- each file that you changed, and its `.bak` copy or the git diff;
- what they must do now, for example open the app again or start a new session;
- that akyuu has no access control: each connected agent can read and change
  every memory, so they must not store passwords or keys in it.

Then stop following this guide. From now on, follow the policy of the store
(`policy/memory`).
