# shellcheck shell=bash
# shellcheck disable=SC2034,SC2154
# Section embed: search by meaning, with a stand-in for an embedding model.
#
# Akyuu runs no model: a command turns a text into a vector. fake-embed.sh is
# a tiny command that gives the words computer, laptop and machine one place
# in the vector, and the words space, room and disk another. A search for
# "my computer is out of room" then finds "The laptop is short of disk space."
# though they share no word.

sec_embed() {
  use_root embed
  fake="$here/fake-embed.sh"
  ak add --kind fact --agent tester --ref me/disk --body "The laptop is short of disk space."
  disk=$out
  ak add --kind fact --agent tester --ref me/garden --body "Water the tomatoes every second day."

  t B01 "with no embedding profile, status says that search by meaning is off"
  ak status
  need_out_has "search by meaning: off"

  t B02 "text mode does not find a memory that has none of the query words"
  ak search --mode text my computer is out of room
  need_rc 0
  need_out_empty

  export AKYUU_EMBED_COMMAND="$fake" AKYUU_EMBED_MODEL=fake:v1 AKYUU_EMBED_MIN=0.3
  export FAKE_EMBED_LOG="$sandbox/embed.log"
  : >"$FAKE_EMBED_LOG"

  t B03 "config shows the profile, its key, and where it came from"
  ak config
  need_rc 0
  need_out_has "embed.profile = environment"
  need_out_has "key = fake:v1"
  need_out_has "command = $fake"

  t B04 "status shows how many memories have a vector"
  ak status
  need_out_has "key fake:v1, vectors for 0 of 2 memories"

  t B05 "embed gives a vector to each memory that has none, and a second run does nothing"
  ak embed
  need_rc 0
  need_out_has "embedded 2 memories with fake:v1, 0 had one already"
  ak embed
  need_out_has "embedded 0 memories with fake:v1, 2 had one already"
  ak status
  need_out_has "vectors for 2 of 2 memories"

  t B06 "the command gets the role: document for a memory, query for a search"
  ak search --mode meaning my computer is out of room
  need_rc 0
  grep -q '^document|The laptop is short of disk space.$' "$FAKE_EMBED_LOG" || fail "no document call for the memory"
  grep -q '^query|my computer is out of room$' "$FAKE_EMBED_LOG" || fail "no query call for the search"

  t B07 "search by meaning finds the memory that has none of the query words, and says how"
  ak search --mode meaning my computer is out of room
  need_out_has "$disk"
  need_out_has "found by meaning"

  t B08 "the default mode (fused) finds it too"
  ak search my computer is out of room
  need_out_has "$disk"

  t B09 "a text search still does not find it"
  ak search --mode text my computer is out of room
  need_out_empty

  t B10 "a new memory gets its vector when it is added"
  ak add --kind fact --agent tester --body "The machine has no storage left."
  need_rc 0
  ak status
  need_out_has "vectors for 3 of 3 memories"

  t B11 "vectors with another key are never compared: the new key starts with none"
  AKYUU_EMBED_MODEL=fake:v2 ak status
  need_out_has "key fake:v2, vectors for 0 of 3 memories"
  AKYUU_EMBED_MODEL=fake:v2 ak search --mode meaning computer room
  need_rc 0
  need_text_has "text search only"

  t B12 "a command that fails does not stop add or search: they fall back to words, and say so"
  FAKE_EMBED_FAIL=1 ak add --kind fact --agent tester --body "added while the model is down"
  need_rc 0
  need_id "$out"
  FAKE_EMBED_FAIL=1 ak search --mode meaning water tomatoes
  need_rc 0
  need_out_has "tomatoes"
  need_text_has "text search only"

  t B13 "embed names each memory that failed, and the next embed fills it in"
  FAKE_EMBED_FAIL=1 ak embed
  need_text_has "1 failed"
  ak embed
  need_rc 0
  need_out_has "embedded 1 memory"
  ak status
  need_out_has "vectors for 4 of 4 memories"

  t B14 "a profile in the config file works, picked with --embed-profile"
  unset AKYUU_EMBED_COMMAND AKYUU_EMBED_MODEL AKYUU_EMBED_MIN
  cat >"$sandbox/embed.toml" <<TOML
[embed.profiles.fake]
command = "$fake"
key = "fake:toml"
query-prefix = "search_query: "
document-prefix = "search_document: "
min = 0.3
TOML
  export AKYUU_CONFIG="$sandbox/embed.toml"
  : >"$FAKE_EMBED_LOG"
  ak --embed-profile fake embed
  need_rc 0
  need_out_has "with fake:toml"
  ak --embed-profile fake search --mode meaning my computer is out of room
  need_out_has "$disk"

  t B15 "akyuu puts the prefixes of the profile before the text that it sends"
  grep -q '^document|search_document: The laptop is short of disk space.$' "$FAKE_EMBED_LOG" || fail "the document prefix is missing in: $(head -3 "$FAKE_EMBED_LOG" | tr '\n' '~')"
  grep -q '^query|search_query: my computer is out of room$' "$FAKE_EMBED_LOG" || fail "the query prefix is missing"

  t B16 "a profile that does not exist is refused, and the message names it"
  ak --embed-profile nosuchprofile status
  [ "$rc" != 0 ] || fail "an unknown profile was accepted"
  need_text_has "nosuchprofile"

  export AKYUU_CONFIG="$sandbox/none.toml"
  unset FAKE_EMBED_LOG
}
