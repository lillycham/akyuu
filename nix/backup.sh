# akyuu-backup: a snapshot of the parts of a store that are not rebuildable.
#
# The cache (cache.sqlite) is not copied: `akyuu reindex` makes it again.
# Each snapshot is a directory with the name of its time. A file that did not
# change since the last snapshot is a hard link to it, so a snapshot of a
# store that did not change costs almost nothing. Objects never change, so
# this holds for nearly the whole store.
#
# The order of the copy matters. The objects (store, trash, tombstones, pins)
# come first and the refs last. An agent adds an object before it moves a ref
# to it, so every ref in the snapshot points to an object in the snapshot.
#
# To restore: copy the directories of a snapshot into an empty root, then
# run `akyuu --root ROOT reindex`.

usage() {
  cat >&2 <<USAGE
usage: akyuu-backup [--root DIR] --dest DIR [--keep N]

  --root DIR   the store root (default: \$AKYUU_ROOT)
  --dest DIR   the directory that holds the snapshots
  --keep N     how many snapshots to keep (default: 14)
USAGE
  exit 2
}

root=${AKYUU_ROOT:-}
dest=
keep=14

while [ $# -gt 0 ]; do
  case $1 in
    --root) [ $# -ge 2 ] || usage; root=$2; shift 2 ;;
    --dest) [ $# -ge 2 ] || usage; dest=$2; shift 2 ;;
    --keep) [ $# -ge 2 ] || usage; keep=$2; shift 2 ;;
    -h | --help) usage ;;
    *) usage ;;
  esac
done

[ -n "$root" ] || { echo "akyuu-backup: no store root. Use --root DIR or set AKYUU_ROOT." >&2; exit 2; }
[ -n "$dest" ] || { echo "akyuu-backup: no destination. Use --dest DIR." >&2; exit 2; }
[ -d "$root/store" ] || { echo "akyuu-backup: $root has no store directory." >&2; exit 1; }
case $keep in '' | *[!0-9]*) echo "akyuu-backup: --keep needs a number." >&2; exit 2 ;; esac
[ "$keep" -ge 1 ] || { echo "akyuu-backup: --keep must be at least 1." >&2; exit 2; }

mkdir -p "$dest"
stamp=$(date -u +%Y-%m-%dT%H%M%SZ)
snap=$dest/$stamp
tmp=$dest/.incomplete-$stamp
[ ! -e "$snap" ] || { echo "akyuu-backup: $snap exists already. Try again in a second." >&2; exit 1; }

prev=$(find "$dest" -mindepth 1 -maxdepth 1 -type d -name '20*' | sort | tail -n 1)

# An unfinished snapshot of a run that died is removed here.
trap 'rm -rf "$tmp"' EXIT
mkdir "$tmp"

for d in store trash tombstones pins refs; do
  [ -d "$root/$d" ] || continue
  if [ -n "$prev" ] && [ -d "$prev/$d" ]; then
    rsync -a --exclude '.DS_Store' --exclude '.tmp*' --exclude '.lock' \
      --link-dest="$prev/$d" "$root/$d/" "$tmp/$d/"
  else
    rsync -a --exclude '.DS_Store' --exclude '.tmp*' --exclude '.lock' \
      "$root/$d/" "$tmp/$d/"
  fi
done

mv "$tmp" "$snap"

# Keep the newest N snapshots.
find "$dest" -mindepth 1 -maxdepth 1 -type d -name '20*' | sort | head -n "-$keep" | while read -r old; do
  rm -rf "$old"
done

objects=$(find "$snap/store" -type f -name '*.md' | wc -l | tr -d ' ')
refs=$(find "$snap/refs" -type f 2>/dev/null | wc -l | tr -d ' ')
echo "$snap"
echo "akyuu-backup: $objects objects, $refs refs" >&2
