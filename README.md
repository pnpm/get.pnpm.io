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

gpg --verify SHASUMS256.txt.sig SHASUMS256.txt
grep ' install.sh$' SHASUMS256.txt | sha256sum -c -   # on macOS: shasum -a 256 -c -

sh install.sh
```

The first check prints `Good signature`, followed by the key's user IDs; the second prints
`install.sh: OK`. Run the installer only if both pass.

`gpg` also prints `WARNING: The key's User ID is not certified with a trusted signature`.
That is expected — it only means you have not personally certified the key. What
establishes trust is the fingerprint, so compare the one `gpg` reports against the
fingerprint published here.

On Windows (PowerShell):

```powershell
iwr https://get.pnpm.io/install.ps1 -OutFile install.ps1
iwr https://get.pnpm.io/SHASUMS256.txt -OutFile SHASUMS256.txt

$expected = (Select-String -Path SHASUMS256.txt -Pattern ' install\.ps1$').Line.Split(' ')[0]
(Get-FileHash install.ps1 -Algorithm SHA256).Hash -eq $expected.ToUpper()

.\install.ps1
```

The comparison prints `True` if the script matches. To also check the signature, install
[Gpg4win](https://gpg4win.org) and run the same `gpg --verify` command as above.

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

`SHASUMS256.txt` covers the installer scripts served from this site. The pnpm executable
itself is downloaded by the installer from the pnpm release for the version being installed.

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
| **PNPM_VERSION**  | _version | `latest` by default. The pnpm version to be installed.<br>(not older than `pnpm@6.27.2`) | `PNPM_VERSION=6.31.0`                               |
