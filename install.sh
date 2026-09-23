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

NPM_REGISTRY='https://registry.npmjs.org'

# npm's registry signing key, mirrored from
# https://registry.npmjs.org/-/npm/v1/keys.
#
# Pinning it here is what makes the check below worth running. The registry
# publishes both the tarball and the checksum, so a checksum fetched from it
# proves nothing on its own; the signature does, because the key that produced
# it is not one the download host can mint. Rotations are rare — when npm
# rotates, this value has to be updated here.
NPM_SIGNING_KEY_ID='SHA256:DhQ8wR5APBvFHLF/+Tc+AYvPOdTpcIDqOhxsBHRwC7U'
NPM_SIGNING_KEY='MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEY6Ya7W++7aUPzvMTrezH6Ycx3c+HOKYCcNGybJZSCJq/fd7Qa8uuAKtdIkUQtQiEKERhAmE5lMMJhP8OkDOa2g=='

# The "dist-tags" object of a packument, one `tag:version` per line.
dist_tags() {
  printf '%s' "$1" | tr -d ' \n' | sed 's/.*"dist-tags":{//; s/}.*//' | tr ',' '\n' | tr -d '"'
}

# The version a dist-tag points at, empty when there is no such tag.
dist_tag_version() {
  dist_tags "$1" | grep "^$2:" | head -n 1 | sed "s/^$2://"
}

# Turn what PNPM_VERSION asks for — a dist-tag, a version, or a bare major — into
# a concrete version, left in RESOLVED_VERSION. `resolveVersion` in the
# `get-pnpm` package resolves the same three the same way.
#
# The result comes back in a variable rather than on stdout because the aborts
# here have to end the install: from a command substitution they would end only
# the subshell, and their message would be captured as the version.
resolve_version() {
  local spec kind version_json version
  spec="$1"
  # A leading `v` is accepted on a version or a major, but not stripped from
  # every spec: that would turn a dist-tag like `vnext` into a lookup for
  # `next`.
  case "$spec" in
    v[0-9]*) spec="${spec#v}" ;;
  esac

  case "$spec" in
    # Starts with a digit and carries something else: the version it says it
    # is, with nothing to look up.
    [0-9]*[!0-9]*) RESOLVED_VERSION="$spec"; return 0 ;;
    # All digits: a bare major.
    [0-9]*) kind='major' ;;
    *) kind='tag' ;;
  esac

  # Tags come from `pnpm`: it is published for every release, whereas
  # `@pnpm/exe` is on its way out and would go stale.
  version_json="$(download "$NPM_REGISTRY/pnpm")" || abort "Download Error!"

  if [ "$kind" = 'major' ]; then
    # A bare major asks for that major's current release. pnpm publishes it as
    # `latest-<major>` once the major is stable, and only as `next-<major>`
    # before it is promoted — taking either is what makes a new major
    # installable on the day it lands rather than once someone promotes it.
    version="$(dist_tag_version "$version_json" "latest-$spec")"
    [ -n "$version" ] || version="$(dist_tag_version "$version_json" "next-$spec")"
  else
    version="$(dist_tag_version "$version_json" "$spec")"
  fi

  [ -n "$version" ] || abort \
    "Sorry! pnpm \"$1\" could not be found." \
    "" \
    "PNPM_VERSION takes a version, a major, or one of these tags:" \
    "$(dist_tags "$version_json")"
  RESOLVED_VERSION="$version"
}

# First "<name>":"<value>" pair in a JSON document. The fields read out of the
# registry metadata below (tarball, integrity, sig, keyid) each occur once.
json_string() {
  printf '%s' "$1" | tr -d ' \n' | grep -o "\"$2\":\"[^\"]*\"" | head -n 1 | sed "s/\"$2\":\"//; s/\"\$//"
}

