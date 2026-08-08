import { createVerify } from 'node:crypto'

import { NPM_SIGNING_KEYS } from './npmSigningKeys.js'

export interface SigningKey {
  keyid: string
  key: string
  expires: string | null
}

export interface PackageSignature {
  keyid: string
  sig: string
}

/**
 * Checks the registry's signature over a package's identity and checksum.
 *
 * The registry serves both the tarball and the checksum, so a checksum taken
 * from it proves nothing on its own. This is what makes it worth anything: the
 * signature is made with a key the registry publishes but the download host
 * cannot mint, and the trusted copy of that key ships inside this package.
 *
 * @throws if the package is unsigned, signed with a key that isn't trusted or
 * has expired, or the signature does not verify.
 */
export function verifyRegistrySignature (
  opts: {
    name: string
    version: string
    integrity: string
    signatures?: PackageSignature[]
    keys?: readonly SigningKey[]
    now?: Date
  }
): void {
  const pkg = `${opts.name}@${opts.version}`
  const signature = opts.signatures?.[0]
  if (signature == null) {
    throw new Error(`${pkg} carries no npm registry signature, so it cannot be verified.`)
  }

  const keys = opts.keys ?? NPM_SIGNING_KEYS
  const key = keys.find(({ keyid }) => keyid === signature.keyid)
  if (key == null) {
    throw new Error(`${pkg} is signed with an unexpected npm key (${signature.keyid}).

If npm has rotated its signing key, this installer needs updating.
Until then, install pnpm another way: https://pnpm.io/installation`)
  }
  if (key.expires != null && new Date(key.expires) < (opts.now ?? new Date())) {
    throw new Error(`${pkg} is signed with an npm key that expired on ${key.expires}.`)
  }

  // Registry signatures cover the package identity and its content hash.
  const message = `${pkg}:${opts.integrity}`
  const publicKey = `-----BEGIN PUBLIC KEY-----\n${key.key}\n-----END PUBLIC KEY-----`
  if (!createVerify('SHA256').update(message).verify(publicKey, signature.sig, 'base64')) {
    throw new Error(`The npm registry signature for ${pkg} is not valid. Refusing to install.`)
  }
}
