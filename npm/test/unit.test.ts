import { createSign, generateKeyPairSync } from 'node:crypto'
import assert from 'node:assert/strict'
import { describe, test } from 'node:test'

import { platformPackageName, type Target } from '../lib/platformPackageName.js'
import { resolveVersion } from '../lib/resolveVersion.js'
import { type SigningKey, verifyRegistrySignature } from '../lib/verifySignature.js'

describe('resolveVersion', () => {
  const packument = {
    'dist-tags': { latest: '11.20.0', 'latest-10': '10.34.5', 'next-12': '12.0.0-rc.1' },
    versions: { '10.34.5': {}, '11.19.0': {}, '11.20.0': {}, '12.0.0-rc.1': {} },
  }

  test('resolves a dist-tag', () => {
    assert.equal(resolveVersion(packument, 'latest'), '11.20.0')
    assert.equal(resolveVersion(packument, 'next-12'), '12.0.0-rc.1')
  })

  test('resolves an exact version, with or without a leading v', () => {
    assert.equal(resolveVersion(packument, '11.19.0'), '11.19.0')
    assert.equal(resolveVersion(packument, 'v11.19.0'), '11.19.0')
  })

  test('resolves a bare major, preferring the stable release', () => {
    assert.equal(resolveVersion(packument, '10'), '10.34.5')
    assert.equal(resolveVersion(packument, '12'), '12.0.0-rc.1')
  })

  test('lists the available tags when nothing matches', () => {
    assert.throws(() => resolveVersion(packument, '9'), /could not be found.*latest, latest-10, next-12/s)
  })
})

describe('platformPackageName', () => {
  const target = (overrides: Partial<Target>): Target =>
    ({ major: 11, platform: 'linux', arch: 'x64', musl: false, ...overrides })

  test('v11 and older use the legacy names', () => {
    assert.equal(platformPackageName(target({})), '@pnpm/linux-x64')
    assert.equal(platformPackageName(target({ musl: true })), '@pnpm/linuxstatic-x64')
    assert.equal(platformPackageName(target({ platform: 'darwin', arch: 'arm64' })), '@pnpm/macos-arm64')
    assert.equal(platformPackageName(target({ platform: 'win32' })), '@pnpm/win-x64')
  })

  test('v12 and newer use the process.platform-based names', () => {
    assert.equal(platformPackageName(target({ major: 12 })), '@pnpm/exe.linux-x64')
    assert.equal(platformPackageName(target({ major: 12, musl: true })), '@pnpm/exe.linux-x64-musl')
    assert.equal(platformPackageName(target({ major: 12, platform: 'win32', arch: 'arm64' })), '@pnpm/exe.win32-arm64')
  })

  test('the musl suffix is Linux-only', () => {
    assert.equal(platformPackageName(target({ platform: 'darwin', arch: 'arm64', musl: true })), '@pnpm/macos-arm64')
  })

  test('rejects hosts pnpm publishes no binary for', () => {
    assert.throws(() => platformPackageName(target({ arch: 'ia32' })), /x86_64\/arm64/)
    assert.throws(() => platformPackageName(target({ platform: 'freebsd' })), /freebsd/)
  })

  test('points Intel macOS users away from v11, which has no working binary', () => {
    assert.throws(() => platformPackageName(target({ platform: 'darwin', arch: 'x64' })), /Intel macOS/s)
    assert.equal(platformPackageName(target({ major: 10, platform: 'darwin', arch: 'x64' })), '@pnpm/macos-x64')
  })
})

describe('verifyRegistrySignature', () => {
  const { privateKey, publicKey } = generateKeyPairSync('ec', { namedCurve: 'prime256v1' })
  const KEY_ID = 'SHA256:test-key'
  const keys: SigningKey[] = [{
    keyid: KEY_ID,
    key: publicKey.export({ type: 'spki', format: 'der' }).toString('base64'),
    expires: null,
  }]
  const name = '@pnpm/exe.linux-x64'
  const version = '12.0.0'
  const integrity = 'sha512-Zm9vYmFy'
  const sign = (message: string, key = privateKey): string => createSign('SHA256').update(message).sign(key, 'base64')
  const signatures = [{ keyid: KEY_ID, sig: sign(`${name}@${version}:${integrity}`) }]

  test('accepts a signature over the package identity and checksum', () => {
    verifyRegistrySignature({ name, version, integrity, signatures, keys })
  })

  test('rejects a signature made over a different checksum', () => {
    assert.throws(() => verifyRegistrySignature({
      name, version, integrity, keys,
      signatures: [{ keyid: KEY_ID, sig: sign(`${name}@${version}:sha512-dGFtcGVyZWQ=`) }],
    }), /is not valid/)
  })

  test('rejects a signature made over a different package', () => {
    assert.throws(() => verifyRegistrySignature({
      name, version, integrity, keys,
      signatures: [{ keyid: KEY_ID, sig: sign(`@evil/pkg@${version}:${integrity}`) }],
    }), /is not valid/)
  })

  test('rejects a signature made with an untrusted key', () => {
    const attacker = generateKeyPairSync('ec', { namedCurve: 'prime256v1' })
    assert.throws(() => verifyRegistrySignature({
      name, version, integrity, keys,
      signatures: [{ keyid: KEY_ID, sig: sign(`${name}@${version}:${integrity}`, attacker.privateKey) }],
    }), /is not valid/)
  })

  test('rejects a keyid that is not pinned', () => {
    assert.throws(() => verifyRegistrySignature({
      name, version, integrity, keys,
      signatures: [{ keyid: 'SHA256:someone-else', sig: signatures[0]!.sig }],
    }), /unexpected npm key/)
  })

  test('rejects an unsigned package', () => {
    assert.throws(() => verifyRegistrySignature({ name, version, integrity, keys }), /carries no npm registry signature/)
    assert.throws(() => verifyRegistrySignature({ name, version, integrity, keys, signatures: [] }), /carries no npm registry signature/)
  })

  test('picks the signature made with a pinned key, whatever its position', () => {
    const rotated = [
      { keyid: 'SHA256:not-pinned-yet', sig: sign(`${name}@${version}:${integrity}`) },
      ...signatures,
    ]
    verifyRegistrySignature({ name, version, integrity, signatures: rotated, keys })
  })

  test('rejects a key whose expiry date cannot be read', () => {
    assert.throws(() => verifyRegistrySignature({
      name, version, integrity, signatures, keys: [{ ...keys[0]!, expires: 'not a date' }],
    }), /expiry date cannot be read/)
  })

  test('rejects a key that has expired, and accepts one that has not', () => {
    const expiring = [{ ...keys[0]!, expires: '2020-01-01T00:00:00.000Z' }]
    assert.throws(() => verifyRegistrySignature({ name, version, integrity, signatures, keys: expiring }), /expired on 2020-01-01/)
    verifyRegistrySignature({ name, version, integrity, signatures, keys: expiring, now: new Date('2019-01-01') })
  })
})