# Verify an npm registry signature over "<name>@<version>:<integrity>".
# Returns 2 when openssl is missing, so the caller can tell "cannot check" from
# "checked and wrong".
verify_npm_signature() {
  local message signature dir
  message="$1"
  signature="$2"
  dir="$3"
  command -v openssl > /dev/null 2>&1 || return 2
  # RFC 7468 wants the base64 body wrapped at 64 columns. OpenSSL tolerates one
  # long line; not every parser does, and a rejected key would be reported here
  # as a bad signature.
  {
    printf -- '-----BEGIN PUBLIC KEY-----\n'
    printf '%s\n' "$NPM_SIGNING_KEY" | fold -w 64
    printf -- '-----END PUBLIC KEY-----\n'
  } > "$dir/npm-key.pem"
  printf '%s' "$signature" | openssl base64 -d -A > "$dir/npm-sig.bin" 2>/dev/null || return 1
  printf '%s' "$message" > "$dir/npm-msg"
  openssl dgst -sha256 -verify "$dir/npm-key.pem" -signature "$dir/npm-sig.bin" "$dir/npm-msg" > /dev/null 2>&1
}

# Compare a file against a "sha512-<base64>" integrity string. Returns 2 when
# no usable digest tool is present.
verify_integrity() {
  local file expected actual
  file="$1"
  expected="${2#sha512-}"
  [ "$expected" != "$2" ] || return 2
  if command -v openssl > /dev/null 2>&1; then
    actual="$(openssl dgst -sha512 -binary "$file" | openssl base64 -A)"
  else
    # No openssl: compare in hex instead, which busybox and coreutils can do.
    expected="$(printf '%s' "$expected" | base64 -d 2>/dev/null | od -An -v -tx1 | tr -d ' \n')"
    if command -v sha512sum > /dev/null 2>&1; then
      actual="$(sha512sum "$file" | cut -d' ' -f1)"
    elif command -v shasum > /dev/null 2>&1; then
      actual="$(shasum -a 512 "$file" | cut -d' ' -f1)"
    else
      return 2
    fi
  fi
  [ -n "$expected" ] && [ "$actual" = "$expected" ]
}

# Download <pkg>@<version> from the npm registry into $2, checking the registry
# signature and the tarball checksum before anything is extracted.
fetch_verified_package() {
  local pkg version dir meta tarball_url integrity signature keyid archive result
  pkg="$1"
  version="$2"
  dir="$3"
  meta="$(download "$NPM_REGISTRY/$pkg/$version")" || abort "Could not reach the npm registry for $pkg@$version."
  tarball_url="$(json_string "$meta" tarball)"
  integrity="$(json_string "$meta" integrity)"
  signature="$(json_string "$meta" sig)"
  keyid="$(json_string "$meta" keyid)"
  [ -n "$tarball_url" ] || abort "The npm registry published no tarball for $pkg@$version."
  [ -n "$integrity" ] || abort "The npm registry published no checksum for $pkg@$version."

  if [ -z "$signature" ]; then
    abort "$pkg@$version carries no npm registry signature, so it cannot be verified."
  elif [ "$keyid" != "$NPM_SIGNING_KEY_ID" ]; then
    abort "$pkg@$version is signed with an unexpected npm key ($keyid)." \
      "" \
      "If npm has rotated its signing key, this installer needs updating." \
      "Until then, install pnpm another way: https://pnpm.io/installation"
  fi

  verify_npm_signature "$pkg@$version:$integrity" "$signature" "$dir"
  result=$?
  if [ "$result" -eq 1 ]; then
    abort "The npm registry signature for $pkg@$version is not valid. Refusing to install."
  elif [ "$result" -eq 2 ]; then
    ohai "openssl was not found — checking the download against its checksum only, not the npm signature"
  fi

  archive="$dir/package.tgz"
  download "$tarball_url" > "$archive" || abort "Download Error!"
  verify_integrity "$archive" "$integrity"
  result=$?
  if [ "$result" -eq 1 ]; then
    abort "$pkg@$version does not match the checksum the npm registry published for it. Refusing to install."
  elif [ "$result" -eq 2 ]; then
    abort "No usable SHA-512 tool was found, so the download cannot be verified."
  fi

  # Extract whole, then lift the wanted entry out of the package/ root: no
  # reliance on --strip-components or member selection, which busybox tar and
  # bsdtar disagree about.
  rm -rf "$dir/unpacked"
  mkdir -p "$dir/unpacked"
  tar -xzf "$archive" -C "$dir/unpacked" || abort "Could not unpack $pkg@$version."
  rm -f "$archive"
}

