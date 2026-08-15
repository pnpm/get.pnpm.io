import assert from 'node:assert/strict'
import { spawnSync } from 'node:child_process'
import { createHash, createSign, generateKeyPairSync } from 'node:crypto'
import fs from 'node:fs'
import http from 'node:http'
import os from 'node:os'
import path from 'node:path'
import zlib from 'node:zlib'
import { after, before, beforeEach, describe, test } from 'node:test'

import { downloadPnpmExecutable, platformPackageName } from '../lib/index.js'
import type { SigningKey } from '../lib/verifySignature.js'

const VERSION = '99.0.0'
const EXECUTABLE = process.platform === 'win32' ? 'pnpm.exe' : 'pnpm'
const CONTENT = 'the pnpm executable, supposedly'

// The pinned key is npm's, so these tests sign with their own and pass it in.
const { privateKey, publicKey } = generateKeyPairSync('ec', { namedCurve: 'prime256v1' })
const KEYS: SigningKey[] = [{
  keyid: 'SHA256:test-key',
  key: publicKey.export({ type: 'spki', format: 'der' }).toString('base64'),
  expires: null,
}]

/** One thing broken per run, to drive each refusal separately. */
type Mode = 'ok' | 'bad-tarball' | 'bad-signature' | 'unsigned' | 'no-integrity' | 'no-executable' | 'npm-tarball-url' | 'truncated'

let tmpDir: string
let server: http.Server
let cdn: http.Server
let registry: string
let mode: Mode = 'ok'
let requests: Array<{ path: string, authorization?: string }> = []
let cdnRequests: Array<{ path: string, authorization?: string }> = []

