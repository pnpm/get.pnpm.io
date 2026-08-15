# get-pnpm

> Installs pnpm as a standalone executable

Installs pnpm the same way [the standalone install script](https://github.com/pnpm/get.pnpm.io) does — a self-contained executable in `PNPM_HOME`, on your `PATH`, with no dependency on Node.js afterwards — for people who would rather not pipe a script into a shell.

## Usage

```sh
npx get-pnpm
```

Install a specific version, major, or dist-tag:

```sh
npx get-pnpm 12         # the latest release of pnpm 12
npx get-pnpm next-12    # the pnpm 12 prerelease lane
npx get-pnpm 11.20.0    # an exact version
```

Then open a new terminal, or source the file the installer names in its output.

## How it works

1. Resolves the requested version against the `pnpm` dist-tags.
2. Downloads the executable for your platform from the npm registry.
3. Checks npm's signature over the package's checksum, then the download against that checksum.
4. Runs `pnpm setup`, which installs the executable globally and adds `PNPM_HOME` to your `PATH`.

Step 3 is what makes step 2 worth trusting. The registry publishes both the tarball
and its checksum, so a checksum taken from it proves nothing on its own; npm also
signs `<name>@<version>:<integrity>` with a key that this package pins, and a
download that fails either check is refused rather than installed.

The download goes to the registry npm is configured with (`npm_config_registry`), not to GitHub — including the tarball itself, so a registry that proxies npm and hands back an npmjs.org URL does not send the download off the mirror. The command does not support registries that require authentication; `downloadPnpmExecutable` takes request headers for one.

## Environment variables

| Variable | Description |
| --- | --- |
| `PNPM_VERSION` | Version to install when no argument is given. |
| `PNPM_HOME` | Directory to install pnpm into. |
| `npm_config_registry` | Registry to download pnpm from. |

## Using it from a program

`installPnpm` does what the command does: download, verify, then hand over to
`pnpm setup`, which installs globally and edits your `PATH`. A caller that
manages its own directory — a CI action, say — wants `downloadPnpm` instead,
which verifies and places the executable and nothing else:

```js
import { downloadPnpm } from 'get-pnpm'

const { version, binPath } = await downloadPnpm({
  versionSpec: 'next-12',
  registry: 'https://registry.npmjs.org/',
  dest: '/opt/pnpm',
})
```

A caller that already knows the exact version, and already has everything else
pnpm ships with, wants `downloadPnpmExecutable`: it places the executable at a
path you name and touches nothing else. No dist-tags are resolved, so no
packument is fetched, and the `dist/` tree that travels beside the executable is
left to the caller. Corepack is the case it exists for — it unpacks the `pnpm`
package itself but installs none of its dependencies, so the executable has to
arrive separately.

```js
import { downloadPnpmExecutable } from 'get-pnpm'

await downloadPnpmExecutable({
  version: '12.0.0',
  registry: 'https://registry.npmjs.org/',
  destPath: '/opt/pnpm/pnpm',
  headers: { authorization: 'Bearer …' }, // optional; never sent off the registry
})
```

It verifies exactly what the other two do, and reads the archive in-process
rather than shelling out to `tar`, so it works where no `tar` is on the PATH.
Placement is atomic and tolerates losing a race with a concurrent call.

## Development

```sh
pnpm install
pnpm test     # builds, then runs the tests against the build output
```

The published package runs on Node.js 22.13 and newer. The test runner needs
22.18 or newer, which is where Node runs TypeScript without a flag.

## Other ways to install pnpm

See [pnpm.io/installation](https://pnpm.io/installation). The shell and PowerShell
installers in this repository do the same job for machines without Node.js, and pin
the same npm signing key.
