#!/bin/sh
# Asserts what the installer says about a `pnpm` from another installer that
# sits ahead of the one it just installed on PATH.
#
# The installer is sourced with its entry-point call removed. Every case builds
# a throwaway PATH out of temp directories, so nothing here depends on what the
# host has installed.
set -eu

here="$(cd "$(dirname "$0")" && pwd)"
root="$(dirname "$here")"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT INT TERM

sed '/^download_and_install || abort "Install Error!"$/d; /^print_undo_hint$/d; /^warn_if_pnpm_is_shadowed$/d' "$root/install.sh" > "$work/installer.sh"

# shellcheck source=/dev/null
. "$work/installer.sh"

failures=0

fail() {
  failures=$((failures + 1))
  echo "FAIL $1"
  echo "  expected: $2"
  echo "  actual:   $3"
}

pnpm_home="$work/pnpm-home"
own_bin="$pnpm_home/bin"
other="$work/other"
empty="$work/empty"
links="$work/links"
mkdir -p "$own_bin" "$other" "$empty" "$links"

# A `pnpm` in "$1" that a PATH lookup accepts, holding "$2".
executable() {
  printf '%s' "${2:-}" > "$1/pnpm"
  chmod +x "$1/pnpm"
}

executable "$own_bin"
executable "$other"

# With PATH="$1", the lookup finds "$2" ("" when nothing shadows) and reports
# whether pnpm's own bin directory is on PATH as "$3".
expect_shadowing() {
  saved_path="$PATH"
  PATH="$1"
  if find_shadowing_pnpm "$pnpm_home"; then actual="$SHADOWING_PNPM"; else actual=''; fi
  PATH="$saved_path"
  [ "$actual" = "$2" ] || fail "PATH=$1" "$2" "$actual"
  [ "$SHADOWED_BIN_ON_PATH" = "$3" ] || fail "PATH=$1 (own bin on PATH)" "$3" "$SHADOWED_BIN_ON_PATH"
}

expect_shadowing "$own_bin:$other" '' no
expect_shadowing "$empty" '' no
expect_shadowing "$other:$own_bin" "$other/pnpm" yes
expect_shadowing "$other" "$other/pnpm" no
# The v10 layout links `pnpm` straight into the pnpm home directory; that is
# pnpm's own, not another installer's.
executable "$pnpm_home"
expect_shadowing "$pnpm_home:$other" '' no
# A symlink into pnpm's own directory runs the pnpm just installed.
ln -s "$own_bin/pnpm" "$links/pnpm"
expect_shadowing "$links:$other" '' no
# The pnpm home directory comes from the environment, so it can hold a space.
spaced_home="$work/pnpm home"
mkdir -p "$spaced_home/bin"
executable "$spaced_home/bin"
saved_path="$PATH"
PATH="$spaced_home/bin:$other"
if find_shadowing_pnpm "$spaced_home"; then actual="$SHADOWING_PNPM"; else actual=''; fi
PATH="$saved_path"
[ "$actual" = '' ] || fail 'a pnpm home with a space' '' "$actual"

# The pnpm at "$1" is classified as "$2".
expect_origin() {
  actual="$(install_origin "$1")"
  [ "$actual" = "$2" ] || fail "origin of $1" "$2" "$actual"
}

expect_origin "$work/opt/homebrew/lib/node_modules/pnpm/bin/pnpm.mjs" npm
expect_origin "$work/opt/homebrew/Cellar/pnpm/12.6.0/bin/pnpm" homebrew
expect_origin "$work/usr/local/lib/node_modules/corepack/shims/pnpm" corepack
expect_origin "$work/home/me/.volta/bin/pnpm" volta
expect_origin "$work/home/me/bin/pnpm" unknown
# A symlink is classified by its target, the way `/opt/homebrew/bin/pnpm` points
# into the npm global directory.
mkdir -p "$work/lib/node_modules/pnpm/bin" "$work/bin"
executable "$work/lib/node_modules/pnpm/bin"
ln -s "$work/lib/node_modules/pnpm/bin/pnpm" "$work/bin/pnpm"
expect_origin "$work/bin/pnpm" npm
# A shim script names its target inside.
mkdir -p "$work/shims/corepack" "$work/shims/npm"
executable "$work/shims/corepack" '#!/bin/sh
exec corepack pnpm "$@"
'
expect_origin "$work/shims/corepack/pnpm" corepack
# shellcheck disable=SC2016
executable "$work/shims/npm" '#!/bin/sh
exec node "$(dirname "$0")/../lib/node_modules/pnpm/bin/pnpm.cjs" "$@"
'
expect_origin "$work/shims/npm/pnpm" npm

# The warning for "$1" of origin "$2" when pnpm's own bin is on PATH ("$3")
# contains "$4".
expect_warning() {
  actual="$(SHADOWED_BIN_ON_PATH="$3" shadowing_pnpm_warning "$1" "$2" /home/me/.local/share/pnpm)"
  case "$actual" in
    *"$4"*) ;;
    *) fail "warning for $1 ($2)" "mentions $4" "$actual" ;;
  esac
}

expect_warning /opt/homebrew/bin/pnpm npm yes 'Warning: "pnpm" on PATH is /opt/homebrew/bin/pnpm (installed with npm), which comes before /home/me/.local/share/pnpm/bin.'
expect_warning /opt/homebrew/bin/pnpm npm yes 'To finish switching, run "npm uninstall -g pnpm" or move /home/me/.local/share/pnpm/bin ahead of /opt/homebrew/bin in PATH.'
expect_warning /usr/local/bin/pnpm unknown no 'and /home/me/.local/share/pnpm/bin is not on PATH yet.'
expect_warning /usr/local/bin/pnpm unknown no 'it has to come first: move /home/me/.local/share/pnpm/bin ahead of /usr/local/bin in PATH.'
expect_warning /usr/local/bin/pnpm corepack yes 'run "corepack disable pnpm"'

# End to end: the entry point prints the warning on stderr and still exits 0.
# The fake PATH holds no `uname`, so the platform is fixed by hand.
# shellcheck disable=SC2329
detect_platform() { printf 'linux'; }
actual="$(PATH="$other:$own_bin" PNPM_HOME="$pnpm_home" warn_if_pnpm_is_shadowed 2>&1 >/dev/null)"
case "$actual" in
  "Warning: \"pnpm\" on PATH is $other/pnpm (not installed by pnpm), which comes before $own_bin."*) ;;
  *) fail 'warn_if_pnpm_is_shadowed' 'a warning on stderr' "$actual" ;;
esac
actual="$(PATH="$own_bin:$other" PNPM_HOME="$pnpm_home" warn_if_pnpm_is_shadowed 2>&1)"
[ "$actual" = '' ] || fail 'warn_if_pnpm_is_shadowed with pnpm first' '' "$actual"

# The uninstall hint names the directory `pnpm setup` installed into.
expected_hint="To uninstall, delete /opt/pnpm-home and the lines pnpm setup added to the shell config file named above.
See https://pnpm.io/uninstall"
actual_hint="$(PNPM_HOME=/opt/pnpm-home print_undo_hint)"
[ "$actual_hint" = "$expected_hint" ] || fail 'print_undo_hint' "$expected_hint" "$actual_hint"

if [ "$failures" -ne 0 ]; then
  echo "$failures failure(s)"
  exit 1
fi
echo 'all shadowing cases passed'
