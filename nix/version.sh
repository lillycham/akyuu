# akyuu-version: keep the memories of a store in a git repository.
#
# The repository is in the root of the store. It holds what cannot be made
# again: the objects (store), the refs, the pins, the reviews and the
# tombstones. The cache, the locks and the trash are not in it (.gitignore).
#
# One run makes one commit of what changed since the last run, and no commit
# if nothing changed. The history is the history of the memory: a ref moves,
# a memory is added, GC removes one. A memory that GC removed stays in the
# history, so a deleted memory can be got back with git.
#
# The order matters. `git add` goes through the directories in order, and refs
# come before store. An agent adds an object before it moves a ref to it, so a
# ref that the commit has always points at an object that the commit has.
#
# The script never pushes. Add a remote and push by hand, or in your own job.
#
# Forgetting: a memory that a person asked to forget is still in the history
# of this repository. To really remove it, rewrite the history by hand.

usage() {
  cat >&2 <<USAGE
usage: akyuu-version [--root DIR] [--message TEXT]

  --root DIR       the store root (default: \$AKYUU_ROOT)
  --message TEXT   a line to add to the commit message
USAGE
  exit 2
}

root=${AKYUU_ROOT:-}
note=

while [ $# -gt 0 ]; do
  case $1 in
    --root) [ $# -ge 2 ] || usage; root=$2; shift 2 ;;
    --message) [ $# -ge 2 ] || usage; note=$2; shift 2 ;;
    -h | --help) usage ;;
    *) usage ;;
  esac
done

[ -n "$root" ] || { echo "akyuu-version: no store root. Use --root DIR or set AKYUU_ROOT." >&2; exit 2; }
[ -d "$root/store" ] || { echo "akyuu-version: $root has no store directory." >&2; exit 1; }

g() { git -C "$root" "$@"; }

if [ ! -d "$root/.git" ]; then
  g init -q -b main
  echo "akyuu-version: made a repository in $root" >&2
fi

if [ ! -e "$root/.gitignore" ]; then
  cat > "$root/.gitignore" <<'IGNORE'
# Made by akyuu-version. These can be made again, or are not memories.
cache.sqlite*
*.lock
.lock
trash/
.DS_Store
.tmp*
IGNORE
fi

# A person's own git identity is used if there is one.
identity=()
if ! g config user.email > /dev/null 2>&1; then
  identity=(-c user.name=akyuu -c user.email=akyuu@localhost)
fi

# pins, refs, reviewed, store, tombstones: refs before store.
paths=(.gitignore)
for d in pins refs reviewed store tombstones; do
  [ -d "$root/$d" ] && paths+=("$d")
done
g add -A -- "${paths[@]}"

if g diff --cached --quiet; then
  echo "akyuu-version: nothing changed" >&2
  exit 0
fi

summary=$(g diff --cached --name-status | awk '
  $2 ~ /^store\// && $1 == "A" { added++ }
  $2 ~ /^store\// && $1 == "D" { removed++ }
  $2 ~ /^refs\//  { refs++ }
  $2 ~ /^pins\//  { pins++ }
  $2 ~ /^reviewed\// { reviews++ }
  END {
    out = ""
    if (added)   out = out added " memories added, "
    if (removed) out = out removed " removed, "
    if (refs)    out = out refs " refs changed, "
    if (pins)    out = out pins " pins changed, "
    if (reviews) out = out reviews " reviews changed, "
    sub(/, $/, "", out)
    print (out == "" ? "other changes" : out)
  }')

stamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
if [ -n "$note" ]; then
  g "${identity[@]}" commit -q -m "snapshot $stamp: $summary" -m "$note"
else
  g "${identity[@]}" commit -q -m "snapshot $stamp: $summary"
fi
g rev-parse --short HEAD
