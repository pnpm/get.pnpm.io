import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'

import { DEFAULT_REGISTRY, normalizeRegistry, type RequestHeaders } from './registry.js'

interface RegistryConfigOptions {
  cwd?: string
  env?: NodeJS.ProcessEnv
  execPath?: string
  homeDir?: string
  platform?: NodeJS.Platform
}

interface RegistryToken {
  pathname: string
  token: string
}

interface NpmrcCandidate {
  ignoreUnreadable: boolean
  path: string
}

export interface RegistryConfig {
  authPath?: string
  headers?: RequestHeaders
  registry: string
}

export function registryConfigFromEnv (opts: RegistryConfigOptions = {}): RegistryConfig {
  const env = opts.env ?? process.env
  const rawRegistry = env.npm_config_registry ?? env.NPM_CONFIG_REGISTRY ?? DEFAULT_REGISTRY
  const embedded = registryAndEmbeddedAuth(rawRegistry)
  if (embedded.headers != null) return embedded

  const registry = embedded.registry
  const token = mostSpecificToken([
    registryTokenFromEnv(registry, env),
    ...projectNpmrcs(opts.cwd ?? process.cwd(), env)
      .map((candidate) => registryTokenFromNpmrc(registry, candidate, env)),
    registryTokenFromNpmrc(registry, userNpmrc(opts, env), env),
    registryTokenFromNpmrc(registry, globalNpmrc(opts, env), env),
  ])

  return token == null
    ? { registry }
    : {
        registry,
        authPath: token.pathname,
        headers: { authorization: `Bearer ${token.token}` },
      }
}

function registryAndEmbeddedAuth (rawRegistry: string): RegistryConfig {
  const url = new URL(normalizeRegistry(rawRegistry))
  if (!url.username && !url.password) return { registry: url.href }

  const username = decodeURIComponent(url.username)
  const password = decodeURIComponent(url.password)
  url.username = ''
  url.password = ''
  return {
    registry: url.href,
    authPath: normalizedPath(url.pathname),
    headers: {
      authorization: `Basic ${Buffer.from(`${username}:${password}`).toString('base64')}`,
    },
  }
}

function registryTokenFromEnv (registry: string, env: NodeJS.ProcessEnv): RegistryToken | undefined {
  const entries: Array<[string, string]> = []
  for (const [name, value] of Object.entries(env)) {
    if (value == null || !name.toLowerCase().startsWith('npm_config_')) continue
    entries.push([name.slice('npm_config_'.length), value])
  }
  return tokenForRegistry(registry, entries)
}

function registryTokenFromNpmrc (
  registry: string,
  npmrc: NpmrcCandidate,
  env: NodeJS.ProcessEnv
): RegistryToken | undefined {
  let text: string
  try {
    text = fs.readFileSync(npmrc.path, 'utf8')
  } catch (err) {
    if (isErrno(err, 'ENOENT')) return undefined
    if (npmrc.ignoreUnreadable && isUnreadableNpmrcError(err)) return undefined
    throw err
  }

  const entries: Array<[string, string]> = []
  for (const rawLine of text.split(/\r?\n/)) {
    const line = rawLine.trim()
    if (!line || line.startsWith('#') || line.startsWith(';')) continue
    const separator = line.indexOf('=')
    if (separator === -1) continue
    const key = line.slice(0, separator).trim()
    const rawValue = stripQuotes(line.slice(separator + 1).trim())
    const value = expandEnv(rawValue, env)
    if (value != null) entries.push([key, value])
  }
  return tokenForRegistry(registry, entries)
}

function tokenForRegistry (registry: string, entries: Array<[string, string]>): RegistryToken | undefined {
  const registryUrl = new URL(registry)
  let best: { pathname: string, position: number, token: string } | undefined

  entries.forEach(([key, token], position) => {
    if (token === '') return
    const scope = authTokenScope(key, registryUrl.protocol)
    if (scope == null) return
    if (scope.host !== registryUrl.host.toLowerCase()) return
    if (!registryUrl.pathname.startsWith(scope.pathname)) return

    if (
      best == null ||
      scope.pathname.length > best.pathname.length ||
      (scope.pathname.length === best.pathname.length && position > best.position)
    ) {
      best = { pathname: scope.pathname, position, token }
    }
  })

  return best == null ? undefined : { pathname: best.pathname, token: best.token }
}

