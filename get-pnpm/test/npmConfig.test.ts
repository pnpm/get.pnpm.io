import assert from 'node:assert/strict'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { afterEach, test } from 'node:test'

import { registryConfigFromEnv } from '../lib/npmConfig.js'

const tmpDirs: string[] = []

afterEach(() => {
  for (const dir of tmpDirs.splice(0)) {
    fs.rmSync(dir, { recursive: true, force: true })
  }
})

test('reads a registry-scoped auth token from npm config environment variables', () => {
  const config = registryConfigFromEnv({
    env: {
      NPM_CONFIG_REGISTRY: 'https://registry.example.test/npm',
      'NPM_CONFIG_//registry.example.test/npm/:_authToken': 'env-token',
    },
  })

  assert.deepEqual(config, {
    registry: 'https://registry.example.test/npm/',
    authPath: '/npm/',
    headers: { authorization: 'Bearer env-token' },
  })
})

test('converts credentials in the configured registry URL to Basic auth', () => {
  const config = registryConfigFromEnv({
    env: {
      npm_config_registry: 'https://user:p%40ss@registry.example.test/npm',
    },
  })

  assert.deepEqual(config, {
    registry: 'https://registry.example.test/npm/',
    authPath: '/npm/',
    headers: {
      authorization: `Basic ${Buffer.from('user:p@ss').toString('base64')}`,
    },
  })
})

test('reads a registry-scoped auth token from the user npmrc', () => {
  const root = tempDir()
  const home = path.join(root, 'home')
  fs.mkdirSync(home)
  fs.writeFileSync(path.join(home, '.npmrc'), '//registry.example.test/:_authToken=user-token\n')

  const config = registryConfigFromEnv({
    cwd: path.join(root, 'project-without-npmrc'),
    env: { npm_config_registry: 'https://registry.example.test/' },
    homeDir: home,
  })

  assert.equal(config.headers?.authorization, 'Bearer user-token')
})

test('reads a registry-scoped auth token from the global npmrc', () => {
  const root = tempDir()
  const globalConfig = path.join(root, 'global.npmrc')
  fs.writeFileSync(globalConfig, '//registry.example.test/:_authToken=global-token\n')

  const config = registryConfigFromEnv({
    cwd: path.join(root, 'project-without-npmrc'),
    env: {
      npm_config_registry: 'https://registry.example.test/',
      npm_config_globalconfig: globalConfig,
    },
    homeDir: path.join(root, 'home-without-npmrc'),
  })

  assert.equal(config.headers?.authorization, 'Bearer global-token')
})

test('prefers project npmrc over user and global npmrc', () => {
  const root = tempDir()
  const home = path.join(root, 'home')
  const project = path.join(root, 'project')
  const cwd = path.join(project, 'subdir')
  const globalConfig = path.join(root, 'global.npmrc')
  fs.mkdirSync(home)
  fs.mkdirSync(cwd, { recursive: true })
  fs.writeFileSync(globalConfig, '//registry.example.test/:_authToken=global-token\n')
  fs.writeFileSync(path.join(home, '.npmrc'), '//registry.example.test/:_authToken=user-token\n')
  fs.writeFileSync(path.join(project, '.npmrc'), '//registry.example.test/:_authToken=project-token\n')

  const config = registryConfigFromEnv({
    cwd,
    env: {
      npm_config_registry: 'https://registry.example.test/',
      npm_config_globalconfig: globalConfig,
      npm_config_local_prefix: project,
    },
    homeDir: home,
  })

  assert.equal(config.headers?.authorization, 'Bearer project-token')
})

test('uses the most specific registry path token and expands environment variables', () => {
  const root = tempDir()
  fs.writeFileSync(path.join(root, '.npmrc'), [
    '//registry.example.test/:_authToken=root-token',
    '//registry.example.test/npm/:_authToken=${PRIVATE_TOKEN}',
    '',
  ].join('\n'))

  const config = registryConfigFromEnv({
    cwd: root,
    env: {
      npm_config_registry: 'https://registry.example.test/npm/private',
      PRIVATE_TOKEN: 'scoped-token',
    },
    homeDir: path.join(root, 'missing-home'),
  })

  assert.deepEqual(config, {
    registry: 'https://registry.example.test/npm/private/',
    authPath: '/npm/',
    headers: { authorization: 'Bearer scoped-token' },
  })
})