describe('downloadPnpmExecutable', () => {
  before(async () => {
    tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'get-pnpm-exe-test-'))
    const tarballs = {
      ok: packTarball('ok', { [EXECUTABLE]: CONTENT }),
      empty: packTarball('empty', { 'README.md': 'nothing to run here\n' }),
      // Big enough to span several blocks, so cutting the tail leaves the
      // executable's declared size unmet rather than merely losing padding.
      truncated: truncate(packTarball('big', { [EXECUTABLE]: 'x'.repeat(5000) })),
    }
    const bytesFor = (mode: Mode): Buffer => {
      if (mode === 'no-executable') return fs.readFileSync(tarballs.empty)
      if (mode === 'truncated') return fs.readFileSync(tarballs.truncated)
      return fs.readFileSync(tarballs.ok)
    }
    const serveTarball = (res: http.ServerResponse): void => {
      const bytes = bytesFor(mode)
      res.writeHead(200, { 'content-type': 'application/octet-stream' })
      res.end(mode === 'bad-tarball' ? Buffer.concat([bytes, Buffer.from('tampered')]) : bytes)
    }

    cdn = http.createServer((req, res) => {
      cdnRequests.push({ path: req.url!, authorization: req.headers.authorization })
      serveTarball(res)
    })
    await listen(cdn)

    server = http.createServer((req, res) => {
      const url = decodeURIComponent(req.url!)
      requests.push({ path: url, authorization: req.headers.authorization })
      if (url.endsWith(`/${VERSION}`)) {
        // The registry may be served from a subpath, which is not part of the
        // package name the signature covers.
        const name = url.slice(1, url.lastIndexOf('/')).replace(/^npm\//, '')
        const integrity = `sha512-${createHash('sha512').update(bytesFor(mode)).digest('base64')}`
        // Signing a checksum other than the one served is what a tampered
        // checksum looks like: bytes and metadata agree, the signature does not
        // cover them.
        const signed = mode === 'bad-signature' ? `sha512-${'A'.repeat(86)}==` : integrity
        res.writeHead(200, { 'content-type': 'application/json' })
        res.end(JSON.stringify({
          dist: {
            // An npm URL is what a registry proxying npm hands back, and has to
            // be re-hosted onto the registry that answered.
            tarball: mode === 'npm-tarball-url'
              ? `https://registry.npmjs.org/${name}/-/tarball.tgz`
              : `${addressOf(cdn)}/${name}/-/tarball.tgz`,
            ...(mode === 'no-integrity' ? {} : { integrity }),
            signatures: mode === 'unsigned'
              ? []
              : [{
                keyid: KEYS[0]!.keyid,
                sig: createSign('SHA256').update(`${name}@${VERSION}:${signed}`).sign(privateKey, 'base64'),
              }],
          },
        }))
        return
      }
      serveTarball(res)
    })
    await listen(server)
    registry = `${addressOf(server)}/`
  })

  after(async () => {
    await Promise.all([close(server), close(cdn)])
    fs.rmSync(tmpDir, { recursive: true, force: true })
  })

  beforeEach(() => {
    mode = 'ok'
    requests = []
    cdnRequests = []
  })

  test('places the executable and nothing else', async () => {
    const destPath = destIn('placed')

    const { packageName } = await downloadPnpmExecutable({ version: VERSION, registry, destPath, keys: KEYS })

    assert.equal(packageName, packageNameFor())
    assert.equal(fs.readFileSync(destPath, 'utf8'), CONTENT)
    assert.deepEqual(fs.readdirSync(path.dirname(destPath)), [path.basename(destPath)])
  })

  test('marks the executable executable', { skip: process.platform === 'win32' }, async () => {
    const destPath = destIn('mode')

    await downloadPnpmExecutable({ version: VERSION, registry, destPath, keys: KEYS })

    assert.equal(fs.statSync(destPath).mode & 0o111, 0o111)
  })

  test('asks for the version it was given, without resolving dist-tags', async () => {
    await downloadPnpmExecutable({ version: VERSION, registry, destPath: destIn('exact'), keys: KEYS })

    assert.deepEqual(requests.map(({ path: asked }) => asked), [`/${packageNameFor()}/${VERSION}`])
  })

  test('sends credentials to the registry and not to the download host', async () => {
    const headers = { authorization: 'Bearer a-token' }

    await downloadPnpmExecutable({ version: VERSION, registry, destPath: destIn('auth'), headers, keys: KEYS })

    assert.equal(requests[0]!.authorization, 'Bearer a-token')
    assert.equal(cdnRequests[0]!.authorization, undefined)
  })

  test('re-hosts an npm tarball URL onto the registry that served the metadata', async () => {
    mode = 'npm-tarball-url'
    const destPath = destIn('rehosted')

    await downloadPnpmExecutable({ version: VERSION, registry, destPath, keys: KEYS })

    assert.equal(fs.readFileSync(destPath, 'utf8'), CONTENT)
    assert.equal(cdnRequests.length, 0, 'the download stayed on the registry')
  })

  test('keeps a registry subpath that does not end in a slash', async () => {
    const destPath = destIn('subpath')

    await downloadPnpmExecutable({ version: VERSION, registry: `${addressOf(server)}/npm`, destPath, keys: KEYS })

    assert.equal(fs.readFileSync(destPath, 'utf8'), CONTENT)
    assert.deepEqual(requests.map(({ path: asked }) => asked), [`/npm/${packageNameFor()}/${VERSION}`])
  })

  test('refuses an archive that ends inside the executable', async () => {
    mode = 'truncated'
    const destPath = destIn('truncated')

    await assert.rejects(download(destPath), /ends after \d+ of the 5000 bytes/)
    assert.deepEqual(fs.readdirSync(path.dirname(destPath)), [])
  })

  test('accepts an executable a concurrent call already placed', async () => {
    const destPath = destIn('raced')
    fs.writeFileSync(destPath, CONTENT)

    await downloadPnpmExecutable({ version: VERSION, registry, destPath, keys: KEYS })

    assert.equal(fs.readFileSync(destPath, 'utf8'), CONTENT)
    assert.deepEqual(fs.readdirSync(path.dirname(destPath)), [path.basename(destPath)])
  })

  // The errno differs per platform — EISDIR on Linux, EPERM on Windows — so
  // what is asserted is that the directory survives rather than how it says so.
  test('refuses a destination that is not a file', async () => {
    const destPath = destIn('directory')
    fs.mkdirSync(destPath)

    await assert.rejects(download(destPath), /rename/)
    assert.ok(fs.statSync(destPath).isDirectory(), 'the directory is left alone')
    assert.deepEqual(fs.readdirSync(path.dirname(destPath)), [path.basename(destPath)])
  })

  test('refuses a tarball that does not match its checksum', async () => {
    mode = 'bad-tarball'
    const destPath = destIn('tampered')

    await assert.rejects(download(destPath), /does not match the checksum/)
    assert.deepEqual(fs.readdirSync(path.dirname(destPath)), [])
  })

  test('refuses a checksum the signature does not cover', async () => {
    mode = 'bad-signature'
    const destPath = destIn('unsigned-checksum')

    await assert.rejects(download(destPath), /is not valid/)
    assert.deepEqual(fs.readdirSync(path.dirname(destPath)), [])
  })

  test('refuses an unsigned package', async () => {
    mode = 'unsigned'

    await assert.rejects(download(destIn('unsigned')), /carries no npm registry signature/)
  })

  test('takes an unsigned package when the caller waives the signature', async () => {
    mode = 'unsigned'
    const destPath = destIn('signature-waived')

    await downloadPnpmExecutable({ version: VERSION, registry, destPath, verifySignature: false })

    assert.equal(fs.readFileSync(destPath, 'utf8'), CONTENT)
  })

  test('still checks the checksum when the caller waives the signature', async () => {
    mode = 'bad-tarball'
    const destPath = destIn('waived-but-tampered')

    await assert.rejects(
      downloadPnpmExecutable({ version: VERSION, registry, destPath, verifySignature: false }),
      /does not match the checksum/
    )
  })

  test('refuses a package the registry published no checksum for', async () => {
    mode = 'no-integrity'

    await assert.rejects(download(destIn('no-integrity')), /published no checksum/)
  })

  test('reports a tarball that carries no executable', async () => {
    mode = 'no-executable'
    const destPath = destIn('no-executable')

    await assert.rejects(download(destPath), /contains no package\//)
    assert.deepEqual(fs.readdirSync(path.dirname(destPath)), [])
  })
})