function mostSpecificToken (candidates: Array<RegistryToken | undefined>): RegistryToken | undefined {
  let best: RegistryToken | undefined
  for (const candidate of candidates) {
    if (candidate == null) continue
    if (best == null || candidate.pathname.length > best.pathname.length) best = candidate
  }
  return best
}

function authTokenScope (key: string, protocol: string): { host: string, pathname: string } | undefined {
  const suffix = ':_authtoken'
  const lower = key.toLowerCase()
  if (!lower.endsWith(suffix)) return undefined
  const rawScope = key.slice(0, -suffix.length)
  if (!rawScope.startsWith('//')) return undefined

  try {
    const url = new URL(`${protocol}${rawScope}`)
    return {
      host: url.host.toLowerCase(),
      pathname: normalizedPath(url.pathname),
    }
  } catch {
    return undefined
  }
}

function projectNpmrcs (cwd: string, env: NodeJS.ProcessEnv): NpmrcCandidate[] {
  const configured = env.npm_config_local_prefix ?? env.NPM_CONFIG_LOCAL_PREFIX
  if (configured != null) {
    return [{ path: path.join(configured, '.npmrc'), ignoreUnreadable: false }]
  }

  const current = path.resolve(cwd)
  const root = findProjectRoot(current)
  const paths = [path.join(current, '.npmrc')]
  if (root !== current) paths.push(path.join(root, '.npmrc'))
  return paths.map((npmrcPath) => ({ path: npmrcPath, ignoreUnreadable: true }))
}

function findProjectRoot (cwd: string): string {
  const start = path.resolve(cwd)
  let current = start
  while (true) {
    if (fs.existsSync(path.join(current, 'package.json'))) return current
    const parent = path.dirname(current)
    if (parent === current) return start
    current = parent
  }
}

function userNpmrc (opts: RegistryConfigOptions, env: NodeJS.ProcessEnv): NpmrcCandidate {
  const configured = env.npm_config_userconfig ?? env.NPM_CONFIG_USERCONFIG
  return configured != null
    ? { path: configured, ignoreUnreadable: false }
    : { path: path.join(npmHomeDir(opts, env), '.npmrc'), ignoreUnreadable: true }
}

function globalNpmrc (opts: RegistryConfigOptions, env: NodeJS.ProcessEnv): NpmrcCandidate {
  const configured = env.npm_config_globalconfig ?? env.NPM_CONFIG_GLOBALCONFIG
  if (configured != null) return { path: configured, ignoreUnreadable: false }

  const platform = opts.platform ?? process.platform
  const homeDir = npmHomeDir(opts, env)
  const prefix = env.npm_config_prefix ??
    env.NPM_CONFIG_PREFIX ??
    (platform === 'win32'
      ? path.join(env.APPDATA ?? path.join(homeDir, 'AppData', 'Roaming'), 'npm')
      : path.dirname(path.dirname(opts.execPath ?? process.execPath)))
  return { path: path.join(prefix, 'etc', 'npmrc'), ignoreUnreadable: true }
}

function npmHomeDir (opts: RegistryConfigOptions, env: NodeJS.ProcessEnv): string {
  if (opts.homeDir != null) return opts.homeDir
  const platform = opts.platform ?? process.platform
  if (platform === 'win32') return env.USERPROFILE ?? env.HOME ?? os.homedir()
  return env.HOME ?? os.homedir()
}

function normalizedPath (pathname: string): string {
  return pathname.endsWith('/') ? pathname : `${pathname}/`
}

function stripQuotes (value: string): string {
  if (value.length < 2) return value
  const first = value[0]
  const last = value[value.length - 1]
  return (first === last && (first === '"' || first === "'")) ? value.slice(1, -1) : value
}

function expandEnv (value: string, env: NodeJS.ProcessEnv): string | undefined {
  let missing = false
  const expanded = value.replace(/\$\{([^}]+)\}/g, (_match, name: string) => {
    const resolved = env[name]
    if (resolved == null) {
      missing = true
      return ''
    }
    return resolved
  })
  return missing ? undefined : expanded
}

function isUnreadableNpmrcError (err: unknown): boolean {
  return ['EACCES', 'EISDIR', 'EPERM'].some((code) => isErrno(err, code))
}

function isErrno (err: unknown, code: string): err is NodeJS.ErrnoException {
  return err instanceof Error && 'code' in err && err.code === code
}
