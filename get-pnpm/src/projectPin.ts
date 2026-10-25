import fs from 'node:fs'
import path from 'node:path'

import semver from 'semver'

/** The pnpm version a project pins, and where the pin was read from. */
export interface ProjectPin {
  /** An exact version, or a range for `resolveVersion` to resolve. */
  spec: string
  /** The manifest that declares the pin. */
  manifestPath: string
  /** The field of the manifest that declares it. */
  field: 'devEngines.packageManager' | 'packageManager'
  /** The version `pnpm-lock.yaml` records for a range pin, when it is still in range. */
  lockedVersion?: string
}

/** The basenames pnpm reads a project manifest from, in the order it tries them. */
const MANIFEST_NAMES = ['package.json', 'package.json5', 'package.yaml']

/**
 * The pnpm version that the project `dir` belongs to pins, read the way pnpm
 * reads it to switch to that version.
 *
 * The pin of a workspace is the one in the manifest of its root, the nearest
 * directory up from `dir` with a `pnpm-workspace.yaml`; outside a workspace it
 * is the one in the nearest manifest. `devEngines.packageManager` takes
 * precedence over `packageManager`, which pnpm reads only as an exact version.
 * A range pin comes with the version the lockfile already settled on, which
 * is the one pnpm switches to while it stays in range.
 *
 * `opts.root` stops the search for both at that directory, such as the root
 * of a checkout, which keeps a workspace that happens to sit above it out.
 *
 * @returns `undefined` when there is no pnpm pin to read: no manifest, one
 * that pins no package manager or another one, or a `package.json5` or
 * `package.yaml`, which would each take a parser of their own.
 * @throws if the manifest pins pnpm in a way pnpm itself would reject.
 */
export function readProjectPin (dir: string, opts: { root?: string } = {}): ProjectPin | undefined {
  const start = path.resolve(dir)
  const root = opts.root == null ? undefined : path.resolve(opts.root)
  const workspaceDir = findUp(start, root, (candidate) => fs.existsSync(path.join(candidate, 'pnpm-workspace.yaml')))
  const projectDir = findUp(start, root, (candidate) => MANIFEST_NAMES.some((name) => fs.existsSync(path.join(candidate, name))))
  const manifest = readManifest(workspaceDir ?? projectDir)
  const wanted = manifest == null ? undefined : wantedPnpm(manifest)
  if (wanted == null) return undefined
  const pin = { ...wanted, manifestPath: manifest!.path }
  if (semver.valid(pin.spec) != null) return pin
  const lockfileDir = workspaceDir != null && sharesNoLockfile(workspaceDir) ? projectDir : workspaceDir ?? projectDir
  const lockedVersion = lockfileDir == null ? undefined : lockedPnpmVersion(lockfileDir, pin.spec)
  return lockedVersion == null ? pin : { ...pin, lockedVersion }
}

interface Manifest {
  path: string
  value: Record<string, unknown>
}

function readManifest (dir: string | undefined): Manifest | undefined {
  if (dir == null) return undefined
  for (const name of MANIFEST_NAMES) {
    const manifestPath = path.join(dir, name)
    const content = readOptionalFile(manifestPath)
    if (content == null) continue
    if (name !== 'package.json') return undefined
    const value = parseJson(manifestPath, content)
    if (!isRecord(value)) throw new Error(`${manifestPath} does not hold an object.`)
    return { path: manifestPath, value }
  }
  return undefined
}

function parseJson (file: string, content: string): unknown {
  try {
    // Windows tools write a byte order mark, which pnpm reads past.
    return JSON.parse(content.replace(/^\uFEFF/, ''))
  } catch (err) {
    throw new Error(`${file} is not valid JSON: ${(err as Error).message}`, { cause: err })
  }
}

function wantedPnpm (manifest: Manifest): Pick<ProjectPin, 'spec' | 'field'> | undefined {
  const engine = devEnginesPackageManager(manifest.value)
  if (engine != null) return engine.name === 'pnpm' ? devEnginesPin(manifest, engine.version) : undefined
  const { packageManager } = manifest.value
  return typeof packageManager === 'string' ? packageManagerPin(manifest, packageManager) : undefined
}

function devEnginesPin (manifest: Manifest, version: unknown): Pick<ProjectPin, 'spec' | 'field'> {
  if (typeof version !== 'string' || semver.validRange(version) == null) {
    throw new Error(`${manifest.path} names pnpm in devEngines.packageManager, but no version or range of it.`)
  }
  return { spec: version, field: 'devEngines.packageManager' }
}

