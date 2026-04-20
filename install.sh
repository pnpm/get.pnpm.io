#!/bin/sh

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
tty_blue="$(tty_mkbold 34)"
tty_bold="$(tty_mkbold 39)"
tty_reset="$(tty_escape 0)"

ohai() {
  printf "${tty_blue}==>${tty_bold} %s${tty_reset}\n" "$1"
}

# End from https://github.com/Homebrew/install/blob/master/install.sh

download() {
  if command -v curl > /dev/null 2>&1; then
    curl -fsSL "$1"
  else
    wget -qO- "$1"
  fi
}

is_glibc_compatible() {
  getconf GNU_LIBC_VERSION >/dev/null 2>&1 || ldd --version >/dev/null 2>&1 || return 1
}

# Detect the OS portion of the target triplet using `process.platform`-style
# names (`linux`, `darwin`, `win32`) — the scheme pnpm's own platform packages
# and release assets use from v11.0.0-rc.3 onward. See `legacy_asset_basename`
# below for the older `macos` / `win` / `linuxstatic` mapping used by earlier
# releases.
detect_platform() {
  local platform
  platform="$(uname -s | tr '[:upper:]' '[:lower:]')"

  case "${platform}" in
    linux)  platform="linux" ;;
    darwin) platform="darwin" ;;
    mingw*|msys*|cygwin*) platform="win32" ;;
    windows*) platform="win32" ;;
  esac

  printf '%s' "${platform}"
}

# Empty unless the target needs a libc suffix (currently only `-musl` on
# non-glibc Linux).
detect_libc_suffix() {
  if [ "$(detect_platform)" = 'linux' ] && ! is_glibc_compatible; then
    printf -- '-musl'
  fi
}

# The asset renaming shipped in pnpm v11.0.0-rc.3. Anything older than that
# release still has only the legacy asset names on its GitHub release page
# (`pnpm-macos-*`, `pnpm-win-*`, `pnpm-linuxstatic-*`), so the installer needs
# to know when to request which.
use_legacy_assets() {
  local version="$1"
  local major
  major="$(echo "$version" | cut -d. -f1)"
  if [ "$major" -lt 11 ] 2>/dev/null; then
    return 0
  fi
  # Only v11.0.0-rc.1 and v11.0.0-rc.2 were published before the rename.
  case "$version" in
    11.0.0-rc.1|11.0.0-rc.2) return 0 ;;
    *) return 1 ;;
  esac
}

# Map the new-scheme target back to the legacy asset basename used by
# pre-rename pnpm releases. Arch is unchanged.
legacy_asset_basename() {
  local platform arch libc_suffix
  platform="$1"
  arch="$2"
  libc_suffix="$3"
  case "${platform}:${libc_suffix}" in
    'darwin:')   printf 'pnpm-macos-%s' "$arch" ;;
    'win32:')    printf 'pnpm-win-%s' "$arch" ;;
    'linux:-musl') printf 'pnpm-linuxstatic-%s' "$arch" ;;
    *)           printf 'pnpm-%s-%s%s' "$platform" "$arch" "$libc_suffix" ;;
  esac
}

# Release-page asset basename (without extension) for the given target triplet
# and pnpm version.
asset_basename() {
  local version platform arch libc_suffix
  version="$1"
  platform="$2"
  arch="$3"
  libc_suffix="$4"
  if use_legacy_assets "$version"; then
    legacy_asset_basename "$platform" "$arch" "$libc_suffix"
  else
    printf 'pnpm-%s-%s%s' "$platform" "$arch" "$libc_suffix"
  fi
}

detect_arch() {
  local arch
  arch="$(uname -m | tr '[:upper:]' '[:lower:]')"

  case "${arch}" in
    x86_64 | amd64) arch="x64" ;;
    armv*) arch="arm" ;;
    arm64 | aarch64) arch="arm64" ;;
  esac

  # `uname -m` in some cases mis-reports 32-bit OS as 64-bit, so double check
  if [ "${arch}" = "x64" ] && [ "$(getconf LONG_BIT)" -eq 32 ]; then
    arch=i686
  elif [ "${arch}" = "arm64" ] && [ "$(getconf LONG_BIT)" -eq 32 ]; then
    arch=arm
  fi

  case "$arch" in
    x64*) ;;
    arm64*) ;;
    *) return 1
  esac
  printf '%s' "${arch}"
}

download_and_install() {
  local platform arch libc_suffix version_json version tmp_dir major_version asset_base
  platform="$(detect_platform)"
  arch="$(detect_arch)" || abort "Sorry! pnpm currently only provides pre-built binaries for x86_64/arm64 architectures."
  libc_suffix="$(detect_libc_suffix)"
  if [ -z "${PNPM_VERSION}" ]; then
    version_json="$(download "https://registry.npmjs.org/@pnpm/exe")" || abort "Download Error!"
    version="$(echo "$version_json" | grep -o '"latest":[[:space:]]*"[0-9.]*"' | grep -o '[0-9.]*')"
  else
    version="${PNPM_VERSION}"
  fi

  # install to PNPM_HOME, defaulting to ~/.pnpm
  tmp_dir="$(mktemp -d)" || abort "Tmpdir Error!"
  # Use double quotes with single-quoted variable to interpolate at trap setup time.
  # This ensures the directory path is captured even if tmp_dir goes out of scope.
  # shellcheck disable=SC2064
  trap "rm -rf '$tmp_dir'" EXIT INT TERM HUP

  ohai "Downloading pnpm binaries ${version}"
  major_version="$(echo "$version" | cut -d. -f1)"
  asset_base="$(asset_basename "$version" "$platform" "$arch" "$libc_suffix")"
  if [ "$major_version" -ge 11 ] 2>/dev/null; then
    # v11+: distributed as tarballs containing the binary and dist/ directory
    if [ "${platform}" = "win32" ]; then
      download "https://github.com/pnpm/pnpm/releases/download/v${version}/${asset_base}.zip" > "$tmp_dir/pnpm.zip" || return 1
      unzip -q "$tmp_dir/pnpm.zip" -d "$tmp_dir" || return 1
      SHELL="$SHELL" "$tmp_dir/pnpm.exe" setup --force || return 1
    else
      download "https://github.com/pnpm/pnpm/releases/download/v${version}/${asset_base}.tar.gz" > "$tmp_dir/pnpm.tar.gz" || return 1
      tar -xzf "$tmp_dir/pnpm.tar.gz" -C "$tmp_dir" || return 1
      chmod +x "$tmp_dir/pnpm"
      SHELL="$SHELL" "$tmp_dir/pnpm" setup --force || return 1
    fi
  else
    # older versions: distributed as a single executable binary
    local archive_url
    archive_url="https://github.com/pnpm/pnpm/releases/download/v${version}/${asset_base}"
    if [ "${platform}" = "win32" ]; then
      archive_url="${archive_url}.exe"
    fi
    download "$archive_url" > "$tmp_dir/pnpm" || return 1
    chmod +x "$tmp_dir/pnpm"
    SHELL="$SHELL" "$tmp_dir/pnpm" setup --force || return 1
  fi
}

download_and_install || abort "Install Error!"
