#!/usr/bin/env bash
# Routing test of the staging Caddyfile (docs/staging.md "Landing page"): the real Caddyfile with
# an http-only site address (PUBLIC_DOMAIN=http://site.test, no certificates), the real site folder
# plus a planted dotfile, and a stub upstream named `api` that answers every path with "stub".
# Asserts: / and /site/* come from the folder with the CSP and a Cache-Control on success only;
# dotfiles are 404; every other path (also /site without the slash) reaches the API, without CSP.
#
# Usage: .github/scripts/staging_caddy_routing.sh [caddy image]   (repo root, needs Docker)
set -euo pipefail

image="${1:-caddy:2.11}"
port=18089
name="pillpal-routing-$$"
work="$(mktemp -d)"
# Docker Desktop on Windows (Git Bash) needs a Windows path for bind mounts.
host_path() { (cd "$1" && (pwd -W 2>/dev/null || pwd)); }
cleanup() {
  docker rm -f "$name-caddy" "$name-api" > /dev/null 2>&1 || true
  docker network rm "$name" > /dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT

mkdir -p "$work/conf" "$work/stub"
cp infra/staging/Caddyfile "$work/conf/Caddyfile"
cp -R infra/staging/site "$work/site"
printf 'secret\n' > "$work/site/site/.hidden"
cat > "$work/stub/stub.py" <<'PY'
from http.server import BaseHTTPRequestHandler, HTTPServer


class Stub(BaseHTTPRequestHandler):
    def do_GET(self) -> None:
        body = b"stub"
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


HTTPServer(("0.0.0.0", 8000), Stub).serve_forever()
PY

# Git Bash only: keep container paths as they are (no effect elsewhere). Scoped to docker, so
# curl and mktemp paths are still translated.
dock() { MSYS_NO_PATHCONV=1 docker "$@"; }
dock network create "$name" > /dev/null
dock run -d --name "$name-api" --network "$name" --network-alias api \
  -v "$(host_path "$work/stub"):/stub:ro" python:3.12-alpine python -u /stub/stub.py > /dev/null
dock run -d --name "$name-caddy" --network "$name" -p "127.0.0.1:$port:80" \
  -e PUBLIC_DOMAIN=http://site.test -e CATALOG_DOMAIN=http://catalog.test \
  -v "$(host_path "$work/conf")/Caddyfile:/etc/caddy/Caddyfile:ro" \
  -v "$(host_path "$work/site"):/srv/site:ro" "$image" > /dev/null

ready=""
for _ in $(seq 1 30); do
  if curl -fs -o /dev/null -H 'Host: site.test' "http://127.0.0.1:$port/healthz"; then ready=1; break; fi
  sleep 1
done
if [ -z "$ready" ]; then
  echo "::error::caddy or the stub upstream did not start"
  docker logs "$name-caddy" 2>&1 | tail -20
  exit 1
fi

failures=0
# expect <path> <status> <site|api|none>: site = served from the folder with CSP and
# Cache-Control; api = the stub answered, no CSP; none = no CSP-less leak and no Cache-Control.
expect() {
  local path="$1" status="$2" kind="$3" headers body got
  headers="$(mktemp)"
  local content
  content="$(mktemp)"
  curl -s -D "$headers" -o "$content" -H 'Host: site.test' "http://127.0.0.1:$port$path"
  # Only the first bytes matter (the stub answers "stub"); fonts are binary.
  body="$(head -c 4 "$content" | LC_ALL=C tr -cd 'a-z')"
  rm -f "$content"
  got="$(head -n1 "$headers" | awk '{print $2}')"
  local problems=()
  [ "$got" = "$status" ] || problems+=("status $got, want $status")
  case "$kind" in
    site)
      grep -qi '^content-security-policy:' "$headers" || problems+=("no CSP")
      grep -qi '^cache-control:' "$headers" || problems+=("no Cache-Control")
      [ "$body" != "stub" ] || problems+=("reached the API") ;;
    api)
      [ "$body" = "stub" ] || problems+=("did not reach the API")
      ! grep -qi '^content-security-policy:' "$headers" || problems+=("has the site CSP") ;;
    none)
      [ "$body" != "stub" ] || problems+=("reached the API")
      ! grep -qi '^cache-control:' "$headers" || problems+=("error response is cacheable") ;;
  esac
  rm -f "$headers"
  if [ "${#problems[@]}" -eq 0 ]; then
    echo "ok   $path -> $got ($kind)"
  else
    echo "::error::caddy routing: $path: ${problems[*]}"
    failures=$((failures + 1))
  fi
}

expect / 200 site
expect /site/site.css 200 site
expect /site/site.js 200 site
expect /site/fonts/Manrope-800.ttf 200 site
expect /site/.hidden 404 none
expect /site/ 404 none
expect /site/missing.css 404 none
expect /healthz 200 api
expect /readyz 200 api
expect /v1/x 200 api
expect /i 200 api
expect /.well-known/assetlinks.json 200 api
expect /site 200 api
expect /index.html 200 api

if [ "$failures" -ne 0 ]; then
  echo "$failures routing check(s) failed"
  exit 1
fi
echo "caddy routing: all checks passed"
