import { spawnSync } from 'node:child_process'
import assert from 'node:assert/strict'
import { createHash, createSign, generateKeyPairSync } from 'node:crypto'
import fs from 'node:fs'
import http from 'node:http'
import os from 'node:os'
import path from 'node:path'
import { after, before, describe, test } from 'node:test'

import { installPnpm } from '../lib/index.js'
import type { SigningKey } from '../lib/verifySignature.js'

const VERSION = '99.0.0'

// The pinned key is npm's, so these tests sign with their own and pass it in.
// Nothing served here can satisfy the real key — which is the point of pinning.
const { privateKey, publicKey } = generateKeyPairSync('ec', { namedCurve: 'prime256v1' })
const KEYS: SigningKey[] = [{
  keyid: 'SHA256:test-key',
  key: publicKey.export({ type: 'spki', format: 'der' }).toString('base64'),
  expires: null,
}]

/** One thing broken per run, to drive each refusal separately. */
type Mode = 'ok' | 'bad-tarball' | 'bad-signature' | 'unsigned' | 'wrong-keyid'

let tmpDir: string
let server: http.Server
let registry: string
let mode: Mode = 'ok'
let setupLog: string

// The fake executable the mock serves is a `#!/bin/sh` script, so the flow that
// runs it is POSIX-only. The verification it exercises is platform-independent.
describe('installPnpm', { skip: process.platform === 'win32' }, () => {
  before(async () => {
    tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'get-pnpm-test-'))
    setupLog = path.join(tmpDir, 'setup.log')
    const tarballs = {
      // The wrapper carries `dist/`; the platform package carries the executable.
      pnpm: packTarball('wrapper', { 'dist/worker.js': 'export {}\n' }),
      platform: packTarball('platform', {
        pnpm: `#!/bin/sh\necho "$@" > "${setupLog}"\nls "$(dirname "$0")/dist" >> "${setupLog}"\n`,
      }),
    }

    server = http.createServer((req, res) => {
      const url = decodeURIComponent(req.url!)
      const json = (body: unknown): void => {
        res.writeHead(200, { 'content-type': 'application/json' })
        res.end(JSON.stringify(body))
      }

      if (url === '/pnpm') {
        json({ 'dist-tags': { latest: VERSION }, versions: { [VERSION]: {} } })
        return
      }
      if (url.endsWith(`/${VERSION}`)) {
        const kind = url === `/pnpm/${VERSION}` ? 'pnpm' : 'platform'
        const name = url.slice(1, url.lastIndexOf('/'))
        const bytes = fs.readFileSync(tarballs[kind])
        const integrity = `sha512-${createHash('sha512').update(bytes).digest('base64')}`
        // Signing a different checksum than the one served is what a tampered
        // checksum looks like: the bytes and the metadata agree, the signature
        // does not cover them.
        const signed = mode === 'bad-signature' ? `sha512-${'A'.repeat(86)}==` : integrity
        json({
          dist: {
            tarball: `${registry}${kind}.tgz`,
            integrity,
            signatures: mode === 'unsigned'
              ? []
              : [{
                keyid: mode === 'wrong-keyid' ? 'SHA256:not-pinned' : KEYS[0]!.keyid,
                sig: createSign('SHA256').update(`${name}@${VERSION}:${signed}`).sign(privateKey, 'base64'),
              }],
          },
        })
        return
      }
      if (url === '/pnpm.tgz' || url === '/platform.tgz') {
        const bytes = fs.readFileSync(tarballs[url === '/pnpm.tgz' ? 'pnpm' : 'platform'])
        res.writeHead(200, { 'content-type': 'application/octet-stream' })
        res.end(mode === 'bad-tarball' ? Buffer.concat([bytes, Buffer.from('tampered')]) : bytes)
        return
      }
      res.writeHead(404)
      res.end()
    })
    await new Promise<void>((resolve) => { server.listen(0, '127.0.0.1', resolve) })
    registry = `http://127.0.0.1:${(server.address() as { port: number }).port}/`
  })

  after(async () => {
    await new Promise<void>((resolve) => { server.close(() => { resolve() }) })
    fs.rmSync(tmpDir, { recursive: true, force: true })
  })

  const install = async (): Promise<number> => installPnpm({ versionSpec: 'latest', registry, keys: KEYS })

  test('runs setup on an executable placed next to the dist it ships with', async () => {
    mode = 'ok'
    assert.equal(await install(), 0)
    assert.equal(fs.readFileSync(setupLog, 'utf8'), 'setup --force\nworker.js\n')
  })

  test('leaves no temporary directory behind', async () => {
    mode = 'ok'
    const before = leftoverTmpDirs()
    await install()
    assert.deepEqual(leftoverTmpDirs(), before)
  })

  test('refuses a tarball that does not match its checksum', async () => {
    mode = 'bad-tarball'
    await assert.rejects(install, /does not match the checksum/)
  })

  test('refuses a checksum the signature does not cover', async () => {
    mode = 'bad-signature'
    await assert.rejects(install, /is not valid/)
  })

  test('refuses an unsigned package', async () => {
    mode = 'unsigned'
    await assert.rejects(install, /carries no npm registry signature/)
  })

  test('refuses a package signed with a key that is not pinned', async () => {
    mode = 'wrong-keyid'
    await assert.rejects(install, /unexpected npm key/)
  })
})

function leftoverTmpDirs (): string[] {
  return fs.readdirSync(os.tmpdir()).filter((entry) => entry.startsWith('pnpm-install-'))
}

function packTarball (name: string, files: Record<string, string>): string {
  const contentDir = path.join(tmpDir, name, 'package')
  for (const [filePath, content] of Object.entries(files)) {
    const dest = path.join(contentDir, filePath)
    fs.mkdirSync(path.dirname(dest), { recursive: true })
    fs.writeFileSync(dest, content, { mode: 0o755 })
  }
  const tarball = path.join(tmpDir, `${name}.tgz`)
  const { status, stderr } = spawnSync('tar', ['-czf', tarball, '-C', path.join(tmpDir, name), 'package'], { encoding: 'utf8' })
  if (status !== 0) throw new Error(`could not create the ${name} fixture tarball: ${stderr}`)
  return tarball
}
