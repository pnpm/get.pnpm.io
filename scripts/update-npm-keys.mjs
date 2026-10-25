#!/usr/bin/env node
// Keeps the npm registry signing key that install.sh and install.ps1 pin in
// sync with pnpm/pnpm's .config/npm-signing-keys.json, the one list that pnpm,
// get-pnpm, and these installers share. pnpm/pnpm refreshes it from
// https://registry.npmjs.org/-/npm/v1/keys.
//
//   node scripts/update-npm-keys.mjs            # check, non-zero on drift
//   node scripts/update-npm-keys.mjs --update   # rewrite the pinned key
//
// The installers pin the current key, the one without an expiry. A key the
// list marks withdrawn is never used: a signature carries no trusted
// timestamp, so one made before a withdrawal cannot be told apart from one
// forged after it, and these installers only ever fetch current releases.
import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const KEYS_URL = 'https://raw.githubusercontent.com/pnpm/pnpm/main/.config/npm-signing-keys.json'
const ROOT = path.join(path.dirname(fileURLToPath(import.meta.url)), '..')

const SH_FILE = path.join(ROOT, 'install.sh')
const PS_FILE = path.join(ROOT, 'install.ps1')

const update = process.argv.includes('--update')
const keys = (await fetchKeys()).filter((key) => key.withdrawn !== true)
const current = keys.find((key) => key.expires == null) ?? keys[0]
if (!current) throw new Error(`No usable keys in ${KEYS_URL}`)

const changes = [
  { file: SH_FILE, next: replaceShellKey(fs.readFileSync(SH_FILE, 'utf8'), current) },
  { file: PS_FILE, next: replacePowerShellKey(fs.readFileSync(PS_FILE, 'utf8'), current) },
].filter(({ file, next }) => fs.readFileSync(file, 'utf8') !== next)

if (!update) {
  if (changes.length === 0) {
    console.log(`✓ The pinned npm signing key is ${current.keyid}, as pnpm/pnpm lists it.`)
    process.exit(0)
  }
  console.error('✗ The pinned npm signing key is out of date:')
  for (const { file } of changes) console.error(`  - ${path.relative(ROOT, file)}`)
  console.error('\nRun: node scripts/update-npm-keys.mjs --update')
  process.exit(1)
}

for (const { file, next } of changes) {
  fs.writeFileSync(file, next)
  console.log(`updated ${path.relative(ROOT, file)}`)
}
console.log(changes.length === 0 ? '✓ Already current.' : `✓ Updated ${changes.length} file(s).`)

async function fetchKeys () {
  const res = await fetch(KEYS_URL)
  if (!res.ok) throw new Error(`Failed to fetch ${KEYS_URL}: ${res.status}`)
  const keys = await res.json()
  if (!Array.isArray(keys)) throw new Error(`Unexpected content in ${KEYS_URL}`)
  return keys
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
