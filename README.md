# pnpm installer

## Usage

On POSIX systems, you may install pnpm even if you don't have Node.js installed, using the following script:

```sh
curl -fsSL https://get.pnpm.io/install.sh | sh -
```

If you don't have curl installed, you would like to use wget:

```sh
wget -qO- https://get.pnpm.io/install.sh | sh -
```

On Windows (PowerShell):

```sh
iwr https://get.pnpm.io/install.ps1 -useb | iex
```

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

The key is published on [keys.openpgp.org](https://keys.openpgp.org/search?q=4D20AD76D7BE567214F3F8EE4EABAE7510A044FA)
and on [Keybase](https://keybase.io/pnpm/pgp_keys.asc). Both serve the same key, so either
source works:

```sh
curl -fsSL https://keybase.io/pnpm/pgp_keys.asc | gpg --import
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
installer falls back to the checksum alone and says so.

pnpm 11 and older are downloaded from the GitHub release page, which publishes no
signature, so those downloads are not verified. To check one yourself, GitHub attests
every release asset:

```sh
gh attestation verify pnpm-linux-x64.tar.gz --repo pnpm/pnpm
```

That confirms the file was built by pnpm's release workflow from the signed release tag,
and the attestation is recorded in a public transparency log.

## Configuring

By default, the script will install the latest version of pnpm. A specific version can be installed by specifying the `PNPM_VERSION` environment variable:

```sh
curl -fsSL https://get.pnpm.io/install.sh | PNPM_VERSION=6.27.2 sh -
```

```sh
$env:PNPM_VERSION='6.27.2' ; iwr https://get.pnpm.io/install.ps1 -useb | iex
```

All the supported environment variables that can influence pnpm's installation:

| Env variable      | Type                  | Description                                                                              | Example                                           |
| ----------------- | --------------------- | ---------------------------------------------------------------------------------------- | ------------------------------------------------- |
| **PNPM_VERSION**  | _version or dist-tag | `latest` by default. The pnpm version to be installed, as a version or a dist-tag.<br>(not older than `pnpm@6.27.2`) | `PNPM_VERSION=6.31.0`<br>`PNPM_VERSION=next-12` |
