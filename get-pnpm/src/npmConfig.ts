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

export interface RegistryConfig {
  headers?: RequestHeaders
  registry: string
}

export function registryConfigFromEnv (opts: RegistryConfigOptions = {}): RegistryConfig {
  const env = opts.env ?? process.env
  const rawRegistry = env.npm_config_registry ?? env.NPM_CONFIG_REGISTRY ?? DEFAULT_REGISTRY
  const embedded = registryAndEmbeddedAuth(rawRegistry)
  if (embedded.headers != null) return embedded

  const registry = embedded.registry
  const token = registryTokenFromEnv(registry, env) ??
    registryTokenFromNpmrc(registry, projectNpmrc(opts.cwd ?? process.cwd(), env), env) ??
    registryTokenFromNpmrc(registry, userNpmrc(opts, env), env) ??
    registryTokenFromNpmrc(registry, globalNpmrc(opts, env), env)

  return token == null
    ? { registry }
    : { registry, headers: { authorization: `Bearer ${token}` } }
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
    headers: {
      authorization: `Basic ${Buffer.from(`${username}:${password}`).toString('base64')}`,
    },
  }
}

function registryTokenFromEnv (registry: string, env: NodeJS.ProcessEnv): string | undefined {
  const entries: Array<[string, string]> = []
  for (const [name, value] of Object.entries(env)) {
    if (value == null || !name.toLowerCase().startsWith('npm_config_')) continue
    entries.push([name.slice('npm_config_'.length), value])
  }
  return tokenForRegistry(registry, entries)
}

function registryTokenFromNpmrc (
  registry: string,
  npmrcPath: string,
  env: NodeJS.ProcessEnv
): string | undefined {
  let text: string
  try {
    text = fs.readFileSync(npmrcPath, 'utf8')
  } catch (err) {
    if (isErrno(err, 'ENOENT')) return undefined
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

function tokenForRegistry (registry: string, entries: Array<[string, string]>): string | undefined {
  const registryUrl = new URL(registry)
  let best: { pathLength: number, position: number, token: string } | undefined

  entries.forEach(([key, token], position) => {
    if (token === '') return
    const scope = authTokenScope(key)
    if (scope == null) return
    if (scope.host !== registryUrl.host.toLowerCase()) return
    if (!registryUrl.pathname.startsWith(scope.pathname)) return

    if (
      best == null ||
      scope.pathname.length > best.pathLength ||
      (scope.pathname.length === best.pathLength && position > best.position)
    ) {
      best = { pathLength: scope.pathname.length, position, token }
    }
  })

  return best?.token
}

function authTokenScope (key: string): { host: string, pathname: string } | undefined {
  const suffix = ':_authtoken'
  const lower = key.toLowerCase()
  if (!lower.endsWith(suffix)) return undefined
  const rawScope = key.slice(0, -suffix.length)
  if (!rawScope.startsWith('//')) return undefined

  try {
    const url = new URL(`https:${rawScope}`)
    return {
      host: url.host.toLowerCase(),
      pathname: url.pathname.endsWith('/') ? url.pathname : `${url.pathname}/`,
    }
  } catch {
    return undefined
  }
}

function projectNpmrc (cwd: string, env: NodeJS.ProcessEnv): string {
  return path.join(
    env.npm_config_local_prefix ?? env.NPM_CONFIG_LOCAL_PREFIX ?? cwd,
    '.npmrc'
  )
}

function userNpmrc (opts: RegistryConfigOptions, env: NodeJS.ProcessEnv): string {
  return env.npm_config_userconfig ??
    env.NPM_CONFIG_USERCONFIG ??
    path.join(npmHomeDir(opts, env), '.npmrc')
}

function globalNpmrc (opts: RegistryConfigOptions, env: NodeJS.ProcessEnv): string {
  const configured = env.npm_config_globalconfig ?? env.NPM_CONFIG_GLOBALCONFIG
  if (configured != null) return configured

  const platform = opts.platform ?? process.platform
  const homeDir = npmHomeDir(opts, env)
  const prefix = env.npm_config_prefix ??
    env.NPM_CONFIG_PREFIX ??
    (platform === 'win32'
      ? path.join(env.APPDATA ?? path.join(homeDir, 'AppData', 'Roaming'), 'npm')
      : path.dirname(path.dirname(opts.execPath ?? process.execPath)))
  return path.join(prefix, 'etc', 'npmrc')
}

function npmHomeDir (opts: RegistryConfigOptions, env: NodeJS.ProcessEnv): string {
  if (opts.homeDir != null) return opts.homeDir
  const platform = opts.platform ?? process.platform
  if (platform === 'win32') return env.USERPROFILE ?? env.HOME ?? os.homedir()
  return env.HOME ?? os.homedir()
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

function isErrno (err: unknown, code: string): err is NodeJS.ErrnoException {
  return err instanceof Error && 'code' in err && err.code === code
}
