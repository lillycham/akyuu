#!/bin/sh
# A tiny stand-in for an embedding model, for tests only. It reads a text on
# stdin and prints a vector of 64 numbers as a JSON array.
#
# Each word counts in one place of the vector, chosen by a hash of the word.
# A few words share a place on purpose (computer, laptop, machine, pc), so
# that a search can find a text that has none of the query words. This gives
# the checks a "meaning" that is the same on every machine.
#
# If FAKE_EMBED_LOG is set, the command appends one line to that file for each
# call: the role akyuu gave it (query or document), a bar, and the text.
# FAKE_EMBED_FAIL=1 makes the command fail, to test that akyuu copes.
if [ "${FAKE_EMBED_FAIL:-}" = 1 ]; then
  echo "fake-embed: failing on purpose" >&2
  exit 1
fi
text=$(cat)
if [ -n "${FAKE_EMBED_LOG:-}" ]; then
  printf '%s|%s\n' "${AKYUU_EMBED_ROLE:-}" "$text" >>"$FAKE_EMBED_LOG"
fi
printf '%s\n' "$text" | tr 'A-Z' 'a-z' | tr -c 'a-z0-9\n' ' ' | awk '
BEGIN {
  n = split("computer laptop machine pc|space room storage disk|quick fast speedy|car vehicle automobile|doctor physician", g, "|")
  for (i = 1; i <= n; i++) {
    m = split(g[i], w, " ")
    for (j = 1; j <= m; j++) canon[w[j]] = w[1]
  }
  for (i = 0; i < 64; i++) v[i] = 0
  for (c = 32; c < 127; c++) ord[sprintf("%c", c)] = c
}
{
  for (i = 1; i <= NF; i++) {
    word = ($i in canon) ? canon[$i] : $i
    h = 7
    for (k = 1; k <= length(word); k++) h = (h * 31 + ord[substr(word, k, 1)]) % 64
    v[h] += 1
  }
}
END {
  s = 0
  for (i = 0; i < 64; i++) s += v[i] * v[i]
  s = sqrt(s)
  if (s == 0) s = 1
  out = "["
  for (i = 0; i < 64; i++) out = out sprintf("%s%.6f", (i ? "," : ""), v[i] / s)
  print out "]"
}'
