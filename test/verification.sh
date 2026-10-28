#!/bin/sh
# Drives every way the v12 verification can fail, and asserts the installer
# refuses and installs nothing. Then drives a flaky registry, and asserts the
# installer retries its way to an install.
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
version="$(curl -fsSL https://registry.npmjs.org/pnpm \
  | node -e 'let s="";process.stdin.on("data",c=>s+=c).on("end",()=>process.stdout.write(JSON.parse(s)["dist-tags"]["next-12"]??""))')"
[ -n "$version" ] || { echo "could not resolve next-12"; exit 1; }
echo "testing $script against pnpm $version"

failures=0

# Runs the installer against the mock in <mode> on <port>, leaving its output
# in $output, its exit code in $code, and its PNPM_HOME under $home.
run_installer() {
  mode="$1"
  port="$2"

  node "$here/mock-registry.mjs" "$mode" "$port" "$version" > "$work/server.log" 2>&1 &
  server_pid=$!
  # Wait for the port rather than sleeping a guessed amount.
  i=0
  # Any answer will do: a request for a real path would use up the failure the
  # flaky mode saves for the installer.
  while ! curl -sS -o /dev/null "http://127.0.0.1:$port/" > /dev/null 2>&1; do
    i=$((i + 1))
    # The mock downloads the real pnpm tarballs before it listens, which can
    # take tens of seconds on a CI runner.
    [ "$i" -lt 300 ] || { echo "mock registry did not start"; cat "$work/server.log"; exit 1; }
    sleep 0.2
  done

  home="$work/home-$mode"
  mkdir -p "$home"
  # The installer runs from $home, so this makes it a project whose `setup`
  # script would replace a built-in `pnpm setup` not forced with `pm`.
  echo '{"scripts":{"setup":"touch hijacked"}}' > "$home/package.json"
  case "$script" in
    *.ps1)
      sed "s|\$NpmRegistry = 'https://registry.npmjs.org'|\$NpmRegistry = 'http://127.0.0.1:$port'|" \
        "$root/$script" > "$work/patched.ps1"
      set +e
      # NO_COLOR keeps PowerShell from threading escape sequences through the
      # error text, which would otherwise land inside the phrases matched below.
      output="$(cd "$home" && HOME="$home" PNPM_HOME="$home/pnpm" PNPM_VERSION="$version" PNPM_NO_MODIFY_PATH="${no_modify_path:-}" \
        SHELL="${setup_shell:-${SHELL:-}}" NO_COLOR=1 pwsh -NoProfile "$work/patched.ps1" 2>&1)"
      code=$?
      set -e
      ;;
    *)
      sed "s|NPM_REGISTRY='https://registry.npmjs.org'|NPM_REGISTRY='http://127.0.0.1:$port'|" \
        "$root/$script" > "$work/patched.sh"
      set +e
      output="$(cd "$home" && HOME="$home" PNPM_HOME="$home/pnpm" PNPM_VERSION="$version" PNPM_NO_MODIFY_PATH="${no_modify_path:-}" \
        SHELL="${setup_shell:-/bin/sh}" sh "$work/patched.sh" 2>&1)"
      code=$?
      set -e
      ;;
  esac

  kill "$server_pid" 2>/dev/null || true
  wait "$server_pid" 2>/dev/null || true
}

expect_refusal() {
  mode="$1"
  expected="$2"
  run_installer "$mode" "$3"

  # PowerShell wraps its error text to the host width and prefixes the
  # continuation with a `|` gutter, so a phrase arrives as "is not | valid".
  # Drop the gutter characters and flatten to single spaces before matching.
  flattened="$(printf '%s' "$output" | tr -d '|~' | tr -s ' \t\n' ' ')"

  if [ "$code" -eq 0 ]; then
    echo "FAIL [$mode] the installer exited 0"
    failures=$((failures + 1))
  elif ! printf '%s' "$flattened" | grep -qF "$expected"; then
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

expect_install() {
  mode="$1"
  run_installer "$mode" "$2"

  if [ "$code" -ne 0 ]; then
    echo "FAIL [$mode] the installer exited $code:"
    printf '%s\n' "$output" | sed 's/^/      /'
    failures=$((failures + 1))
  elif ! [ -e "$home/pnpm/bin/pnpm" ] && ! [ -e "$home/pnpm/bin/pnpm.exe" ]; then
    echo "FAIL [$mode] the installer exited 0, yet pnpm was not installed"
    failures=$((failures + 1))
  elif [ -e "$home/hijacked" ]; then
    echo "FAIL [$mode] the project's setup script ran instead of pnpm setup"
    failures=$((failures + 1))
  else
    echo "ok   [$mode] installed"
  fi
}

expect_refusal bad-tarball 'does not match the checksum' 8971
expect_refusal bad-integrity 'is not valid' 8972
expect_refusal no-signature 'carries no npm registry signature' 8973
expect_refusal wrong-keyid 'unexpected npm key' 8974
expect_refusal no-integrity 'published no checksum' 8975
expect_install flaky 8976

# 12.15.0 predates `pnpm setup --no-modify-path`, so asking for it is refused
# before anything is downloaded.
latest_version="$version"
version=12.15.0
no_modify_path=1
expect_refusal intact 'PNPM_NO_MODIFY_PATH needs pnpm 12.16.0 or newer' 8977
version="$latest_version"

# With the option, pnpm is installed and no shell config file is written. A
# bash setup would otherwise write .bashrc; a plain sh one has no file to write.
setup_shell=/bin/bash
expect_install intact 8978
setup_shell=
for rc in .profile .bashrc .bash_profile .zshrc .config/fish/config.fish .config/powershell/Microsoft.PowerShell_profile.ps1; do
  if [ -e "$home/$rc" ]; then
    echo "FAIL [no-modify-path] the installer wrote $rc"
    failures=$((failures + 1))
  fi
done
no_modify_path=

[ "$failures" -eq 0 ] || { echo "$failures case(s) failed"; exit 1; }
echo "all verification failures are refused, and transient ones are retried"
