import assert from 'node:assert/strict'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { test } from 'node:test'

import { downloadPnpmExecutable, runCli } from '../lib/index.js'

for (const version of ['11.0.0', '11.20.0', '11.0.0-rc.1']) {
  test(`refuses pnpm ${version} on arm64 musl before downloading`, async (t) => {
    const platform = Object.getOwnPropertyDescriptor(process, 'platform')!
    const arch = Object.getOwnPropertyDescriptor(process, 'arch')!
    const scratch = fs.mkdtempSync(path.join(os.tmpdir(), 'get-pnpm-platform-'))
    const requests: string[] = []
    Object.defineProperty(process, 'platform', { value: 'linux' })
    Object.defineProperty(process, 'arch', { value: 'arm64' })
    t.mock.method(process.report, 'getReport', () => ({ header: {} }))
    t.mock.method(globalThis, 'fetch', async (url: string | URL) => {
      requests.push(String(url))
      if (new URL(url).pathname !== '/pnpm') throw new Error(`Unexpected package request: ${url}`)
      return new Response(JSON.stringify({ 'dist-tags': {}, versions: { [version]: {} } }))
    })
    const expectedError = (err: Error): boolean => {
      assert.match(err.message, /pnpm v11.*arm64 musl Linux/s)
      assert.ok(err.message.includes(`npm install -g pnpm@${version}`))
      assert.match(err.message, /npx get-pnpm 12/)
      return true
    }

    try {
      await assert.rejects(runCli([version]), expectedError)
      assert.equal(requests.length, 1, 'only the version metadata was requested')
      assert.equal(new URL(requests[0]!).pathname, '/pnpm')
      requests.length = 0

      const destPath = path.join(scratch, 'pnpm')
      await assert.rejects(downloadPnpmExecutable({ version, registry: 'https://registry.npmjs.org/', destPath }), expectedError)
      assert.deepEqual(requests, [], 'the executable API never contacted the registry')
      assert.equal(fs.existsSync(destPath), false)
    } finally {
      Object.defineProperty(process, 'platform', platform)
      Object.defineProperty(process, 'arch', arch)
      fs.rmSync(scratch, { recursive: true, force: true })
    }
  })
}