function packageManagerPin (manifest: Manifest, packageManager: string): Pick<ProjectPin, 'spec' | 'field'> | undefined {
  // `pnpm@12.1.0+sha512.<hash>`: the build names the artifact Corepack downloaded,
  // not a pnpm release.
  const separator = packageManager.lastIndexOf('@')
  if (separator <= 0 || packageManager.slice(0, separator) !== 'pnpm') return undefined
  const version = packageManager.slice(separator + 1).split('+')[0]!
  if (semver.valid(version) !== version) {
    throw new Error(`${manifest.path} sets packageManager to "${packageManager}", which pins no exact pnpm version.`)
  }
  return { spec: version, field: 'packageManager' }
}

/** The entry that governs pnpm: pnpm's own in a list, or else the first one. */
function devEnginesPackageManager (manifest: Record<string, unknown>): Record<string, unknown> | undefined {
  const declared = isRecord(manifest.devEngines) ? manifest.devEngines.packageManager : undefined
  if (!Array.isArray(declared)) return isRecord(declared) ? declared : undefined
  const entries = declared.filter(isRecord)
  return entries.find((entry) => entry.name === 'pnpm') ?? entries[0]
}

/** Whether every project of the workspace keeps a lockfile of its own. */
function sharesNoLockfile (workspaceDir: string): boolean {
  const workspace = fs.readFileSync(path.join(workspaceDir, 'pnpm-workspace.yaml'), 'utf8')
  // A top-level key, so it starts a line of its own.
  return /^sharedWorkspaceLockfile:\s*false\s*(?:#.*)?$/m.test(workspace)
}

function lockedPnpmVersion (lockfileDir: string, range: string): string | undefined {
  const content = readOptionalFile(path.join(lockfileDir, 'pnpm-lock.yaml'))
  const envDocument = content == null ? undefined : extractEnvDocument(content)
  if (envDocument == null) return undefined
  const locked = blockScalarAt(envDocument, ['importers', '.', 'packageManagerDependencies', 'pnpm', 'version'])
  // In range the way pnpm checks a locked version, prereleases included.
  if (typeof locked !== 'string' || semver.valid(locked) == null) return undefined
  return semver.satisfies(locked, range, { includePrerelease: true }) ? locked : undefined
}

/**
 * The document that leads a pnpm 11+ lockfile and records the package
 * manager. Sliced out rather than parsed with the rest, which runs to
 * megabytes in a large workspace.
 */
function extractEnvDocument (content: string): string | undefined {
  const normalized = content.replace(/^\uFEFF/, '').replaceAll('\r\n', '\n')
  if (!normalized.startsWith('---\n')) return undefined
  const end = normalized.indexOf('\n---\n', 4)
  return end === -1 ? normalized.slice(4).replace(/\n---\n?$/, '') : normalized.slice(4, end)
}

/**
 * The scalar at `keys` in `yaml`, read as the block mappings pnpm writes its
 * lockfile in: a `key:` per line, nested by indentation, with a plain or
 * quoted value. That is all the env document holds on the way to the pnpm
 * version, and it keeps a YAML parser out of the dependencies.
 */
function blockScalarAt (yaml: string, keys: string[]): string | undefined {
  const path: Array<{ indent: number, key: string }> = []
  for (const line of yaml.split('\n')) {
    const entry = parseBlockLine(line)
    if (entry == null) continue
    while (path.length > 0 && path.at(-1)!.indent >= entry.indent) path.pop()
    path.push(entry)
    if (path.length === keys.length && path.every(({ key }, index) => key === keys[index])) {
      return entry.value
    }
  }
  return undefined
}

function parseBlockLine (line: string): { indent: number, key: string, value?: string } | undefined {
  const match = /^( *)('[^']*'|"[^"]*"|[^\s'"#][^:]*):(?: (.*))?$/.exec(line)
  if (match == null) return undefined
  const value = match[3]?.trim()
  return { indent: match[1]!.length, key: unquote(match[2]!), value: value ? unquote(value) : undefined }
}

function unquote (scalar: string): string {
  if (scalar.length >= 2 && scalar.startsWith("'") && scalar.endsWith("'")) return scalar.slice(1, -1).replaceAll("''", "'")
  if (scalar.length >= 2 && scalar.startsWith('"') && scalar.endsWith('"')) return scalar.slice(1, -1)
  return scalar
}

export function findUp (start: string, root: string | undefined, matches: (dir: string) => boolean): string | undefined {
  for (let dir = start; ; dir = path.dirname(dir)) {
    if (matches(dir)) return dir
    if (dir === root || path.dirname(dir) === dir) return undefined
  }
}

function readOptionalFile (file: string): string | undefined {
  try {
    return fs.readFileSync(file, 'utf8')
  } catch (err) {
    if ((err as NodeJS.ErrnoException).code === 'ENOENT') return undefined
    throw err
  }
}

function isRecord (value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value != null && !Array.isArray(value)
}
