# pnpm installer

## Usage

On POSIX systems, you may install pnpm even if you don't have Node.js installed, using the following script:

```sh
curl -fsSL https://get.pnpm.io | sh -
```

If you don't have curl installed, you would like to use wget:

```sh
wget -qO- https://get.pnpm.io | sh -
```

On Windows (PowerShell):

```sh
iwr https://get.pnpm.io/ps1 -useb | iex
```

`https://get.pnpm.io` and `https://get.pnpm.io/ps1` serve the same files as
`https://get.pnpm.io/install.sh` and `https://get.pnpm.io/install.ps1`, which keep working.

These commands run the installer as soon as it is downloaded. To check that it is
the script pnpm published before running it, see [Verifying files](#verifying-files).

## Verifying files

The installer scripts served from this site are listed in [`SHASUMS256.txt`](https://get.pnpm.io/SHASUMS256.txt),
which is signed with the pnpm release key. Verifying takes two steps: check that the
checksum file carries a good signature, then check the script against its checksum.

On POSIX systems:

```sh
curl -fsSLO https://get.pnpm.io/install.sh
curl -fsSLO https://get.pnpm.io/SHASUMS256.txt
curl -fsSLO https://get.pnpm.io/SHASUMS256.txt.sig

# Import the pnpm release key (compare the fingerprint with the one below)
curl -fsSL https://keys.openpgp.org/vks/v1/by-fingerprint/4D20AD76D7BE567214F3F8EE4EABAE7510A044FA | gpg --import

gpg --verify SHASUMS256.txt.sig SHASUMS256.txt \
  && grep ' install.sh$' SHASUMS256.txt | sha256sum -c - \
  && sh install.sh
```

The steps are chained, so the installer does not run unless both checks pass. The first
prints `Good signature`, followed by the key's user IDs; the second prints `install.sh: OK`.

macOS has no `sha256sum` — use `shasum -a 256 -c -` in its place.

`gpg` also prints `WARNING: The key's User ID is not certified with a trusted signature`.
That is expected — it only means you have not personally certified the key. What
establishes trust is the fingerprint, so compare the one `gpg` reports against the
fingerprint published here.

On Windows (PowerShell). `gpg` is not part of Windows — [Gpg4win](https://gpg4win.org)
provides it:

```powershell
iwr https://get.pnpm.io/install.ps1 -OutFile install.ps1
iwr https://get.pnpm.io/SHASUMS256.txt -OutFile SHASUMS256.txt
iwr https://get.pnpm.io/SHASUMS256.txt.sig -OutFile SHASUMS256.txt.sig

# Import the pnpm release key (compare the fingerprint with the one below)
iwr https://keys.openpgp.org/vks/v1/by-fingerprint/4D20AD76D7BE567214F3F8EE4EABAE7510A044FA -OutFile pnpm.asc
gpg --import pnpm.asc

gpg --verify SHASUMS256.txt.sig SHASUMS256.txt
if ($LASTEXITCODE -ne 0) { throw 'SHASUMS256.txt is not signed by the pnpm release key' }

$expected = (Select-String -Path SHASUMS256.txt -Pattern ' install\.ps1$').Line.Split(' ')[0]
if ((Get-FileHash install.ps1 -Algorithm SHA256).Hash -ne $expected.ToUpper()) {
  throw 'install.ps1 does not match its published checksum'
}

.\install.ps1
```

Both checks stop the script rather than fall through to the installer. Skipping the
signature step is not equivalent to running it: the checksums are served from the same
site as the installer, so on their own they only prove the two files agree with each
other. The signature is what ties them to the pnpm release key.

### The pnpm release key

| | Fingerprint |
| --- | --- |
| Primary key | `4D20AD76D7BE567214F3F8EE4EABAE7510A044FA` |
| Signing subkey | `432EDF21183B9FE186AA53247CBF6055273E6CB5` |

The key is published on [keys.openpgp.org](https://keys.openpgp.org/search?q=4D20AD76D7BE567214F3F8EE4EABAE7510A044FA),
which serves it by either fingerprint above:

```sh
curl -fsSL https://keys.openpgp.org/vks/v1/by-fingerprint/4D20AD76D7BE567214F3F8EE4EABAE7510A044FA | gpg --import
```

`SHASUMS256.txt` lists the installer scripts served from this site — `install.sh`,
`install.ps1`, and the legacy `v6*.js` installers. What the installer downloads afterwards
is covered separately, below.

### How the downloaded executable is verified

pnpm 12 and newer are downloaded from the npm registry, which publishes a signature over
each package's checksum. The installer pins npm's public key, checks that signature, and
then checks the downloaded file against the signed checksum. Neither a tampered download
nor a tampered checksum passes, because the key that signs them is not one the download
host can mint. The executable is identical to the one on the GitHub release page.

Signature checking needs `openssl` (POSIX) or PowerShell 7 (Windows). Without them the
installer says so and checks the download against the registry's checksum only — which,
coming from the same host as the download, catches corruption rather than tampering.

pnpm 11 and older are downloaded from the GitHub release page, which publishes no
signature, so those downloads are not verified. To check one yourself, GitHub attests
every release asset — name the file you downloaded, which for pnpm 11 and older follows
the older scheme (`pnpm-macos-*`, `pnpm-win-*`, `pnpm-linuxstatic-*`):

```sh
gh attestation verify pnpm-linux-x64.tar.gz --repo pnpm/pnpm    # v11+
gh attestation verify pnpm-macos-arm64 --repo pnpm/pnpm         # v10 and older
```

That confirms the file was built by pnpm's release workflow from the signed release tag,
and the attestation is recorded in a public transparency log.

## If `pnpm --version` still prints the old version

A `pnpm` installed another way — `npm install -g pnpm`, Homebrew, Corepack, Volta —
that comes before `$PNPM_HOME/bin` on your `PATH` keeps running after the installer
finishes. The installer looks for one when it is done and says which it found and how
to remove it, for example:

```text
Warning: "pnpm" on PATH is /opt/homebrew/bin/pnpm (installed with npm), which comes before /Users/me/Library/pnpm/bin.
Your shell keeps running that pnpm, not the one pnpm installed to /Users/me/Library/pnpm/bin.
To finish switching, run "npm uninstall -g pnpm" or move /Users/me/Library/pnpm/bin ahead of /opt/homebrew/bin in PATH.
```

`pnpm doctor` reports the same thing later, and `pnpm self-update` warns the same way.

## Uninstalling

The installers put pnpm in `PNPM_HOME` and run `pnpm setup`, which puts
`$PNPM_HOME/bin` on your `PATH`. To undo both:

1. Delete the `PNPM_HOME` directory — `~/.local/share/pnpm` on Linux,
   `~/Library/pnpm` on macOS, `%LOCALAPPDATA%\pnpm` on Windows, unless you set
   `PNPM_HOME` or `XDG_DATA_HOME`.
2. On Linux and macOS, delete the lines `pnpm setup` added to your shell's rc file
   (`~/.bashrc`, `~/.zshrc`, `~/.config/fish/config.fish`, or
   `~/.config/nushell/env.nu`): the block from `# pnpm` to `# pnpm end`, or the
   unmarked `PNPM_HOME` and `PATH` lines older pnpm versions write. On Windows, remove
   the `PNPM_HOME` variable and the `Path` entry pointing into it (`%PNPM_HOME%`,
   `%PNPM_HOME%\bin`, or the expanded path) under *Edit environment variables for
   your account*.
3. Open a new terminal.

See [pnpm.io/uninstall](https://pnpm.io/uninstall) for removing global packages and
the store first.

## Configuring

By default, the script will install the latest version of pnpm. A specific version can be installed by specifying the `PNPM_VERSION` environment variable:

```sh
curl -fsSL https://get.pnpm.io | PNPM_VERSION=6.27.2 sh -
```

```sh
$env:PNPM_VERSION='6.27.2' ; iwr https://get.pnpm.io/ps1 -useb | iex
```

`PNPM_VERSION` also takes a bare major, which installs that major's current
release — its `latest-<major>` dist-tag, or `next-<major>` for a major that has
not been promoted to stable yet:

```sh
curl -fsSL https://get.pnpm.io | PNPM_VERSION=12 sh -
```

All the supported environment variables that can influence pnpm's installation:

| Env variable      | Type                  | Description                                                                              | Example                                           |
| ----------------- | --------------------- | ---------------------------------------------------------------------------------------- | ------------------------------------------------- |
| **PNPM_VERSION**  | _version, major, or dist-tag_ | `latest` by default. The pnpm version to be installed, as a version, a major, or a dist-tag.<br>(not older than `pnpm@6.27.2`) | `PNPM_VERSION=6.31.0`<br>`PNPM_VERSION=12`<br>`PNPM_VERSION=next-12` |