is_glibc_compatible() {
  getconf GNU_LIBC_VERSION >/dev/null 2>&1 || ldd --version >/dev/null 2>&1 || return 1
}

# Detect the OS portion of the target triplet using `process.platform`-style
# names (`linux`, `darwin`, `win32`) — the scheme pnpm's own platform packages
# and release assets use from v11.0.0-rc.3 onward. See `legacy_asset_basename`
# below for the older `macos` / `win` / `linuxstatic` mapping used by earlier
# releases.
# Android reports itself as Linux, so `uname` alone cannot tell the two apart,
# and the wrong answer picks an asset that cannot run: the musl Linux binary
# resolves DNS through `/etc/resolv.conf`, which Android does not have. Only
# 64-bit Android is built for, and this is the loader those binaries name as
# their interpreter, so its absence means no asset would run here anyway.
is_android() {
  [ -e /system/bin/linker64 ]
}

detect_platform() {
  local platform
  platform="$(uname -s | tr '[:upper:]' '[:lower:]')"

  case "${platform}" in
    linux)  if is_android; then platform="android"; else platform="linux"; fi ;;
    darwin) platform="darwin" ;;
    mingw*|msys*|cygwin*) platform="win32" ;;
    windows*) platform="win32" ;;
  esac

  printf '%s' "${platform}"
}

detect_libc_suffix() {
  case "$1-$2" in
    linux-x64 | linux-arm64)
      if ! is_glibc_compatible; then
        printf -- '-musl'
      fi
      ;;
  esac
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
    ppc64le) arch="ppc64" ;;
    # Node names both POWER endiannesses ppc64; only little-endian is built.
    ppc64) return 1 ;;
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
    ppc64 | riscv64 | s390x) ;;
    *) return 1
  esac
  printf '%s' "${arch}"
}

assert_target_is_built() {
  local platform arch major
  platform="$1"
  arch="$2"
  major="$3"

  case "${platform}-${arch}" in
    android-arm64 | android-x64) ;;
    freebsd-x64 | linux-ppc64 | linux-riscv64 | linux-s390x) ;;
    darwin-x64 | darwin-arm64 | linux-x64 | linux-arm64 | win32-x64 | win32-arm64) return 0 ;;
    *) abort "Sorry! pnpm does not provide a pre-built binary for ${platform}-${arch}." ;;
  esac
  if [ "$major" -lt 12 ]; then
    abort \
      "pnpm v${major} does not provide a pre-built binary for ${platform}-${arch}." \
      "" \
      "pnpm 12 does. Install it with:" \
      "  PNPM_VERSION=12 sh -c \"\$(curl -fsSL https://get.pnpm.io/install.sh)\""
  fi
}

