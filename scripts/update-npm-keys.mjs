#!/usr/bin/env node
// Keeps the pinned npm registry signing keys in sync with
// https://registry.npmjs.org/-/npm/v1/keys.
//
//   node scripts/update-npm-keys.mjs            # check, non-zero on drift
//   node scripts/update-npm-keys.mjs --update   # rewrite the pinned keys
//
// Three installers pin these: install.sh, install.ps1 and the get-pnpm package.
// They are updated together, because a rotation that reaches only some of them
// leaves the rest refusing to install anything.
//
// The pinned set is exactly what npm advertises. A key npm has withdrawn is not
// kept for verifying older packages: a signature carries no trusted timestamp,
// so a signature made before a withdrawal cannot be told apart from one forged
// after it. These installers only ever fetch current releases, so following
// npm's set costs nothing and keeps withdrawal meaning withdrawal.
//
// The shell and PowerShell installers carry only the current key; the package
// carries every key npm lists, expiry included, and rejects an expired one.
import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const KEYS_URL = 'https://registry.npmjs.org/-/npm/v1/keys'
const ROOT = path.join(path.dirname(fileURLToPath(import.meta.url)), '..')
const KEY_FIELDS = ['expires', 'keyid', 'keytype', 'scheme', 'key']

const JS_KEYS_FILE = path.join(ROOT, 'get-pnpm', 'src', 'npmSigningKeys.ts')
const SH_FILE = path.join(ROOT, 'install.sh')
const PS_FILE = path.join(ROOT, 'install.ps1')

const update = process.argv.includes('--update')
const npmKeys = await fetchNpmKeys()
const current = npmKeys.find((key) => key.expires == null) ?? npmKeys[0]
if (!current) throw new Error(`No keys in ${KEYS_URL}`)

const merged = [...npmKeys].sort((a, b) => a.keyid.localeCompare(b.keyid))

const changes = [
  { file: JS_KEYS_FILE, next: renderKeysModule(merged) },
  { file: SH_FILE, next: replaceShellKey(fs.readFileSync(SH_FILE, 'utf8'), current) },
  { file: PS_FILE, next: replacePowerShellKey(fs.readFileSync(PS_FILE, 'utf8'), current) },
].filter(({ file, next }) => fs.readFileSync(file, 'utf8') !== next)

if (!update) {
  if (changes.length === 0) {
    console.log(`✓ Pinned npm signing keys are up to date (${merged.length} key(s)).`)
    process.exit(0)
  }
  console.error('✗ Pinned npm signing keys are out of date:')
  for (const { file } of changes) console.error(`  - ${path.relative(ROOT, file)}`)
  console.error('\nRun: node scripts/update-npm-keys.mjs --update')
  process.exit(1)
}

for (const { file, next } of changes) {
  fs.writeFileSync(file, next)
  console.log(`updated ${path.relative(ROOT, file)}`)
}
console.log(changes.length === 0 ? '✓ Already current.' : `✓ Updated ${changes.length} file(s).`)

async function fetchNpmKeys () {
  const res = await fetch(KEYS_URL)
  if (!res.ok) throw new Error(`Failed to fetch ${KEYS_URL}: ${res.status}`)
  const body = await res.json()
  if (!Array.isArray(body?.keys)) throw new Error(`Unexpected response from ${KEYS_URL}`)
  return body.keys.map((key) => Object.fromEntries(KEY_FIELDS.map((f) => [f, key[f] ?? null])))
}

function renderKeysModule (keys) {
  return `/* eslint-disable */
// GENERATED — npm's public registry signing keys, mirrored from
// ${KEYS_URL}
//
// Refresh with: node scripts/update-npm-keys.mjs --update
// A scheduled workflow runs the check, so a rotation arrives as a pull request
// rather than as a failed install.
export const NPM_SIGNING_KEYS = ${JSON.stringify(keys, KEY_FIELDS, 2)} as const satisfies ReadonlyArray<{
  expires: string | null
  keyid: string
  keytype: string
  scheme: string
  key: string
}>
`
}

function replaceShellKey (source, key) {
  return replaceOnce(replaceOnce(source, /(NPM_SIGNING_KEY_ID=')[^']*(')/, key.keyid, SH_FILE),
    /(NPM_SIGNING_KEY=')[^']*(')/, key.key, SH_FILE)
}

function replacePowerShellKey (source, key) {
  return replaceOnce(replaceOnce(source, /(\$NpmSigningKeyId = ')[^']*(')/, key.keyid, PS_FILE),
    /(\$NpmSigningKey = ')[^']*(')/, key.key, PS_FILE)
}

// A pattern that stops matching means the installer was restructured and this
// script would otherwise silently leave a stale key behind.
function replaceOnce (source, pattern, value, file) {
  if (!pattern.test(source)) {
    throw new Error(`Pattern ${pattern} not found in ${path.relative(ROOT, file)}`)
  }
  return source.replace(pattern, `$1${value}$2`)
}
