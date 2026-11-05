# shellcheck shell=bash
# shellcheck disable=SC2034,SC2154
# Section web: the read-only web view, and the one-file export.

# Call a URL and keep the status in $status and the body in $sandbox/body.
http() {
  status=$(curl -sS -m 5 -o "$sandbox/body" -w '%{http_code}' "$@" 2>"$errf") || status="curl-failed"
  lastcmd="curl $*"
}

# The files that hold the truth: not the cache, the vectors or the lock files.
source_files() {
  (cd "$AKYUU_ROOT" && find . -type f ! -name 'cache.sqlite*' ! -name 'embeddings.sqlite*' ! -name '*.lock' | sort | xargs cat | wc -c | tr -d ' ')
}

sec_web() {
  use_root web
  "$bin" seed --demo --root "$AKYUU_ROOT" >/dev/null 2>&1
  seeded=$("$bin" ref list | head -1 | awk '{ print $2 }')

  if ! command -v curl >/dev/null 2>&1; then
    skip W01 "the web view answers requests" "curl is not installed"
  else
    files_before=$(source_files)
    "$bin" serve --port 0 >"$sandbox/serve.out" 2>"$sandbox/serve.err" </dev/null &
    srv=$!
    disown "$srv" 2>/dev/null
    servers="$servers $srv"
    url=""
    n=0
    while [ $n -lt 50 ] && [ -z "$url" ]; do
      n=$((n + 1))
      url=$(grep -o 'http://127\.0\.0\.1:[0-9]*/' "$sandbox/serve.out" 2>/dev/null | head -1)
      [ -n "$url" ] || sleep 0.1
    done

    t W01 "serve --port 0 prints the address of a free port on 127.0.0.1"
    [ -n "$url" ] || fail "no address in: $(cat "$sandbox/serve.out" "$sandbox/serve.err" | head -3)"

    t W02 "GET / is an HTML page, with security headers"
    http -D "$sandbox/headers" "$url"
    need_eq "$status" 200 "status"
    grep -q '<!doctype html>' "$sandbox/body" || fail "the body is not an HTML page"
    grep -i -q '^content-security-policy: default-src .none.' "$sandbox/headers" || fail "no Content-Security-Policy that starts from default-src 'none'"
    grep -i -q '^x-frame-options: DENY' "$sandbox/headers" || fail "no X-Frame-Options: DENY"

    t W03 "the read endpoints answer 200 with JSON: stats, refs, graph, search, gc/plan, trash, verify"
    for p in api/stats api/refs api/graph "api/search?q=editor" api/gc/plan api/trash api/verify; do
      http "$url$p"
      [ "$status" = 200 ] || fail "GET $p -> $status"
    done

    t W04 "api/refs lists the refs, and api/memory shows a memory by the start of its id"
    http "${url}api/refs"
    grep -q 'me/lang' "$sandbox/body" || fail "api/refs lacks me/lang"
    http "${url}api/memory/${seeded:0:19}"
    need_eq "$status" 200 "status for api/memory"

    t W05 "an id that no memory has is 404, an unknown path is 404, and a bad number is 400"
    http "${url}api/memory/$ZERO_ID"
    need_eq "$status" 404 "unknown memory"
    http "${url}api/nothing"
    need_eq "$status" 404 "unknown path"
    http "${url}api/graph?hops=99"
    need_eq "$status" 400 "hops=99"

    t W06 "the view is read-only: POST and DELETE are 405"
    http -X POST "${url}api/stats"
    need_eq "$status" 405 "POST"
    http -X DELETE "${url}api/stats"
    need_eq "$status" 405 "DELETE"

    t W07 "a request for another host name is refused (403), against DNS rebinding"
    http -H "Host: evil.example" "${url}api/stats"
    need_eq "$status" 403 "wrong Host"

    t W08 "a path that climbs out of the view is 404"
    http --path-as-is "${url}../store"
    need_eq "$status" 404 "path traversal"

    t W09 "the server listens on 127.0.0.1 only"
    if command -v lsof >/dev/null 2>&1; then
      listening=$(lsof -nP -a -p "$srv" -iTCP -sTCP:LISTEN 2>/dev/null | tail -n +2)
      [ -n "$listening" ] || fail "lsof shows no listening socket"
      printf '%s\n' "$listening" | grep -v '127.0.0.1:' >/dev/null && fail "a socket listens on another address: $listening"
    else
      fail "lsof is not installed, so this cannot be checked (not an akyuu fault)"
    fi

    t W10 "the requests changed nothing in the store, the refs, the pins or the trash (the cache may change: it is derived)"
    need_eq "$(source_files)" "$files_before" "files of the store, refs, pins and trash"

    t W11 "the server stops when it gets SIGTERM"
    kill "$srv" 2>/dev/null
    n=0
    while kill -0 "$srv" 2>/dev/null && [ $n -lt 30 ]; do
      n=$((n + 1))
      sleep 0.1
    done
    kill -0 "$srv" 2>/dev/null && fail "the server is still running 3 seconds after SIGTERM"
  fi

  t W12 "viz prints the whole view as one HTML file, with the data in it, and a body cannot end the script element"
  ak viz
  need_rc 0
  need_out_has "<!doctype html>"
  need_out_has 'id="akyuu-data"'
  need_out_lacks '</script><script>alert'
  [ "$(wc -c <"$outf" | tr -d ' ')" -gt 10000 ] || fail "the file is under 10 kB"

  t W13 "a memory that has HTML in its body is escaped in the export"
  use_root web-escape
  ak add --kind fact --agent tester --body '</script><script>alert(1)</script><img src=x onerror=alert(2)>'
  ak viz
  need_rc 0
  need_out_lacks '</script><script>alert(1)'
}