download_and_install() {
  local platform arch libc_suffix version tmp_dir major_version asset_base
  platform="$(detect_platform)"
  arch="$(detect_arch)" || abort "Sorry! pnpm does not provide a pre-built binary for this architecture."
  libc_suffix="$(detect_libc_suffix "$platform" "$arch")"
  # PNPM_VERSION takes a dist-tag, a version, or a major, as it does in
  # install.ps1.
  resolve_version "${PNPM_VERSION:-latest}"
  version="$RESOLVED_VERSION"

  # Everything below builds URLs out of this value, so keep it to the shape of
  # a version. Every pnpm release is `major.minor.patch`, optionally with a
  # prerelease part; a partial version like `12.0` is not a version the registry
  # holds, and without this test it reaches it as one and comes back as a 404
  # rather than as the mistake it is.
  case "$version" in
    [0-9]*.[0-9]*.[0-9]*) ;;
    *) abort "Invalid pnpm version: $version" \
      "" \
      "PNPM_VERSION takes a full version (12.0.0), a major (12), or a dist-tag (next-12)." ;;
  esac
  # Checked separately, because the test above admits a path: without this
  # `PNPM_VERSION=12.0.0/../../@evil/pkg` passes the major-version test too and
  # changes which path is requested.
  case "$version" in
    *[!0-9A-Za-z.+-]*) abort "Invalid pnpm version: $version" ;;
  esac

  # Compute the major version once. Strip an optional leading "v" so
  # PNPM_VERSION=v11.0.0 normalizes the same as 11.0.0; the second sed
  # captures only the leading digits so prereleases like 11.0.0-rc.1
  # resolve to 11. A bare `cut -d. -f1` would leave a "v" or non-digit
  # prefix in the value, fail the numeric -ge test silently (the existing
  # `2>/dev/null` suppression hid the parse error), and skip every
  # major-gated branch below.
  major_version="$(printf '%s' "$version" | sed -E 's/^v//; s/^([0-9]+).*/\1/')"
  # Caught here so the major-gated tests below don't fail with a shell error
  # about integers if the resolved value is not a version after all.
  case "$major_version" in
    '' | *[!0-9]*) abort "Invalid pnpm version: $version" ;;
  esac

  assert_target_is_built "$platform" "$arch" "$major_version"

  # Intel macOS isn't supported on pnpm v11 only: the SEA binary produced
  # by Node.js for darwin-x64 segfaults at startup because of an upstream
  # Node.js bug the Node.js team has decided not to fix (Intel macOS is
  # being phased out). Without this guard the script would 404 on
  # pnpm-darwin-x64.tar.gz and surface as a generic "Install Error!".
  # v12 (the Rust port) ships darwin-x64 again, so the guard is v11-bound.
  # See https://github.com/pnpm/pnpm/issues/11423 and
  # https://github.com/nodejs/node/issues/62893.
  if [ "${platform}" = "darwin" ] && [ "${arch}" = "x64" ] && [ "$major_version" -eq 11 ]; then
    abort \
      "pnpm v${version} does not provide a working binary for Intel macOS (darwin-x64) due to an upstream Node.js SEA bug." \
      "" \
      "Install pnpm a different way instead:" \
      "  npm install -g pnpm           # uses your system Node.js" \
      "  brew install pnpm             # via Homebrew" \
      "  corepack enable pnpm          # bundled with Node.js" \
      "" \
      "More context: https://github.com/pnpm/pnpm/issues/11423"
  fi

  # install to PNPM_HOME, defaulting to ~/.pnpm
  tmp_dir="$(mktemp -d)" || abort "Tmpdir Error!"
  # Use double quotes with single-quoted variable to interpolate at trap setup time.
  # This ensures the directory path is captured even if tmp_dir goes out of scope.
  # shellcheck disable=SC2064
  trap "rm -rf '$tmp_dir'" EXIT INT TERM HUP

  if [ "$major_version" -ge 12 ]; then
    # v12+ is published to the npm registry as well as to the GitHub release
    # page, and the two carry the same executable byte for byte. Only the
    # registry copy comes with a signature over its checksum, so that is the
    # one worth downloading: see NPM_SIGNING_KEY above.
    local executable platform_pkg
    executable='pnpm'
    if [ "${platform}" = 'win32' ]; then
      executable='pnpm.exe'
    fi

    ohai "Downloading pnpm ${version}"
    platform_pkg="@pnpm/exe.${platform}-${arch}${libc_suffix}"
    fetch_verified_package "$platform_pkg" "$version" "$tmp_dir"
    mv "$tmp_dir/unpacked/package/$executable" "$tmp_dir/$executable" || return 1

    # The executable expects the `dist/` tree next to it. `pnpm` is where the
    # registry publishes it, verified the same way. (`@pnpm/exe` currently
    # carries identical content, but only `pnpm` is published going forward.)
    fetch_verified_package 'pnpm' "$version" "$tmp_dir"
    mv "$tmp_dir/unpacked/package/dist" "$tmp_dir/dist" || return 1

    chmod +x "$tmp_dir/$executable"
    SHELL="$SHELL" "$tmp_dir/$executable" setup --force || return 1
    return 0
  fi

  ohai "Downloading pnpm binaries ${version}"
  asset_base="$(asset_basename "$version" "$platform" "$arch" "$libc_suffix")"
  if [ "$major_version" -ge 11 ]; then
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

