#!/bin/sh
# Asserts what PNPM_VERSION accepts and what it refuses.
#
# The installer is sourced with its last line — the call that performs an
# install — removed, and its `download` replaced by a fixed packument. Every
# case below is decided by the shipped resolution code, and none of them reach
# the network.
set -eu

here="$(cd "$(dirname "$0")" && pwd)"
root="$(dirname "$here")"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT INT TERM

sed '$d' "$root/install.sh" > "$work/installer.sh"

# Shaped like the real thing, and pinned: `latest-12` is deliberately absent, so
# a major that has been published but not yet promoted stays covered here after
# it is promoted for real.
cat > "$work/packument.json" <<'EOF'
{"name":"pnpm","dist-tags":{"latest":"11.24.0","latest-10":"10.34.5","next-10":"10.34.5","latest-11":"11.24.0","next-11":"11.24.0","next-12":"12.0.0"},"versions":{}}
EOF

# shellcheck source=/dev/null
. "$work/installer.sh"

download() { cat "$work/packument.json"; }

failures=0

fail() {
  failures=$((failures + 1))
  echo "FAIL $1"
  echo "  expected: $2"
  echo "  actual:   $3"
}

# PNPM_VERSION="$1" resolves to version "$2".
expect_version() {
  actual="$( (resolve_version "$1"; printf '%s' "$RESOLVED_VERSION") 2>&1 || true )"
  if [ "$actual" = "$2" ]; then
    echo "ok   $1 -> $2"
  else
    fail "$1" "$2" "$actual"
  fi
}

# PNPM_VERSION="$1" names nothing published, and the refusal says so and lists
# what it could have named instead.
expect_unresolvable() {
  actual="$( (resolve_version "$1") 2>&1 || true )"
  case "$actual" in
    *"Sorry! pnpm \"$1\" could not be found."*"next-12:12.0.0"*)
      echo "ok   $1 unresolvable" ;;
    *) fail "$1" 'a refusal listing the available tags' "$(printf '%s' "$actual" | tr '\n' ' ')" ;;
  esac
}

# PNPM_VERSION="$1" is refused, with "$2" somewhere in the message.
expect_refusal() {
  actual="$( (PNPM_VERSION="$1" download_and_install) 2>&1 || true )"
  case "$actual" in
    *"$2"*) echo "ok   $1 refused" ;;
    *) fail "$1" "a refusal mentioning \"$2\"" "$(printf '%s' "$actual" | tr '\n' ' ')" ;;
  esac
}

# A bare major takes the major's stable tag when there is one, and the
# prerelease lane until it is promoted. This is the whole point of the feature:
# `12` has to install pnpm 12 on the day it lands.
expect_version 10 10.34.5
expect_version 12 12.0.0
expect_version v12 12.0.0

# Dist-tags and exact versions, unchanged.
expect_version latest 11.24.0
expect_version next-12 12.0.0
expect_version 11.20.0 11.20.0
expect_version v11.20.0 11.20.0
expect_version 12.0.0-rc.1 12.0.0-rc.1

# A major nobody has published anything for, and a tag nobody has published.
expect_unresolvable 99
expect_unresolvable bogus

# A partial version is not a version the registry holds. Refused here, rather
# than passed on for the registry to answer with a 404.
expect_refusal 12.0 'Invalid pnpm version: 12.0'
expect_refusal 11.0 'Invalid pnpm version: 11.0'

# A version is used to build the URLs that are fetched, so it may not carry a
# path — and this one gets past the shape test above.
expect_refusal '12.0.0/../../@evil/pkg' 'Invalid pnpm version'

if [ "$failures" -gt 0 ]; then
  echo "$failures case(s) failed"
  exit 1
fi
echo "all cases passed"
