# shellcheck shell=bash
# shellcheck disable=SC2034,SC2154
# Section config: where each setting comes from.

sec_config() {
  use_root config

  t C01 "with no config file, config says so and shows the defaults"
  ak config
  need_rc 0
  need_out_has "file: none"
  need_out_has "policy-ref = policy/memory  (the default)"
  need_out_has "tiers-ref = policy/tiers  (the default)"
  need_out_has "embed: off"

  cat >"$sandbox/c.toml" <<TOML
root = "$sandbox/fileroot"
policy-ref = "me/pol"
agent = "fromfile"
TOML

  t C02 "a TOML config file sets the root, the policy ref and the agent, and config names the file"
  ake -u AKYUU_ROOT AKYUU_CONFIG="$sandbox/c.toml" "$bin" config
  need_rc 0
  need_out_has "file: $sandbox/c.toml"
  need_out_has "root = $sandbox/fileroot  ($sandbox/c.toml)"
  need_out_has "policy-ref = me/pol  ($sandbox/c.toml)"
  need_out_has "agent = fromfile"

  t C03 "an environment variable wins over the file"
  ake AKYUU_CONFIG="$sandbox/c.toml" AKYUU_ROOT="$sandbox/envroot" AKYUU_AGENT=fromenv "$bin" config
  need_out_has "root = $sandbox/envroot  (\$AKYUU_ROOT)"
  need_out_has "agent = fromenv  (\$AKYUU_AGENT)"

  t C04 "an option wins over the environment"
  ake AKYUU_CONFIG="$sandbox/c.toml" AKYUU_ROOT="$sandbox/envroot" "$bin" --root "$sandbox/optroot" config
  need_out_has "root = $sandbox/optroot  (the command line)"

  t C05 "an empty variable counts as no value"
  ake AKYUU_CONFIG="$sandbox/c.toml" AKYUU_ROOT= "$bin" config
  need_out_has "root = $sandbox/fileroot"

  # shellcheck disable=SC2088
  t C06 "~/ at the start of root in the file is the home directory"
  printf 'root = "~/stores/main"\n' >"$sandbox/tilde.toml"
  ake -u AKYUU_ROOT AKYUU_CONFIG="$sandbox/tilde.toml" "$bin" config
  need_out_has "root = $HOME/stores/main"

  t C07 "a key that akyuu does not know is reported as a note, and is not an error"
  printf 'root = "%s/x"\nbogus-key = 1\n' "$sandbox" >"$sandbox/unknown.toml"
  ake -u AKYUU_ROOT AKYUU_CONFIG="$sandbox/unknown.toml" "$bin" config
  need_rc 0
  need_out_has "note:"
  need_out_has "bogus-key"

  t C08 "a config file that is not valid TOML is an error (exit 2) that names the file"
  printf 'root = \n[[[' >"$sandbox/bad.toml"
  ake -u AKYUU_ROOT AKYUU_CONFIG="$sandbox/bad.toml" "$bin" config
  need_rc 2
  need_text_has "$sandbox/bad.toml"
  need_text_has "not valid"

  t C09 "config needs no store, so it works when the store does not exist"
  ake AKYUU_ROOT="$sandbox/never-made" "$bin" config
  need_rc 0
  need_out_has "root = $sandbox/never-made"

  t C10 "a command uses the root from the file when nothing else sets one"
  mkdir -p "$sandbox/fileroot"
  ake -u AKYUU_ROOT AKYUU_CONFIG="$sandbox/c.toml" "$bin" add --kind fact --agent tester --body "from the file root"
  need_rc 0
  ake -u AKYUU_ROOT AKYUU_CONFIG="$sandbox/c.toml" "$bin" status
  need_out_has "root: $sandbox/fileroot"
  need_out_has "memories: 1"
}
