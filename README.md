# PNPM installer

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

## Verifying files

To download `SHASUMS256.txt` using curl:

```sh
curl -O https://get.pnpm.io/SHASUMS256.txt
```

To check that a downloaded file matches the checksum, run it through sha256sum with a command such as:

```sh
grep v6.16.js SHASUMS256.txt | sha256sum -c -
```

The GPG detached signature of `SHASUMS256.txt` is in `SHASUMS256.txt.sig`.
You can use it with `gpg` to verify the integrity of `SHASUMS256.txt`.
You will first need to import the GPG keys of individuals authorized to create releases.
To import the keys:

```sh
curl https://keybase.io/pnpm/pgp_keys.asc | gpg --import
```

Next, download the `SHASUMS256.txt.sig`:

```sh
curl -O https://get.pnpm.io/SHASUMS256.txt.sig
```

Then use the following script to verify the file's signature:

```sh
gpg --verify SHASUMS256.txt.sig SHASUMS256.txt
```

## Configuring

By default, the script will install the latest version of pnpm. A specific version can be installed by specifying the `PNPM_VERSION` environment variable:

```sh
curl -fsSL https://get.pnpm.io/install.sh | PNPM_VERSION=6.27.2 sh -
```

All the supported environment variables that can influence pnpm's installation:

| Env variable      | Type                  | Description                                                                              | Example                                           |
| ----------------- | --------------------- | ---------------------------------------------------------------------------------------- | ------------------------------------------------- |
| **PNPM_VERSION**  | _version | `latest` by default. The pnpm version to be installed.<br>(not older than `pnpm@6.27.2`) | `PNPM_VERSION=next`                               |