test('normalizes default ports using the configured registry protocol', () => {
  const config = registryConfigFromEnv({
    env: {
      npm_config_registry: 'http://registry.example.test:80/npm/',
      'npm_config_//registry.example.test:80/npm/:_authToken': 'http-token',
    },
  })

  assert.deepEqual(config, {
    registry: 'http://registry.example.test/npm/',
    authPath: '/npm/',
    headers: { authorization: 'Bearer http-token' },
  })
})

test('prefers a more specific token across npmrc precedence layers', () => {
  const root = tempDir()
  const project = path.join(root, 'project')
  const cwd = path.join(project, 'src')
  const home = path.join(root, 'home')
  fs.mkdirSync(cwd, { recursive: true })
  fs.mkdirSync(home)
  fs.writeFileSync(path.join(project, 'package.json'), '{}\n')
  fs.writeFileSync(path.join(project, '.npmrc'), '//registry.example.test/:_authToken=project-wide\n')
  fs.writeFileSync(path.join(home, '.npmrc'), '//registry.example.test/npm/:_authToken=user-scoped\n')

  const config = registryConfigFromEnv({
    cwd,
    env: { npm_config_registry: 'https://registry.example.test/npm/private/' },
    homeDir: home,
  })

  assert.equal(config.headers?.authorization, 'Bearer user-scoped')
  assert.equal(config.authPath, '/npm/')
})

test('prefers a cwd npmrc before the discovered package-root npmrc at the same scope', () => {
  const root = tempDir()
  const project = path.join(root, 'project')
  const cwd = path.join(project, 'tools')
  fs.mkdirSync(cwd, { recursive: true })
  fs.writeFileSync(path.join(project, 'package.json'), '{}\n')
  fs.writeFileSync(path.join(project, '.npmrc'), '//registry.example.test/:_authToken=root-token\n')
  fs.writeFileSync(path.join(cwd, '.npmrc'), '//registry.example.test/:_authToken=cwd-token\n')

  const config = registryConfigFromEnv({
    cwd,
    env: { npm_config_registry: 'https://registry.example.test/' },
    homeDir: path.join(root, 'missing-home'),
  })

  assert.equal(config.headers?.authorization, 'Bearer cwd-token')
})

test('finds the project npmrc from a project subdirectory', () => {
  const root = tempDir()
  const project = path.join(root, 'project')
  const cwd = path.join(project, 'src', 'nested')
  fs.mkdirSync(cwd, { recursive: true })
  fs.writeFileSync(path.join(project, 'package.json'), '{}\n')
  fs.writeFileSync(path.join(project, '.npmrc'), '//registry.example.test/:_authToken=project-token\n')

  const config = registryConfigFromEnv({
    cwd,
    env: { npm_config_registry: 'https://registry.example.test/' },
    homeDir: path.join(root, 'missing-home'),
  })

  assert.equal(config.headers?.authorization, 'Bearer project-token')
})

test('ignores an unreadable default npmrc candidate', () => {
  const root = tempDir()
  fs.mkdirSync(path.join(root, '.npmrc'))

  const config = registryConfigFromEnv({
    cwd: path.join(root, 'project'),
    env: { npm_config_registry: 'https://registry.example.test/' },
    homeDir: root,
  })

  assert.deepEqual(config, { registry: 'https://registry.example.test/' })
})

test('reports an unreadable explicitly configured npmrc', () => {
  const root = tempDir()

  assert.throws(() => registryConfigFromEnv({
    cwd: root,
    env: {
      npm_config_registry: 'https://registry.example.test/',
      npm_config_userconfig: root,
    },
    homeDir: root,
  }))
})

test('does not use a token scoped to another registry', () => {
  const root = tempDir()
  fs.writeFileSync(path.join(root, '.npmrc'), '//other.example.test/:_authToken=wrong-token\n')

  const config = registryConfigFromEnv({
    cwd: root,
    env: {
      npm_config_registry: 'https://registry.example.test/',
    },
    homeDir: path.join(root, 'missing-home'),
  })

  assert.deepEqual(config, { registry: 'https://registry.example.test/' })
})

function tempDir (): string {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'get-pnpm-config-'))
  tmpDirs.push(dir)
  return dir
}