async function download (destPath: string): Promise<unknown> {
  return downloadPnpmExecutable({ version: VERSION, registry, destPath, keys: KEYS })
}

function packageNameFor (): string {
  return platformPackageName({ major: 99, platform: process.platform, arch: process.arch, musl: false })
}

/** A destination of its own per test, so leftovers are visible. */
function destIn (name: string): string {
  const dir = path.join(tmpDir, name)
  fs.mkdirSync(dir, { recursive: true })
  return path.join(dir, EXECUTABLE)
}

/**
 * Cuts an archive off one block into the executable, so the entry declares more
 * than the archive holds. Located rather than measured from the end, because
 * tar pads an archive out to a record far longer than its content.
 */
function truncate (tarball: string): string {
  const unpacked = zlib.gunzipSync(fs.readFileSync(tarball))
  for (let offset = 0; offset + 512 <= unpacked.length; offset += 512) {
    const name = unpacked.toString('utf8', offset, offset + 100).replace(/\0.*$/s, '')
    if (name !== `package/${EXECUTABLE}`) continue
    const cut = path.join(tmpDir, 'truncated.tgz')
    fs.writeFileSync(cut, zlib.gzipSync(unpacked.subarray(0, offset + 512 + 512)))
    return cut
  }
  throw new Error(`no ${EXECUTABLE} entry to truncate in ${tarball}`)
}

function packTarball (name: string, files: Record<string, string>): string {
  const contentDir = path.join(tmpDir, name, 'package')
  for (const [filePath, content] of Object.entries(files)) {
    const dest = path.join(contentDir, filePath)
    fs.mkdirSync(path.dirname(dest), { recursive: true })
    fs.writeFileSync(dest, content)
  }
  const tarball = path.join(tmpDir, `${name}.tgz`)
  const { status, stderr } = spawnSync('tar', ['-czf', tarball, '-C', path.join(tmpDir, name), 'package'], { encoding: 'utf8' })
  if (status !== 0) throw new Error(`could not create the ${name} fixture tarball: ${stderr}`)
  return tarball
}

async function listen (target: http.Server): Promise<void> {
  await new Promise<void>((resolve) => { target.listen(0, '127.0.0.1', resolve) })
}

async function close (target: http.Server): Promise<void> {
  await new Promise<void>((resolve) => { target.close(() => { resolve() }) })
}

function addressOf (target: http.Server): string {
  return `http://127.0.0.1:${(target.address() as { port: number }).port}`
}
