#!/usr/bin/env bash
# Checks SITE_DOMAIN in a staging .env before the deploy touches any container
# (docs/staging.md "Landing page"). A changed variable recreates the caddy container, and a value
# Caddy cannot adapt (a scheme, a path, a wildcard, a space, the API or catalog host) leaves it
# without any config: the API and catalog hosts would go down with the landing page.
# Empty or missing SITE_DOMAIN is fine (the landing page stays on PUBLIC_DOMAIN).
#
# Usage: check_site_domain.sh <path to .env>   (reads the file, never sources it)
set -euo pipefail

env_file="${1:?usage: check_site_domain.sh <path to .env>}"

# The last assignment wins, as in compose. One pair of surrounding quotes is accepted.
value() {
  local raw
  raw="$(grep -E "^$1=" "$env_file" | tail -n1 | cut -d= -f2- || true)"
  raw="${raw%$'\r'}"
  case "$raw" in
    \"*\") raw="${raw#\"}"; raw="${raw%\"}" ;;
    \'*\') raw="${raw#\'}"; raw="${raw%\'}" ;;
  esac
  printf '%s' "$raw"
}

site="$(value SITE_DOMAIN)"
[ -n "$site" ] || exit 0

label='[a-z0-9]([a-z0-9-]*[a-z0-9])?'
if ! printf '%s' "$site" | grep -Eqx "$label(\.$label)+"; then
  echo "SITE_DOMAIN in $env_file must be a lower-case host name only (e.g. example.com): no scheme, port, path, slash, wildcard, space or comment" >&2
  exit 1
fi
for name in PUBLIC_DOMAIN CATALOG_DOMAIN; do
  other="$(value "$name" | tr '[:upper:]' '[:lower:]')"
  if [ "$site" = "$other" ] || [ "www.$site" = "$other" ]; then
    echo "SITE_DOMAIN in $env_file must differ from $name (and www.SITE_DOMAIN too)" >&2
    exit 1
  fi
done
