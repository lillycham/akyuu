# A check of akyuu-version, run in the Nix sandbox by `checks.version`.
set -eu
export HOME=$PWD

root=$PWD/root
mkdir "$root"
export AKYUU_ROOT=$root

a=$(akyuu add --kind fact --agent check --body "first memory")
akyuu ref set check/main "$a" --new > /dev/null
akyuu pin "$a" > /dev/null

# The first run makes the repository and one commit.
akyuu-version 2> /dev/null > /dev/null
test -d "$root/.git"
test "$(git -C "$root" rev-list --count HEAD)" = 1
git -C "$root" ls-files | grep -q '^store/'
git -C "$root" ls-files | grep -q '^refs/check/'
git -C "$root" ls-files | grep -q '^pins/'

# The cache, the locks and debris are not in it.
akyuu search first > /dev/null
echo x > "$root/store/.DS_Store"
echo x > "$root/refs/.tmp-1"
mkdir -p "$root/trash"
echo x > "$root/trash/sha256-0.md"
akyuu-version 2> /dev/null > /dev/null || true
! git -C "$root" ls-files | grep -E 'cache|\.lock|trash|DS_Store|\.tmp' > /dev/null

# A run with no change makes no commit.
before=$(git -C "$root" rev-parse HEAD)
akyuu-version 2> /dev/null > /dev/null
test "$(git -C "$root" rev-parse HEAD)" = "$before"

# A new memory and a moved ref make a commit, and the message says what.
b=$(akyuu supersede check/main --kind fact --agent check --body "second memory")
akyuu-version --message "a test" 2> /dev/null > /dev/null
test "$(git -C "$root" rev-list --count HEAD)" = 2
git -C "$root" log -1 --format=%B | grep -q "memories added"
git -C "$root" log -1 --format=%B | grep -q "a test"

# A memory that is removed from the store stays in the history.
rm "$root/store/$(echo "$b" | cut -c8-9)/$b.md"
akyuu-version 2> /dev/null > /dev/null
git -C "$root" log --diff-filter=D --name-only --format= | grep -q "$b.md"
git -C "$root" show "HEAD~1:store/$(echo "$b" | cut -c8-9)/$b.md" | grep -q "second memory"
touch $out
