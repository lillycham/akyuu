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
- Before step 2, ask the person where the store goes. The usual place is
  `~/.local/share/akyuu`. Below, `ROOT` is that place as a full path, for
  example `/Users/NAME/.local/share/akyuu` or `/home/NAME/.local/share/akyuu`.
  Config files (Nix, JSON, TOML) do not expand `~`, so always write `ROOT` in
  full.
- `AKYUU` is the full path of the binary, for config files: apps do not get the
  `PATH` of a shell. Use a path that stays the same after an upgrade, never a
  path in `/nix/store`:
  - home-manager: `/etc/profiles/per-user/NAME/bin/akyuu` when home-manager is
    a module of NixOS or nix-darwin, else `~/.nix-profile/bin/akyuu` (in full);
  - NixOS or nix-darwin: `/run/current-system/sw/bin/akyuu`;
  - a profile install: `~/.nix-profile/bin/akyuu` (in full).

  Check that the path exists before you use it.
- `YOUR-NAME` is the name of your client, for example `claude-code` or `codex`.
- At the end, report to the person (step 7).

## 1. Nix

Check: `nix --version` works, and `nix flake --help` works.

- No Nix: **Ask** the person to install it (<https://nixos.org/download>). Do
  not install it yourself. Stop until it is there.
- No flakes: **Ask** to add `experimental-features = nix-command flakes` to
  `~/.config/nix/nix.conf`.

## 2. The binary

Check: `command -v akyuu` finds it, and `akyuu --version` prints the version of
`TAG`. Then find out where it comes from:

- From the configuration of the person (a path in `/etc/profiles`,
  `/run/current-system` or the home-manager profile): skip this step.
- From an imperative install (`nix profile list` shows akyuu): tell the person.
  If they keep a configuration, ask if they want to move akyuu into it. If yes,
  do the rest of this step, and after the switch they remove the old install
  with `nix profile remove akyuu`.

Most Nix users keep their software in a configuration, not in an imperative
profile. Ask the person how they manage their setup, and where its files are.
Also ask now which extras of step 6.3 they want, so that one switch does
everything. Then use the first choice that fits:

1. **home-manager.** Use the module of the flake: it installs the binary, sets
   `AKYUU_ROOT`, makes the store directory, and has the daily jobs of step 6.3.
   **Ask**, then add the input and the module:

   ```nix
   # flake.nix of the configuration
   inputs.akyuu.url = "github:lillycham/akyuu/TAG";

   # the home-manager configuration
   imports = [ inputs.akyuu.homeModules.default ];
   programs.akyuu = {
     enable = true;
     root = "ROOT";
     # and the options of step 6.3 that the person wants
   };
   ```

   The home-manager configuration needs `inputs`. If it does not get it yet,
   pass it: `extraSpecialArgs = { inherit inputs; };` in
   `homeManagerConfiguration` (home-manager on its own), or
   `home-manager.extraSpecialArgs = { inherit inputs; };` (home-manager as a
   module of NixOS or nix-darwin).

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

For a configuration:

- Lock the new input with `nix flake update akyuu` in the directory of the
  configuration.
- A flake sees only files that git knows: `git add` a new file and the changed
  `flake.lock` before the build.
- Show the diff. If the configuration is a git repository, ask before you
  commit.
- Do not run `home-manager switch`, `darwin-rebuild switch` or
  `nixos-rebuild switch` without a yes. A switch can need `sudo`: then the
  person runs it, and you wait until it is done.
- If the configuration is not a flake, do not convert it. Ask the person what
  they want.

## 3. The store

Check: `ROOT` exists, and `akyuu --root ROOT status` shows `policy/memory` and
`policy/tiers`. If it shows other memories, a store is there: tell the person
what it shows, and keep it.

```sh
akyuu --root ROOT init
akyuu --root ROOT status
```

`init` makes `ROOT` if it is not there, and keeps existing refs. (`status` on a
missing `ROOT` says "Make it first": `init` does that.) It writes a policy for
agents (`policy/memory`) and a manifest of the tiers (`policy/tiers`). The
person can change both later.

For the command line, `AKYUU_ROOT` must be set. A configuration from step 2
sets it after the switch. With a profile install, **ask** before you add
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
a new session, ask the person to do it: "Start a new session and ask the agent
to call the akyuu tool `context`. It should show the policy `policy/memory`."

## 6. Extras

Tell the person about each extra, and ask which ones they want. Do only those.

### 6.1 Memories at the start of each session

The policy tells an agent to call `context` first. A client can also do this by
itself:

- **Claude Code.** Check: `~/.claude/settings.json` has a `SessionStart` hook
  that runs `context`. **Ask**, then add the hooks below. If the file is not
  there, make it with only this. If it is there, add to it and keep the hooks
  that are there. Then check that the file is valid JSON
  (`nix run nixpkgs#jq -- . ~/.claude/settings.json`). Each hook prints one
  page, because Claude Code keeps only about 10,000 characters of the output
  of one hook ([hooks.md](hooks.md)). A page after the last one prints
  nothing.

  ```json
  { "hooks": { "SessionStart": [ { "hooks": [
    { "type": "command", "command": "AKYUU --root ROOT context --page 1" },
    { "type": "command", "command": "AKYUU --root ROOT context --page 2" },
    { "type": "command", "command": "AKYUU --root ROOT context --page 3" }
  ] } ] } }
  ```

- **Codex.** Check: `~/.codex/AGENTS.md` has the line below. **Ask**, then add
  it: "At the start of each task, call the akyuu tool `context` with `cwd` set
  to the working directory, and follow the policy that it returns."
- **Claude Desktop.** Give the person the same sentence for their instructions
  in the app. You cannot set it.

### 6.2 A profile of the person

Ask the person if they want a short profile that every session reads. Write
only what they tell you, in their words.

Check: `akyuu --root ROOT get --ref me/profile` shows a memory. If it does, do
not add one: show it to the person, and ask if it needs a change. Else add it:

```sh
akyuu --root ROOT add --ref me/profile --kind user --agent YOUR-NAME --body "TEXT"
```

Then put it in the tier `always`. Read the manifest with
`akyuu --root ROOT get --ref policy/tiers`, and find the line that starts with
`always:`. If that line already names `me/profile`, stop. Else add `me/profile`
at its end, with the whole line as it is now (`LINE`):

```sh
akyuu --root ROOT amend policy/tiers --from "LINE" --to "LINE me/profile"
```

For a new store, `LINE` is `always: policy/memory`.

### 6.3 Daily jobs, the web view and search by meaning

These need the home-manager module (step 2, choice 1). **Ask**, then add the
options that the person wants to the `programs.akyuu` block of step 2, with the
same rules for the diff and the switch. If you asked in step 2, they are
already in, and one switch does all.

```nix
gc.enable = true;           # akyuu gc, daily at 03:30
backup.enable = true;       # akyuu-backup, daily at 04:00
versioning.enable = true;   # akyuu-version: a git commit of the memories, daily at 04:15
serve.enable = true;        # the web view on http://127.0.0.1:7420
```

Backups go to `~/.local/share/akyuu-backups` by default, on the same disk as
the store. Ask the person if they want another place (`backup.directory`), for
example another disk or a synced folder.

[install.md](install.md) explains each option. Search by meaning needs a model,
and the person must choose it: see [embeddings.md](embeddings.md).

Without home-manager, these jobs do not run. Tell the person that `akyuu gc`
and `akyuu serve` work by hand.

## 7. Report

Tell the person:

- the version, the root and the clients that you connected;
- the extras that you set up, and the ones that you skipped;
- each file that you changed, and its `.bak` copy or the git diff;
- what they must do now, for example run the switch, open the app again, or
  start a new session and check `context`;
- that akyuu has no access control: each connected agent can read and change
  every memory, so they must not store passwords or keys in it.

Then stop following this guide. From now on, follow the policy of the store
(`policy/memory`).
