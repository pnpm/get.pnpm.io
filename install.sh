#!/usr/bin/env bash

# From https://github.com/Homebrew/install/blob/master/install.sh
abort() {
  printf "%s\n" "$@"
  exit 1
}

# string formatters
if [ -t 1 ]; then
  tty_escape() { printf "\033[%sm" "$1"; }
else
  tty_escape() { :; }
fi
tty_mkbold() { tty_escape "1;$1"; }
tty_underline="$(tty_escape "4;39")"
tty_blue="$(tty_mkbold 34)"
tty_red="$(tty_mkbold 31)"
tty_bold="$(tty_mkbold 39)"
tty_reset="$(tty_escape 0)"

shell_join() {
  printf "%s" "$1"
  shift
  for arg in "$@"; do
    printf " "
    printf "%s" "${arg// /\ }"
  done
}

ohai() {
  printf "${tty_blue}==>${tty_bold} %s${tty_reset}\n" "$(shell_join "$@")"
}

warn() {
  printf "${tty_red}Warning${tty_reset}: %s\n" "$(chomp "$1")"
}

# End from https://github.com/Homebrew/install/blob/master/install.sh

detect_platform() {
  local platform
  platform="$(uname -s | tr '[:upper:]' '[:lower:]')"

  case "${platform}" in
    linux) platform="linux" ;;
    darwin) platform="macos" ;;
    windows) platform="win" ;;
  esac

  printf '%s' "${platform}"
}

detect_arch() {
  local arch
  arch="$(uname -m | tr '[:upper:]' '[:lower:]')"

  case "${arch}" in
    x86_64) arch="x64" ;;
    amd64) arch="x64" ;;
    armv*) arch="arm" ;;
    arm64) arch="aarch64" ;;
  esac

  # `uname -m` in some cases mis-reports 32-bit OS as 64-bit, so double check
  if [ "${arch}" = "x64" ] && [ "$(getconf LONG_BIT)" -eq 32 ]; then
    arch=i686
  elif [ "${arch}" = "aarch64" ] && [ "$(getconf LONG_BIT)" -eq 32 ]; then
    arch=arm
  fi

  if [[ "$arch" != "x64"* ]]; then
    abort "Sorry! pnpm currently only provides pre-built binaries for x86_64 architectures." 2>&1
  fi
  printf '%s' "${arch}"
}

detect_arch
platform="$(detect_platform)"
arch="$(detect_arch)"
pkgName="@pnpm/${platform}-${arch}"
version="$(curl -f "https://registry.npmjs.org/${pkgName}" | grep -Po '"latest":"([^"]*)' | grep -Po "[0-9].+")"
archive_url="https://registry.npmjs.org/${pkgName}/-/${platform}-${arch}-${version}.tgz"

curl --progress-bar --show-error --location --output "pnpm.tgz" "$archive_url"

create_tree() {
  local tmp_dir="$1"

  ohai 'Creating' "directory layout"

  if ! mkdir -p "$tmp_dir";
  then
    abort "Could not create directory layout. Please make sure the target directory is writeable: $tmp_dir"
  fi
}

install_from_file() {
  local archive="$1"
  local tmp_dir="$2"

  create_tree "$tmp_dir"

  ohai 'Extracting' "pnpm binaries"
  # extract the files to the specified directory
  tar -xf "$archive" -C "$tmp_dir" --strip-components=1
  SHELL=$SHELL "$tmp_dir/pnpm" setup
}

# install to PNPM_HOME, defaulting to ~/.pnpm
tmp_dir="pnpm_tmp"

install_from_file "pnpm.tgz" "$tmp_dir"

rm -rf pnpm.tgz pnpm_tmp

