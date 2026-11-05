# shellcheck shell=bash
# shellcheck disable=SC2034,SC2154
# Section backup: snapshots that can be restored, and versioning with git.

sec_backup() {
  use_root backup
  bindir=$(dirname "$bin")
  backup="$bindir/akyuu-backup"
  version="$bindir/akyuu-version"
  ak add --kind fact --agent tester --ref a/b --body "backup me"
  ak add --kind fact --agent tester --ref a/c --body "and me too"
  dest="$sandbox/dest"

  if [ ! -x "$backup" ]; then
    skip A01 "akyuu-backup makes a snapshot" "akyuu-backup is not next to akyuu"
  else
    t A01 "akyuu-backup makes a snapshot directory named by the time, and says what it copied"
    lastcmd="akyuu-backup --dest $dest"
    "$backup" --dest "$dest" >"$outf" 2>"$errf" </dev/null
    rc=$?
    out=$(cat "$outf")
    err=$(cat "$errf")
    need_rc 0
    need_eq "$(ls "$dest" | wc -l | tr -d ' ')" 1 "snapshots"
    snap1=$(ls "$dest" | head -1)
    printf '%s' "$snap1" | grep -E -q '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{6}Z$' || fail "the snapshot name is not a time: $snap1"
    need_text_has "2 objects, 2 refs"
    need_file "$dest/$snap1/store"
    need_file "$dest/$snap1/refs"

    t A02 "a snapshot restores: copy it into an empty root, reindex, and verify, ref list and search agree"
    ak ref list
    refs_now=$out
    restored="$sandbox/restored"
    rm -rf "$restored"
    mkdir -p "$restored"
    cp -R "$dest/$snap1/." "$restored/"
    ake AKYUU_ROOT="$restored" "$bin" reindex
    need_rc 0
    ake AKYUU_ROOT="$restored" "$bin" verify
    need_rc 0
    ake AKYUU_ROOT="$restored" "$bin" ref list
    need_out_eq "$refs_now"
    ake AKYUU_ROOT="$restored" "$bin" search backup
    need_out_has "[backup] me"

    t A03 "a second snapshot of a store that did not change costs almost nothing: the files are hard links"
    sleep 1.2
    "$backup" --dest "$dest" >/dev/null 2>&1
    snap2=$(ls "$dest" | tail -1)
    need_ne "$snap1" "$snap2" "the two snapshots have different names"
    f=$(cd "$dest/$snap1" && find store -type f -name '*.md' | head -1)
    i1=$(ls -i "$dest/$snap1/$f" | awk '{ print $1 }')
    i2=$(ls -i "$dest/$snap2/$f" | awk '{ print $1 }')
    need_eq "$i1" "$i2" "inode of a memory file in the two snapshots"

    t A04 "--keep N keeps only the newest N snapshots"
    sleep 1.2
    "$backup" --dest "$dest" --keep 2 >/dev/null 2>&1
    need_eq "$(ls "$dest" | wc -l | tr -d ' ')" 2 "snapshots after --keep 2"
    [ ! -e "$dest/$snap1" ] || fail "the oldest snapshot is still there"
  fi

  if [ ! -x "$version" ] || ! command -v git >/dev/null 2>&1; then
    skip A05 "akyuu-version commits the store" "akyuu-version or git is missing"
  else
    t A05 "akyuu-version makes a git repository in the root, with one commit that counts what changed"
    ake "$version"
    need_rc 0
    need_text_has "made a repository"
    need_eq "$(git -C "$AKYUU_ROOT" log --oneline | wc -l | tr -d ' ')" 1 "commits"
    need_true git -C "$AKYUU_ROOT" log -1 --format=%s | grep -q "2 memories added, 2 refs changed" || fail "the commit message does not count the changes: $(git -C "$AKYUU_ROOT" log -1 --format=%s)"

    t A06 "a second run with no change makes no commit"
    ake "$version"
    need_rc 0
    need_text_has "nothing changed"
    need_eq "$(git -C "$AKYUU_ROOT" log --oneline | wc -l | tr -d ' ')" 1 "commits"

    t A07 "a change makes one more commit, and --message adds a line"
    ak add --kind fact --agent tester --body "another memory"
    ake "$version" --message "the second run"
    need_rc 0
    need_eq "$(git -C "$AKYUU_ROOT" log --oneline | wc -l | tr -d ' ')" 2 "commits"
    git -C "$AKYUU_ROOT" log -1 --format=%B | grep -q "the second run" || fail "the message line is not in the commit"

    t A08 "the cache and the lock files are not committed (they can be made again)"
    git -C "$AKYUU_ROOT" ls-files | grep -q 'cache.sqlite' && fail "cache.sqlite is in git"
    git -C "$AKYUU_ROOT" ls-files | grep -q 'embeddings.sqlite' && fail "embeddings.sqlite is in git"
  fi
}
