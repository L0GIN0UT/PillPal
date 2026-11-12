#!/usr/bin/env bash
# Cases of infra/staging/check_site_domain.sh, which the deploy runs before it touches any
# container (docs/staging.md "Landing page").
# Usage: .github/scripts/check_site_domain_test.sh   (repo root)
set -euo pipefail

check="infra/staging/check_site_domain.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
failures=0

# case <accept|reject> <.env line for SITE_DOMAIN, or "" for none>
case_() {
  local want="$1" line="$2" got
  printf 'PUBLIC_DOMAIN=api.example.com\nCATALOG_DOMAIN=catalog.example.com\n' > "$work/.env"
  [ -z "$line" ] || printf '%s\n' "$line" >> "$work/.env"
  if bash "$check" "$work/.env" 2> /dev/null; then got=accept; else got=reject; fi
  if [ "$got" = "$want" ]; then
    echo "ok   $want: '$line'"
  else
    echo "::error::check_site_domain.sh: '$line' -> $got, want $want"
    failures=$((failures + 1))
  fi
}

case_ accept ""
case_ accept "SITE_DOMAIN="
case_ accept "SITE_DOMAIN=example.com"
case_ accept "SITE_DOMAIN=my-site.example.co"
case_ accept 'SITE_DOMAIN="example.com"'
case_ accept $'SITE_DOMAIN=example.com\r'
case_ accept $'SITE_DOMAIN=bad\nSITE_DOMAIN=example.com'
case_ reject "SITE_DOMAIN=https://example.com"
case_ reject "SITE_DOMAIN=example.com/"
case_ reject "SITE_DOMAIN=example.com:8443"
case_ reject "SITE_DOMAIN=*.example.com"
case_ reject "SITE_DOMAIN= example.com"
case_ reject "SITE_DOMAIN=example.com # landing"
case_ reject "SITE_DOMAIN=Example.com"
case_ reject "SITE_DOMAIN=localhost"
case_ reject "SITE_DOMAIN=-example.com"
case_ reject "SITE_DOMAIN=api.example.com"
case_ reject "SITE_DOMAIN=catalog.example.com"
case_ reject "SITE_DOMAIN=example.com"$'\n'"PUBLIC_DOMAIN=www.example.com"
case_ reject "SITE_DOMAIN=example.com"$'\n'"PUBLIC_DOMAIN=Example.COM"

if [ "$failures" -ne 0 ]; then
  echo "$failures check_site_domain case(s) failed"
  exit 1
fi
echo "check_site_domain: all cases passed"
