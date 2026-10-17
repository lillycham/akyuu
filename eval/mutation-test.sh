#!/usr/bin/env bash
# Test the checks themselves: run them against copies of akyuu that are broken
# on purpose, and make sure that each break is noticed.
#
#   eval/mutation-test.sh [--bin PATH]
#
# A "mutant" is a wrapper around the real akyuu that changes one behaviour: it
# cuts the end of `get`, ignores --expect, finds nothing in `search`, and so
# on. The checks must report at least one FAIL for each mutant. A mutant that
# no check notices (it "survives") means that a behaviour has no check: add one.
# The exit status is 0 if no mutant survived.
set -u

here=$(cd "$(dirname "$0")" && pwd)
bin=${AKYUU_BIN:-akyuu}
if [ "${1:-}" = --bin ]; then bin=$2; fi
real=$(command -v "$bin") || {
  echo "cannot find akyuu: $bin" >&2
  exit 3
}
case $real in /*) ;; *) real="$(pwd)/$real" ;; esac

tmp=$(mktemp -d "${TMPDIR:-/tmp}/akyuu-mutants.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

cat >"$tmp/mutant.sh" <<SHIM
#!/usr/bin/env bash
real="$real"
strip_opt() {
  local opt=\$1
  shift
  local skip=0 a
  for a in "\$@"; do
    if [ \$skip = 1 ]; then skip=0; continue; fi
    if [ "\$a" = "\$opt" ]; then skip=1; continue; fi
    printf '%s\\0' "\$a"
  done
}
case "\${MUTANT:-}" in
get-cuts-last-byte)
  if [ "\${1:-}" = get ]; then "\$real" "\$@" | sed '\$ s/.\$//'; exit "\${PIPESTATUS[0]}"; fi ;;
supersede-ignores-expect)
  if [ "\${1:-}" = supersede ]; then
    args=()
    while IFS= read -r -d '' x; do args+=("\$x"); done < <(strip_opt --expect "\$@")
    exec "\$real" "\${args[@]}"
  fi ;;
search-finds-nothing) [ "\${1:-}" = search ] && exit 0 ;;
verify-always-ok) [ "\${1:-}" = verify ] && { echo "ok: checked 0 objects"; exit 0; } ;;
gc-collects-nothing) [ "\${1:-}" = gc ] && { echo "would collect 0 objects"; exit 0; } ;;
ref-new-ignored)
  if [ "\${1:-}" = ref ] && [ "\${2:-}" = set ]; then
    args=()
    for a in "\$@"; do [ "\$a" = --new ] || args+=("\$a"); done
    exec "\$real" "\${args[@]}"
  fi ;;
log-oldest-first)
  if [ "\${1:-}" = log ]; then "\$real" "\$@" | sort; exit "\${PIPESTATUS[0]}"; fi ;;
errors-exit-0) "\$real" "\$@"; exit 0 ;;
mcp-no-hint)
  if [ "\${1:-}" = mcp ]; then "\$real" "\$@" | sed "s/ (did you mean '[a-z_]*'?)//"; exit "\${PIPESTATUS[0]}"; fi ;;
add-prints-bad-id)
  if [ "\${1:-}" = add ]; then "\$real" "\$@" | sed 's/sha256-/sha-/'; exit "\${PIPESTATUS[0]}"; fi ;;
reindex-does-nothing) [ "\${1:-}" = reindex ] && exit 0 ;;
amend-drops-edges)
  if [ "\${1:-}" = amend ]; then
    "\$real" "\$@" >/dev/null || exit \$?
    r=\$2
    body=\$("\$real" get --ref "\$r" | tail -n +5)
    printf '%s' "\$body" | "\$real" supersede "\$r" --kind fact --agent amended
    exit \$?
  fi ;;
esac
exec "\$real" "\$@"
SHIM
chmod +x "$tmp/mutant.sh"

# mutant name, then the sections whose checks must notice it
mutants="
get-cuts-last-byte|memories
supersede-ignores-expect|supersede concurrency
search-finds-nothing|search
verify-always-ok|verify
gc-collects-nothing|gc
ref-new-ignored|refs
log-oldest-first|logs
errors-exit-0|memories refs
mcp-no-hint|mcp
add-prints-bad-id|memories
reindex-does-nothing|verify
amend-drops-edges|supersede
"

printf '%s\n' "$mutants" | while IFS='|' read -r name sections; do
  [ -n "$name" ] || continue
  # shellcheck disable=SC2086
  fails=$(MUTANT=$name "$here/checks.sh" --bin "$tmp/mutant.sh" $sections 2>&1 | grep -c '^FAIL')
  if [ "$fails" -gt 0 ]; then
    printf 'caught    %-26s (%s checks failed)\n' "$name" "$fails"
  else
    printf 'SURVIVED  %-26s no check noticed it\n' "$name"
    echo x >>"$tmp/survivors"
  fi
done
if [ -s "$tmp/survivors" ]; then
  echo "some mutants survived: add a check for each"
  exit 1
fi
echo "every mutant was caught"
