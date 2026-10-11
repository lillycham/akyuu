# A check of akyuu-backup, run in the Nix sandbox by `checks.backup`.
set -eu

root=$PWD/root
dest=$PWD/backups
mkdir "$root"
export AKYUU_ROOT=$root

a=$(akyuu add --kind fact --agent check --body "first memory")
b=$(akyuu add --kind fact --agent check --body "second memory")
akyuu ref set check/main "$a" --new > /dev/null
akyuu supersede check/main --kind fact --agent check --body "third memory" > /dev/null

# Debris of a file manager and of an unfinished write must not be copied.
echo x > "$root/store/.DS_Store"
echo x > "$root/refs/.tmp-1234"

first=$(akyuu-backup --dest "$dest" 2> /dev/null)
test -d "$first/store"
test -d "$first/refs"
test ! -e "$first/store/.DS_Store"
test ! -e "$first/refs/.tmp-1234"
test ! -e "$first/cache.sqlite"

# The snapshot is a store that akyuu can read: restore it and verify.
restored=$PWD/restored
mkdir "$restored"
cp -R "$first/." "$restored/"
akyuu --root "$restored" reindex > /dev/null
akyuu --root "$restored" verify > /dev/null
test "$(akyuu --root "$restored" ref get check/main)" = "$(akyuu ref get check/main)"
akyuu --root "$restored" get "$b" > /dev/null

# A second snapshot of a store that did not change links to the first.
sleep 1
second=$(akyuu-backup --dest "$dest" 2> /dev/null)
test "$first" != "$second"
obj=$(find "$first/store" -type f -name '*.md' | head -n 1)
rel=${obj#"$first"/}
test "$(stat -c %i "$first/$rel")" = "$(stat -c %i "$second/$rel")"

# The keep limit removes the oldest snapshots.
sleep 1
akyuu-backup --dest "$dest" --keep 2 > /dev/null 2>&1
test "$(find "$dest" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')" = 2
test ! -e "$first"

# A root with no store is refused.
mkdir "$PWD/empty"
if akyuu-backup --root "$PWD/empty" --dest "$dest" > /dev/null 2>&1; then
  echo "expected a failure for a root with no store" >&2
  exit 1
fi

touch "$out"
