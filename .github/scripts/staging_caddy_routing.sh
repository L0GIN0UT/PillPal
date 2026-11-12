#!/usr/bin/env bash
# Routing test of the staging Caddyfile (docs/staging.md "Landing page"): the real Caddyfile, the
# real site folder plus a planted dotfile, and a stub upstream named `api` that answers every path
# with "stub". Two runs, one per landing mode (the compose file derives LANDING_MODE from
# SITE_DOMAIN):
# - SITE_DOMAIN unset: http-only site addresses (PUBLIC_DOMAIN=http://site.test, no certificates).
#   / and /site/* come from the folder with the CSP and a Cache-Control on success only; dotfiles
#   are 404; every other path (also /site without the slash) reaches the API, without CSP.
# - SITE_DOMAIN set: real host names over https with Caddy's internal CA (`local_certs` is added
#   to a copy only, so no ACME). The site host serves only the landing page (everything else 404,
#   never the API); www redirects there permanently; the API host redirects / and /site/* there
#   and still proxies every other path.
#
# Usage: .github/scripts/staging_caddy_routing.sh [caddy image]   (repo root, needs Docker)
set -euo pipefail

image="${1:-caddy:2.11}"
http_port=18089
https_port=18443
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
# Test-only copy for the https run: the internal CA instead of ACME, no trust store changes.
awk '{ print } !done && $0 == "{" { print "\tlocal_certs"; print "\tskip_install_trust"; done = 1 }' \
  infra/staging/Caddyfile > "$work/conf/Caddyfile.local_certs"
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

# fetch <url> [curl options...]: any host name goes to the local Caddy port of the URL's scheme;
# -k because the https run uses Caddy's internal CA.
fetch() {
  local url="$1" port="$http_port"
  shift
  if [ "${url%%://*}" = https ]; then port="$https_port"; fi
  curl -sk --connect-to "::127.0.0.1:$port" "$@" "$url"
}

# Git Bash only: keep container paths as they are (no effect elsewhere). Scoped to docker, so
# curl and mktemp paths are still translated.
dock() { MSYS_NO_PATHCONV=1 docker "$@"; }
dock network create "$name" > /dev/null
dock run -d --name "$name-api" --network "$name" --network-alias api \
  -v "$(host_path "$work/stub"):/stub:ro" python:3.12-alpine python -u /stub/stub.py > /dev/null

# start_caddy <file in $work/conf> <health URL> [docker run options...]
start_caddy() {
  local config="$1" health="$2"
  shift 2
  docker rm -f "$name-caddy" > /dev/null 2>&1 || true
  dock run -d --name "$name-caddy" --network "$name" \
    -p "127.0.0.1:$http_port:80" -p "127.0.0.1:$https_port:443" "$@" \
    -v "$(host_path "$work/conf")/$config:/etc/caddy/Caddyfile:ro" \
    -v "$(host_path "$work/site"):/srv/site:ro" "$image" > /dev/null
  for _ in $(seq 1 30); do
    if fetch "$health" -f -o /dev/null; then return 0; fi
    sleep 1
  done
  echo "::error::caddy or the stub upstream did not start"
  docker logs "$name-caddy" 2>&1 | tail -20
  exit 1
}

failures=0
# expect <url> <status> <site|api|none|redirect> [location]: site = served from the folder with
# CSP and Cache-Control; api = the stub answered, no CSP; none = no CSP-less leak and no
# Cache-Control; redirect = Location is exactly <location> and the API was not reached.
expect() {
  local url="$1" status="$2" kind="$3" location="${4:-}" headers content body got
  headers="$(mktemp)"
  content="$(mktemp)"
  fetch "$url" -D "$headers" -o "$content" || true
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
    redirect)
      local got_location
      got_location="$(grep -i '^location:' "$headers" | head -n1 | cut -d' ' -f2- | tr -d '\r')"
      [ "$got_location" = "$location" ] || problems+=("location '$got_location', want '$location'")
      [ "$body" != "stub" ] || problems+=("reached the API") ;;
  esac
  rm -f "$headers"
  if [ "${#problems[@]}" -eq 0 ]; then
    echo "ok   $url -> $got ($kind)"
  else
    echo "::error::caddy routing: $url: ${problems[*]}"
    failures=$((failures + 1))
  fi
}

echo "--- SITE_DOMAIN unset: the landing page is on the API host"
start_caddy Caddyfile http://site.test/healthz \
  -e PUBLIC_DOMAIN=http://site.test -e CATALOG_DOMAIN=http://catalog.test
api=http://site.test
expect "$api/" 200 site
expect "$api/site/site.css" 200 site
expect "$api/site/site.js" 200 site
expect "$api/site/fonts/Manrope-800.ttf" 200 site
expect "$api/site/.hidden" 404 none
expect "$api/site/" 404 none
expect "$api/site/missing.css" 404 none
expect "$api/healthz" 200 api
expect "$api/readyz" 200 api
expect "$api/v1/x" 200 api
expect "$api/i" 200 api
expect "$api/.well-known/assetlinks.json" 200 api
expect "$api/site" 200 api
expect "$api/index.html" 200 api

echo "--- SITE_DOMAIN set: the landing page has its own host"
start_caddy Caddyfile.local_certs https://api.test/healthz \
  -e PUBLIC_DOMAIN=api.test -e CATALOG_DOMAIN=catalog.test \
  -e SITE_DOMAIN=landing.test -e LANDING_MODE=api_host_to_site_domain
site=https://landing.test
www=https://www.landing.test
api=https://api.test
expect "$site/" 200 site
expect "$site/site/site.css" 200 site
expect "$site/site/site.js" 200 site
expect "$site/site/fonts/Manrope-800.ttf" 200 site
expect "$site/site/.hidden" 404 none
expect "$site/site/" 404 none
expect "$site/site/missing.css" 404 none
expect "$site/healthz" 404 none
expect "$site/readyz" 404 none
expect "$site/v1/x" 404 none
expect "$site/i" 404 none
expect "$site/.well-known/assetlinks.json" 404 none
expect "$site/site" 404 none
expect "$site/index.html" 404 none
expect "$www/" 301 redirect "$site/"
expect "$www/site/site.css?v=1" 301 redirect "$site/site/site.css?v=1"
expect "$www/v1/x" 301 redirect "$site/v1/x"
expect "$api/" 302 redirect "$site/"
expect "$api/?ref=x" 302 redirect "$site/?ref=x"
expect "$api/site/site.css" 302 redirect "$site/site/site.css"
expect "$api/healthz" 200 api
expect "$api/readyz" 200 api
expect "$api/v1/x" 200 api
expect "$api/i" 200 api
expect "$api/.well-known/assetlinks.json" 200 api
expect "$api/site" 200 api
expect "$api/index.html" 200 api
expect "http://landing.test/" 308 redirect "$site/"

if [ "$failures" -ne 0 ]; then
  echo "$failures routing check(s) failed"
  exit 1
fi
echo "caddy routing: all checks passed"
