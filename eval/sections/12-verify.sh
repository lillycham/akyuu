# shellcheck shell=bash
# shellcheck disable=SC2034,SC2154
# Section verify: integrity, and a cache that can always be thrown away.

sec_verify() {
  use_root verify
  ak add --kind fact --agent tester --ref me/a --body "alpha text is here"
  va=$out
  ak add --kind fact --agent tester --ref me/b --body "beta text is here"
  vb=$out

  t V01 "verify of a sound store exits 0 and says ok"
  ak verify
  need_rc 0
  need_out_match '^ok: checked 2 objects'

  t V02 "an edge to an id that was never stored is a problem (exit 1) and the id is named"
  ak add --kind fact --agent tester --about "$ZERO_ID" --body "points at nothing"
  need_rc 0
  ak verify
  need_rc 1
  need_out_has "missing $ZERO_ID"
  need_out_has "problems found"

  t V03 "an object whose bytes changed is reported as corrupt (exit 1), and get refuses to print it"
  f=$(ls "$AKYUU_ROOT"/store/*/"$va".md)
  cp "$f" "$f.keep"
  printf 'X' >>"$f"
  ak verify
  need_rc 1
  need_out_has "corrupt $va"
  ak get "$va"
  need_rc 1
  need_text_has "damaged"
  mv "$f.keep" "$f"

  t V04 "a ref that points at a memory that is gone is reported (exit 1)"
  g=$(ls "$AKYUU_ROOT"/store/*/"$vb".md)
  mv "$g" "$g.moved"
  ak verify
  need_rc 1
  need_out_has "ref me/b points to missing $vb"
  mv "$g.moved" "$g"
  ak verify
  need_out_lacks "me/b"

  t V05 "reindex reads the whole store again (and says how many memories), and a search gives the same answer after it"
  ak search alpha
  before=$out
  ak reindex
  need_rc 0
  need_out_has "indexed 3 memories"
  ak search alpha
  need_out_eq "$before"

  t V06 "the cache can be deleted at any time: nothing is lost, and the next search rebuilds it"
  rm -f "$AKYUU_ROOT"/cache.sqlite*
  ak search alpha
  need_rc 0
  need_out_eq "$before"
  need_file "$AKYUU_ROOT/cache.sqlite"

  t V07 "a cache file that is not a database is replaced, not a crash"
  head -c 3000 /dev/zero | tr '\0' 'x' >"$AKYUU_ROOT/cache.sqlite"
  rm -f "$AKYUU_ROOT"/cache.sqlite-wal "$AKYUU_ROOT"/cache.sqlite-shm
  ak search alpha
  need_rc 0
  need_out_eq "$before"

  t V08 "the answers do not depend on the cache: search after deleting it matches search before"
  ak search beta
  b1=$out
  rm -f "$AKYUU_ROOT"/cache.sqlite*
  ak search beta
  need_out_eq "$b1"

  t V09 "status reports the counts"
  ak status
  need_rc 0
  need_out_match 'memories: [0-9]+, refs: 2'
}
