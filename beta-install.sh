#!/usr/bin/env bash

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
    error "Sorry! pnpm currently only provides pre-built binaries for x86_64 architectures."
  fi
  printf '%s' "${arch}"
}

platform="$(detect_platform)"
arch="$(detect_arch)"
pkgName="@pnpm/${platform}-${arch}"
version="$(curl -f "https://registry.npmjs.org/${pkgName}" | grep -Po '"latest":"([^"]*)' | grep -Po "[0-9].+")"
archive_url="https://registry.npmjs.org/${pkgName}/-/${platform}-${arch}-${version}.tgz"

curl --progress-bar --show-error --location --output "pnpm.tgz" "$archive_url"

create_tree() {
  local tmp_dir="$1"

  info 'Creating' "directory layout"

  if ! mkdir -p "$tmp_dir";
  then
    error "Could not create directory layout. Please make sure the target directory is writeable: $tmp_dir"
    exit 1
  fi
}

install_from_file() {
  local archive="$1"
  local tmp_dir="$2"

  create_tree "$tmp_dir"

  info 'Extracting' "pnpm binaries"
  # extract the files to the specified directory
  tar -xf "$archive" -C "$tmp_dir" --strip-components=1
  SHELL=$SHELL "$tmp_dir/pnpm" setup
}

# install to PNPM_HOME, defaulting to ~/.pnpm
tmp_dir="pnpm_tmp"

install_from_file "pnpm.tgz" "$tmp_dir"

rm -rf pnpm.tgz pnpm_tmp

