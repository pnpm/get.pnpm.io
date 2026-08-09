import { createHash } from 'node:crypto'
import { createWriteStream } from 'node:fs'
import { pipeline } from 'node:stream/promises'

import type { Packument } from './resolveVersion.js'
import type { PackageSignature } from './verifySignature.js'

export interface VersionMeta {
  dist: {
    tarball: string
    integrity?: string
    signatures?: PackageSignature[]
  }
}

const ABBREVIATED_PACKUMENT = 'application/vnd.npm.install-v1+json'

export const DEFAULT_REGISTRY = 'https://registry.npmjs.org/'

/** The registry npx/npm is configured with, so a mirror stays a mirror. */
export function registryFromEnv (): string {
  const registry = process.env.npm_config_registry ?? process.env.NPM_CONFIG_REGISTRY ?? DEFAULT_REGISTRY
  return registry.endsWith('/') ? registry : `${registry}/`
}

// Node's fetch applies no timeout of its own: a registry that accepts the
// connection and then stalls would hang the install with no output. Metadata is
// small and quick; the tarball budget has to survive a slow connection carrying
// a ~150 MB download.
const METADATA_TIMEOUT_MS = 30_000
const TARBALL_TIMEOUT_MS = 15 * 60_000

export async function fetchPackument (registry: string, pkgName: string): Promise<Packument> {
  return fetchJson<Packument>(new URL(pkgName, registry), ABBREVIATED_PACKUMENT)
}

export async function fetchVersionMeta (registry: string, pkgName: string, version: string): Promise<VersionMeta> {
  return fetchJson<VersionMeta>(new URL(`${pkgName}/${version}`, registry), 'application/json')
}

/**
 * Streams `meta.dist.tarball` to `dest`, verifying the checksum the registry
 * published for it. A mismatch removes nothing — the caller discards the whole
 * temporary directory.
 */
export async function downloadTarball (meta: VersionMeta, dest: string): Promise<void> {
  const response = await request(new URL(meta.dist.tarball), undefined, TARBALL_TIMEOUT_MS)
  const [algorithm, expected] = checksum(meta)
  const hash = createHash(algorithm)
  const body = response.body as unknown as AsyncIterable<Uint8Array>
  await pipeline(
    async function * () {
      for await (const chunk of body) {
        hash.update(chunk)
        yield chunk
      }
    },
    createWriteStream(dest)
  )
  const actual = hash.digest('base64')
  if (actual !== expected) {
    throw new Error(`The download from ${meta.dist.tarball} does not match the checksum the npm registry published for it. Refusing to install.`)
  }
}

/**
 * The algorithm and digest to check a tarball against.
 *
 * `integrity` is an SRI string, which may hold several space-separated entries;
 * the first is used. Only the digest that the registry signature covers is
 * accepted — `shasum` is SHA-1, and a package without `integrity` has already
 * been refused before any download starts.
 */
function checksum (meta: VersionMeta): [algorithm: string, expected: string] {
  const entry = meta.dist.integrity?.trim().split(/\s+/)[0]
  if (!entry) {
    throw new Error(`The registry published no checksum for ${meta.dist.tarball}, so it cannot be verified.`)
  }
  const separator = entry.indexOf('-')
  if (separator === -1) {
    throw new Error(`The registry published an unreadable checksum for ${meta.dist.tarball}: ${entry}`)
  }
  return [entry.slice(0, separator), entry.slice(separator + 1)]
}

async function fetchJson<T> (url: URL, accept: string): Promise<T> {
  const response = await request(url, accept, METADATA_TIMEOUT_MS)
  return await response.json() as T
}

async function request (url: URL, accept: string | undefined, timeoutMs: number): Promise<Response> {
  let response: Response
  try {
    response = await fetch(url, {
      signal: AbortSignal.timeout(timeoutMs),
      ...(accept ? { headers: { accept } } : {}),
    })
  } catch (err) {
    const reason = (err as Error).name === 'TimeoutError'
      ? `timed out after ${Math.round(timeoutMs / 1000)}s`
      : (err as Error).message
    throw new Error(`Could not reach ${url.href}: ${reason}`, { cause: err })
  }
  if (!response.ok) {
    throw new Error(`Could not download ${url.href}: ${response.status} ${response.statusText}`)
  }
  if (response.body == null) {
    throw new Error(`Empty response from ${url.href}`)
  }
  return response
}