# Where `pnpm setup` installs: PNPM_HOME, or pnpm's default for the platform,
# resolved the way pnpm resolves it (XDG_DATA_HOME first, then the platform
# directory).
pnpm_home_dir() {
  if [ -n "${PNPM_HOME:-}" ]; then
    printf '%s' "$PNPM_HOME"
  elif [ -n "${XDG_DATA_HOME:-}" ]; then
    printf '%s/pnpm' "$XDG_DATA_HOME"
  elif [ "$(detect_platform)" = 'darwin' ]; then
    printf '%s/Library/pnpm' "$HOME"
  else
    printf '%s/.local/share/pnpm' "$HOME"
  fi
}

# The path with every symlink resolved, or the path itself where nothing can
# resolve it (`readlink -f` only reached macOS in 12.3). These functions run
# their utilities through `command -p`, on the system's default PATH, because
# the PATH being examined is the one that may hold a stray `pnpm`.
real_path() {
  command -p realpath "$1" 2>/dev/null || command -p readlink -f "$1" 2>/dev/null || printf '%s' "$1"
}

# Whether "$1" is a directory `pnpm setup` links pnpm into: `$PNPM_HOME/bin`,
# or `$PNPM_HOME` itself, which the v10 layout linked into directly. Either
# side may reach the directory through a symlink (`/var` on macOS is one).
is_pnpm_home_bin() {
  local dir pnpm_home
  dir="${1%/}"
  pnpm_home="${2%/}"
  if [ "$dir" = "$pnpm_home/bin" ] || [ "$dir" = "$pnpm_home" ]; then
    return 0
  fi
  dir="$(real_path "$dir")"
  [ "$dir" = "$(real_path "$pnpm_home/bin")" ] || [ "$dir" = "$(real_path "$pnpm_home")" ]
}

# The first `pnpm` a PATH lookup finds when it is not the one `pnpm setup`
# installed under "$1", left in SHADOWING_PNPM; the exit status is 1 when the
# shell finds pnpm's own first, or none at all. SHADOWED_BIN_ON_PATH is `yes`
# when `$1/bin` is on PATH at all, behind SHADOWING_PNPM. Both come back in
# variables so the function can run in the shell that reads them, not in a
# command substitution's subshell.
#
# A `pnpm` from another installer (npm, Homebrew, Corepack, Volta) that sits
# ahead of `$1/bin` on PATH keeps running after this script reports success,
# so every version it installs looks like it never took. This is what makes
# the install script say so.
find_shadowing_pnpm() {
  local pnpm_home dir candidate rest
  pnpm_home="$1"
  SHADOWING_PNPM=''
  SHADOWED_BIN_ON_PATH=no
  rest="$PATH"
  while [ -n "$rest" ]; do
    case "$rest" in
      *:*) dir="${rest%%:*}"; rest="${rest#*:}" ;;
      *) dir="$rest"; rest='' ;;
    esac
    [ -n "$dir" ] || dir='.'
    if is_pnpm_home_bin "$dir" "$pnpm_home"; then
      [ -n "$SHADOWING_PNPM" ] || return 1
      SHADOWED_BIN_ON_PATH=yes
      break
    fi
    [ -z "$SHADOWING_PNPM" ] || continue
    candidate="$dir/pnpm"
    [ -f "$candidate" ] && [ -x "$candidate" ] || continue
    # A symlink into pnpm's own directory runs the pnpm just installed.
    if is_pnpm_home_bin "$(command -p dirname "$(real_path "$candidate")")" "$pnpm_home"; then
      return 1
    fi
    SHADOWING_PNPM="$candidate"
  done
  [ -n "$SHADOWING_PNPM" ]
}

