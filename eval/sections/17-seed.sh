# shellcheck shell=bash
# shellcheck disable=SC2034,SC2154
# Section seed: the demo store.

sec_seed() {
  demo="$sandbox/demo"
  rm -rf "$demo"
  mkdir -p "$demo"

  t D01 "seed --demo fills an empty directory, and says what it made"
  ak seed --demo --root "$demo"
  need_rc 0
  need_out_match 'made a demo store in .* with [0-9]+ memories'

  t D02 "the demo store has refs, and search and check work on it"
  ak --root "$demo" ref list
  need_rc 0
  [ "$(nlines "$out")" -ge 5 ] || fail "fewer than 5 refs"
  ak --root "$demo" search editor
  need_rc 0
  ak --root "$demo" check
  need_rc 0

  t D03 "seed --demo refuses a directory that has data (exit 1), and changes nothing"
  before=$(find "$demo" -type f | wc -l | tr -d ' ')
  ak seed --demo --root "$demo"
  need_rc 1
  need_text_has "not empty"
  need_eq "$(find "$demo" -type f | wc -l | tr -d ' ')" "$before" "files after the refusal"

  t D04 "the demo store shows each kind of thing that check and gc handle: a fork, garbage, a pruned target"
  ak --root "$demo" check
  need_out_has "fork"
  ak --root "$demo" gc --dry-run --grace 0s
  need_rc 0
  need_out_match 'would collect [0-9]+ object'
}
