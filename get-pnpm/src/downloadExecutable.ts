import { randomBytes } from 'node:crypto'
import fs from 'node:fs'
import path from 'node:path'

import { extractTarballMember } from './extractTarballMember.js'
import { isMusl, platformPackageName } from './platformPackageName.js'
import { downloadTarball, fetchVersionMeta, type RequestHeaders } from './registry.js'
import { majorVersion } from './resolveVersion.js'
import { type SigningKey, verifyRegistrySignature } from './verifySignature.js'

/** Name the executable is published under inside its platform package. */
function executableName (): string {
  return process.platform === 'win32' ? 'pnpm.exe' : 'pnpm'
}

export interface DownloadExecutableOptions {
  /** Exact version to download; nothing is resolved against dist-tags. */
  version: string
  /** Registry to download from, e.g. from {@link registryFromEnv}. */
  registry: string
  /** Path to place the executable at. */
  destPath: string
  /** Credentials for `registry`, withheld from any other origin. */
  headers?: RequestHeaders
  /** Overrides the pinned npm signing keys; for tests. */
  keys?: readonly SigningKey[]
}

/**
 * Places the pnpm executable for this host at `destPath`, and nothing else.
 *
 * The narrow half of {@link downloadPnpm}, for a caller that already knows the
 * exact version and already has whatever else it needs: no dist-tag lookup (so
 * no packument download), no `dist/` tree, no directory to assemble. Corepack
 * is the case it exists for — it unpacks the `pnpm` package itself but installs
 * none of its dependencies, so the executable has to arrive separately.
 *
 * The download is checked against the checksum the registry published for it,
 * and that checksum against npm's signature, exactly as {@link downloadPnpm}
 * does. Nothing is written to `destPath` until both pass.
 *
 * Placement is atomic and tolerates losing a race: a concurrent call that got
 * there first keeps its copy, since both placed the same verified bytes.
 *
 * @returns the package the executable came from.
 */
export async function downloadPnpmExecutable (opts: DownloadExecutableOptions): Promise<{ packageName: string }> {
  const { version, registry, destPath } = opts
  const packageName = platformPackageName({
    major: majorVersion(version),
    platform: process.platform,
    arch: process.arch,
    musl: isMusl(),
  })

  const meta = await fetchVersionMeta(registry, packageName, version, opts.headers)
  if (!meta.dist.integrity) {
    throw new Error(`The npm registry published no checksum for ${packageName}@${version}, so it cannot be verified.`)
  }
  verifyRegistrySignature({
    name: packageName,
    version,
    integrity: meta.dist.integrity,
    signatures: meta.dist.signatures,
    keys: opts.keys,
  })

  const scratch = `${destPath}.${randomBytes(6).toString('hex')}`
  const tarball = `${scratch}.tgz`
  const staged = `${scratch}.tmp`
  fs.mkdirSync(path.dirname(destPath), { recursive: true })
  try {
    await downloadTarball(meta, tarball, { registry, headers: opts.headers })
    const member = `package/${executableName()}`
    if (!await extractTarballMember(tarball, member, staged, 0o755)) {
      throw new Error(`The ${packageName}@${version} tarball contains no ${member}.`)
    }
    place(staged, destPath)
  } finally {
    fs.rmSync(tarball, { force: true })
    fs.rmSync(staged, { force: true })
  }
  return { packageName }
}

/**
 * Moves the verified executable into place, keeping whatever a concurrent call
 * already put there — on Windows the rename fails outright once that copy is
 * being executed. What is in the way has to be a plain file: a directory or a
 * symlink is not something this function leaves behind.
 */
function place (staged: string, destPath: string): void {
  try {
    fs.renameSync(staged, destPath)
  } catch (err) {
    if (fs.lstatSync(destPath, { throwIfNoEntry: false })?.isFile() !== true) throw err
  }
}
