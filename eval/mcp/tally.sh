#!/usr/bin/env bash
# Turn results.tsv of the MCP evaluation into a table, by scenario and set.
#
#   eval/mcp/tally.sh results.tsv
#
# A run is clean when no check of the verifier failed, the agent finished
# (status ok), and, for S3, the other writer ran. The means are over all runs
# of the cell. Cost is in dollars.

set -u
file=${1:-}
[ -n "$file" ] && [ -r "$file" ] || {
  echo "usage: tally.sh results.tsv" >&2
  exit 2
}

awk -F'\t' '
NR == 1 { next }
{
  key = $2 SUBSEP $1
  n[key]++
  ok = ($5 == 0 && $11 == "ok" && ($2 != "S3" || $12 == "yes"))
  if (ok) clean[key]++
  calls[key] += $6
  errors[key] += $7
  cost[key] += $9
  secs[key] += $10
  if (!($2 in seen)) { seen[$2] = 1; order[++m] = $2 }
  sets[$1] = 1
}
END {
  printf "%-4s %-9s %5s %7s %9s %9s %8s %8s\n", "scn", "set", "runs", "clean", "calls", "errors", "cost", "seconds"
  for (i = 1; i <= m; i++) {
    sn = order[i]
    for (s in sets) {
      key = sn SUBSEP s
      if (!(key in n)) continue
      printf "%-4s %-9s %5d %7d %9.1f %9.1f %8.3f %8.0f\n", sn, s, n[key], clean[key] + 0, calls[key] / n[key], errors[key] / n[key], cost[key] / n[key], secs[key] / n[key]
    }
  }
}' "$file" | { read -r head; echo "$head"; sort -k1,1 -k2,2; }
