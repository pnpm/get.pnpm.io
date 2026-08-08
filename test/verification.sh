#!/bin/sh
# Drives every way the v12 verification can fail, and asserts the installer
# refuses and installs nothing.
#
# The installer talks to a fixed registry, so each case runs against a copy with
# that one URL repointed at the mock. Everything else is the shipped script.
set -eu

script="${1:-install.sh}"
here="$(cd "$(dirname "$0")" && pwd)"
root="$(dirname "$here")"
work="$(mktemp -d)"
trap 'rm -rf "$work"; kill "${server_pid:-}" 2>/dev/null || true' EXIT INT TERM

# A concrete version, so the run does not depend on the mock serving packuments.
version="$(curl -fsSL https://registry.npmjs.org/pnpm | tr -d ' \n' \
  | sed 's/.*"dist-tags":{//; s/}.*//' | tr ',' '\n' | tr -d '"' \
  | grep '^next-12:' | head -n 1 | sed 's/^next-12://')"
[ -n "$version" ] || { echo "could not resolve next-12"; exit 1; }
echo "testing $script against pnpm $version"

failures=0

expect_refusal() {
  mode="$1"
  expected="$2"
  port="$3"

  node "$here/mock-registry.mjs" "$mode" "$port" > "$work/server.log" 2>&1 &
  server_pid=$!
  # Wait for the port rather than sleeping a guessed amount.
  i=0
  while ! curl -fsS "http://127.0.0.1:$port/pnpm/$version" > /dev/null 2>&1; do
    i=$((i + 1))
    [ "$i" -lt 50 ] || { echo "mock registry did not start"; cat "$work/server.log"; exit 1; }
    sleep 0.2
  done

  home="$work/home-$mode"
  mkdir -p "$home"
  case "$script" in
    *.ps1)
      sed "s|\$NpmRegistry = 'https://registry.npmjs.org'|\$NpmRegistry = 'http://127.0.0.1:$port'|" \
        "$root/$script" > "$work/patched.ps1"
      set +e
      output="$(cd "$home" && HOME="$home" PNPM_HOME="$home/pnpm" PNPM_VERSION="$version" \
        pwsh -NoProfile "$work/patched.ps1" 2>&1)"
      code=$?
      set -e
      ;;
    *)
      sed "s|NPM_REGISTRY='https://registry.npmjs.org'|NPM_REGISTRY='http://127.0.0.1:$port'|" \
        "$root/$script" > "$work/patched.sh"
      set +e
      output="$(cd "$home" && HOME="$home" PNPM_HOME="$home/pnpm" PNPM_VERSION="$version" \
        SHELL=/bin/sh sh "$work/patched.sh" 2>&1)"
      code=$?
      set -e
      ;;
  esac

  kill "$server_pid" 2>/dev/null || true
  wait "$server_pid" 2>/dev/null || true

  if [ "$code" -eq 0 ]; then
    echo "FAIL [$mode] the installer exited 0"
    failures=$((failures + 1))
  elif ! printf '%s' "$output" | grep -qF "$expected"; then
    echo "FAIL [$mode] expected \"$expected\", got:"
    printf '%s\n' "$output" | sed 's/^/      /'
    failures=$((failures + 1))
  elif [ -e "$home/pnpm/bin/pnpm" ] || [ -e "$home/pnpm/pnpm" ]; then
    echo "FAIL [$mode] refused, yet pnpm was installed"
    failures=$((failures + 1))
  else
    echo "ok   [$mode] $expected"
  fi
}

expect_refusal bad-tarball 'does not match the checksum' 8971
expect_refusal bad-integrity 'is not valid' 8972
expect_refusal no-signature 'carries no npm registry signature' 8973
expect_refusal wrong-keyid 'unexpected npm key' 8974
expect_refusal no-integrity 'published no checksum' 8975

[ "$failures" -eq 0 ] || { echo "$failures case(s) failed"; exit 1; }
echo "all verification failures are refused"
