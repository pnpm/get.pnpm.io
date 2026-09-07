#!/bin/sh
# Asserts which hosts the installer builds a target for, and which it refuses.
#
# The installer is sourced with its last line — the call that performs an
# install — removed, so `detect_arch` and `assert_target_is_built` are exercised
# as shipped. `uname` is replaced per case; nothing here reaches the network.
set -eu

here="$(cd "$(dirname "$0")" && pwd)"
root="$(dirname "$here")"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT INT TERM

sed '$d' "$root/install.sh" > "$work/installer.sh"

# shellcheck source=/dev/null
. "$work/installer.sh"

failures=0

fail() {
  failures=$((failures + 1))
  echo "FAIL $1"
  echo "  expected: $2"
  echo "  actual:   $3"
}

# `uname -m` of "$1" maps to arch "$2".
expect_arch() {
  # Called by the sourced installer, not from here, which shellcheck cannot see.
  # shellcheck disable=SC2329
  uname() { if [ "${1:-}" = '-m' ]; then printf '%s' "$machine"; else printf 'Linux'; fi; }
  machine="$1"
  actual="$(detect_arch || printf 'REFUSED')"
  [ "$actual" = "$2" ] || fail "uname -m=$1" "$2" "$actual"
}

# `uname -s` of Linux with the Android loader "$1" present detects as "$2".
expect_platform_on_linux() {
  # Both are called by the sourced installer, as above.
  # shellcheck disable=SC2329
  uname() { printf 'Linux'; }
  # shellcheck disable=SC2329
  is_android() { [ "$android" = 'yes' ]; }
  android="$1"
  actual="$(detect_platform)"
  [ "$actual" = "$2" ] || fail "linux, android=$1" "$2" "$actual"
}

# pnpm major "$3" on "$1"-"$2" is installable.
expect_built() {
  actual="$( (assert_target_is_built "$1" "$2" "$3" && printf 'OK') 2>&1 || true )"
  [ "$actual" = 'OK' ] || fail "$1-$2 on v$3" 'OK' "$actual"
}

# pnpm major "$3" on "$1"-"$2" is refused, naming "$4".
expect_not_built() {
  actual="$( (assert_target_is_built "$1" "$2" "$3" && printf 'OK') 2>&1 || true )"
  case "$actual" in
    *"$4"*) ;;
    *) fail "$1-$2 on v$3" "mentions $4" "$actual" ;;
  esac
}

# The architectures pnpm 12 is built for, under the names its assets carry.
expect_arch x86_64 x64
expect_arch aarch64 arm64
expect_arch riscv64 riscv64
expect_arch s390x s390x
# Node calls both POWER endiannesses `ppc64`, and only the little-endian build
# is released, so only that `uname -m` maps to a target.
expect_arch ppc64le ppc64
expect_arch ppc64 REFUSED
# Architectures pnpm has never shipped a binary for.
expect_arch i686 REFUSED
expect_arch mips REFUSED

# Android reports itself as Linux and has to be told apart, or it picks the
# musl asset, whose DNS resolution cannot work there.
expect_platform_on_linux yes android
expect_platform_on_linux no linux

# The x64/arm64 matrix predates v12 and is not gated.
expect_built linux x64 11
expect_built darwin arm64 10
expect_built win32 x64 11

# Everything else arrived with the Rust port in v12.
expect_built freebsd x64 12
expect_built linux ppc64 12
expect_built linux riscv64 12
expect_built linux s390x 12
expect_not_built freebsd x64 11 'pnpm 12 does'
expect_not_built linux ppc64 11 'linux-ppc64'
expect_not_built linux riscv64 11 'linux-riscv64'
expect_not_built linux s390x 10 'linux-s390x'
expect_built android arm64 12
expect_built android x64 12
expect_not_built android arm64 11 'android-arm64'

if [ "$failures" -gt 0 ]; then
  echo "$failures case(s) failed"
  exit 1
fi
echo "all cases passed"
