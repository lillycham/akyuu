# shellcheck shell=bash
# shellcheck disable=SC2034,SC2154
# Section init: start a store.

sec_init() {
  use_root init

  t I01 "init exits 0 and makes the policy and the manifest"
  ak init
  need_rc 0
  need_out_has "policy/memory"
  need_out_has "policy/tiers"

  t I02 "init made two refs, and they name memories that exist"
  ak ref list
  need_rc 0
  need_eq "$(nlines "$out")" 2 "number of refs"
  p1=$(printf '%s\n' "$out" | awk '$1 == "policy/memory" { print $2 }')
  need_id "$p1"
  ak get "$p1"
  need_rc 0

  t I03 "init a second time keeps the refs where they are"
  ak ref list
  before=$out
  ak init
  need_rc 0
  ak ref list
  need_eq "$out" "$before" "refs after a second init"

  t I04 "the policy tells an agent how to use the store"
  ak get --ref policy/memory
  need_rc 0
  need_out_has "context"
  need_out_has "supersede"
  need_out_has "search"

  t I05 "the manifest names a tier called always"
  ak get --ref policy/tiers
  need_rc 0
  need_out_match '^always:'

  t I06 "status after init finds the manifest and the policy"
  ak status
  need_rc 0
  need_out_has "policy policy/memory: present"
  need_out_has "memories: 2, refs: 2"
}
