#!/bin/sh
set -eu

here="$(cd "$(dirname "$0")" && pwd)"
root="$(dirname "$here")"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT INT TERM

sed '/^download_and_install || abort "Install Error!"$/d' "$root/install.sh" > "$work/installer.sh"

# shellcheck source=/dev/null
. "$work/installer.sh"

failures=0

fail() {
  failures=$((failures + 1))
  echo "FAIL $1"
  echo "  expected: $2"
  echo "  actual:   $3"
}

expect_arch() {
  # Called by the sourced installer, not from here, which shellcheck cannot see.
  # shellcheck disable=SC2329
  uname() { if [ "${1:-}" = '-m' ]; then printf '%s' "$machine"; else printf 'Linux'; fi; }
  machine="$1"
  actual="$(detect_arch || printf 'REFUSED')"
  [ "$actual" = "$2" ] || fail "uname -m=$1" "$2" "$actual"
}

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

expect_built() {
  actual="$( (assert_target_is_built "$1" "$2" "$3" && printf 'OK') 2>&1 || true )"
  [ "$actual" = 'OK' ] || fail "$1-$2 on v$3" 'OK' "$actual"
}

expect_not_built() {
  actual="$( (assert_target_is_built "$1" "$2" "$3" && printf 'OK') 2>&1 || true )"
  case "$actual" in
    *"$4"*) ;;
    *) fail "$1-$2 on v$3" "mentions $4" "$actual" ;;
  esac
}

expect_package() {
  actual="$(
    # shellcheck disable=SC2329
    detect_platform() { printf '%s' "$mock_platform"; }
    # shellcheck disable=SC2329
    detect_arch() { printf '%s' "$mock_arch"; }
    # shellcheck disable=SC2329
    is_glibc_compatible() { [ "$libc" = 'glibc' ]; }
    # shellcheck disable=SC2329
    ohai() { :; }
    # Stop before downloading or executing anything.
    # shellcheck disable=SC2329
    fetch_verified_package() { printf '%s' "$1"; exit 0; }
    mock_platform="$1"
    mock_arch="$2"
    libc="$3"
    PNPM_VERSION=12.0.0 download_and_install
  )"
  [ "$actual" = "$4" ] || fail "$1-$2 on $3" "$4" "$actual"
}

expect_arch x86_64 x64
expect_arch aarch64 arm64
expect_arch riscv64 riscv64
expect_arch s390x s390x
expect_arch ppc64le ppc64
expect_arch ppc64 REFUSED
expect_arch i686 REFUSED
expect_arch mips REFUSED

expect_platform_on_linux yes android
expect_platform_on_linux no linux

expect_built linux arm64 11
expect_built darwin x64 10
expect_built win32 arm64 11
expect_built linux x64 11
expect_built darwin arm64 10
expect_built win32 x64 11

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

for major in 10 11 12; do
  expect_not_built freebsd riscv64 "$major" 'does not provide a pre-built binary for freebsd-riscv64'
  expect_not_built freebsd arm64 "$major" 'does not provide a pre-built binary for freebsd-arm64'
  expect_not_built darwin ppc64 "$major" 'does not provide a pre-built binary for darwin-ppc64'
  expect_not_built win32 s390x "$major" 'does not provide a pre-built binary for win32-s390x'
  expect_not_built android riscv64 "$major" 'does not provide a pre-built binary for android-riscv64'
  expect_not_built openbsd x64 "$major" 'does not provide a pre-built binary for openbsd-x64'
done

for libc in glibc musl; do
  for arch in ppc64 riscv64 s390x; do
    expect_package linux "$arch" "$libc" "@pnpm/exe.linux-$arch"
  done
  expect_package freebsd x64 "$libc" '@pnpm/exe.freebsd-x64'
  expect_package android arm64 "$libc" '@pnpm/exe.android-arm64'
done
for arch in x64 arm64; do
  expect_package linux "$arch" glibc "@pnpm/exe.linux-$arch"
  expect_package linux "$arch" musl "@pnpm/exe.linux-$arch-musl"
done

if [ "$failures" -gt 0 ]; then
  echo "$failures case(s) failed"
  exit 1
fi
echo "all cases passed"
