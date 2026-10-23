#!/usr/bin/env bash
# A stdio proxy between an MCP client and `akyuu mcp`, for the MCP evaluation.
#
#   proxy.sh --bin AKYUU --root DIR --tool-set SET [--interfere S3]
#
# It starts `akyuu --root DIR mcp --tool-set SET` and passes every line of its
# own standard input to the server. The server writes to the same standard
# output, so the answers do not pass through the proxy.
#
# With --interfere S3, the proxy does what another agent does in scenario S3:
# just before the first write call of the client (amend, supersede, replace,
# revise or add_to), it appends a line to the baking routine of Mira with the
# command line. The client has read the memory by then, or it writes without
# reading. Either way the write meets a store that has changed. The proxy
# makes the file `interfered` in the parent directory of the root when the
# other writer has run, so the runner can tell.
#
# It needs bash 3.2 or newer and mkfifo. It never reads or writes any other
# store: AKYUU_ROOT is set to DIR, and the config file is switched off.

set -u

bin=""
root=""
set_name=ordinary
interfere=none
while [ $# -gt 0 ]; do
  case $1 in
  --bin)
    bin=$2
    shift 2
    ;;
  --root)
    root=$2
    shift 2
    ;;
  --tool-set)
    set_name=$2
    shift 2
    ;;
  --interfere)
    interfere=$2
    shift 2
    ;;
  *)
    echo "proxy.sh: unknown argument: $1" >&2
    exit 2
    ;;
  esac
done
if [ -z "$bin" ] || [ ! -x "$bin" ] || [ -z "$root" ] || [ ! -d "$root" ]; then
  echo "proxy.sh: give --bin (an executable) and --root (a directory that exists)" >&2
  exit 2
fi

export AKYUU_ROOT="$root"
export AKYUU_CONFIG=/nonexistent.toml
unset AKYUU_POLICY_REF AKYUU_TIERS_REF AKYUU_AGENT AKYUU_EMBED_PROFILE AKYUU_EMBED_COMMAND AKYUU_EMBED_MODEL

work=$(mktemp -d "${TMPDIR:-/tmp}/akyuu-proxy.XXXXXX")
trap 'rm -rf "$work"' EXIT
mkfifo "$work/in"
flag="$work/interfered"
marker="$(dirname "$root")/interfered"

# What the other agent does in S3.
interfere_S3() {
  if "$bin" --root "$root" amend people/mira/routine --append "She also bakes rye on Wednesdays." --agent other-agent >/dev/null 2>&1; then
    : >"$marker"
  else
    echo "proxy.sh: the other writer failed" >&2
  fi
}

write_re='"name" *: *"(amend|supersede|replace|revise|add_to)"'

"$bin" --root "$root" mcp --tool-set "$set_name" <"$work/in" &
server=$!
exec 3>"$work/in"

while IFS= read -r line; do
  if [ "$interfere" = S3 ] && [ ! -e "$flag" ]; then
    case $line in
    *'"tools/call"'*)
      if printf '%s' "$line" | grep -E -q "$write_re"; then
        : >"$flag"
        interfere_S3
      fi
      ;;
    esac
  fi
  printf '%s\n' "$line" >&3
done

exec 3>&-
wait "$server"