# How the `pnpm` at "$1" got there, as far as its location and, for a shim
# script, its contents tell: npm, homebrew, corepack, volta, or unknown.
install_origin() {
  local executable
  for executable in "$(real_path "$1")" "$1"; do
    case "$executable" in
      */Cellar/pnpm/*) printf 'homebrew'; return ;;
      *corepack*) printf 'corepack'; return ;;
      */.volta/*) printf 'volta'; return ;;
      */node_modules/pnpm/*) printf 'npm'; return ;;
    esac
  done
  # npm's and Corepack's shims name their target inside; a real executable
  # is far larger than any shim, so only its head is read.
  if command -p head -c 65536 "$1" 2>/dev/null | command -p grep -q 'corepack'; then
    printf 'corepack'
  elif command -p head -c 65536 "$1" 2>/dev/null | command -p grep -q 'node_modules/pnpm/'; then
    printf 'npm'
  else
    printf 'unknown'
  fi
}

# The warning for a `pnpm` at "$1" of origin "$2" that shadows the one
# installed under "$3". `SHADOWED_BIN_ON_PATH` tells which of the two
# situations it describes.
shadowing_pnpm_warning() {
  local executable origin pnpm_home described removal reorder fix
  executable="$1"
  origin="$2"
  pnpm_home="$3"
  case "$origin" in
    npm) described='installed with npm'; removal='npm uninstall -g pnpm' ;;
    homebrew) described='installed with Homebrew'; removal='brew uninstall pnpm' ;;
    corepack) described='a Corepack shim'; removal='corepack disable pnpm' ;;
    volta) described='installed with Volta'; removal='volta uninstall pnpm' ;;
    *) described='not installed by pnpm'; removal='' ;;
  esac
  reorder="move $pnpm_home/bin ahead of $(command -p dirname "$executable") in PATH"
  if [ -n "$removal" ]; then
    fix="run \"$removal\" or $reorder"
  else
    fix="$reorder"
  fi
  if [ "$SHADOWED_BIN_ON_PATH" = 'yes' ]; then
    printf '%s\n' \
      "Warning: \"pnpm\" on PATH is $executable ($described), which comes before $pnpm_home/bin." \
      "Your shell keeps running that pnpm, not the one pnpm installed to $pnpm_home/bin." \
      "To finish switching, $fix."
  else
    printf '%s\n' \
      "Warning: \"pnpm\" on PATH is $executable ($described), and $pnpm_home/bin is not on PATH yet." \
      "Once a new shell adds it, it has to come first: $fix."
  fi
}

# Say so when the pnpm just installed is not the one PATH resolves, or the
# success above is the last thing the person reads before `pnpm --version`
# prints the old version again. Windows paths take another shape under
# MSYS, so the lookup is left to `pnpm setup` there.
warn_if_pnpm_is_shadowed() {
  local pnpm_home
  [ "$(detect_platform)" != 'win32' ] || return 0
  pnpm_home="$(pnpm_home_dir)"
  find_shadowing_pnpm "$pnpm_home" || return 0
  shadowing_pnpm_warning "$SHADOWING_PNPM" "$(install_origin "$SHADOWING_PNPM")" "$pnpm_home" >&2
}

download_and_install || abort "Install Error!"
warn_if_pnpm_is_shadowed
