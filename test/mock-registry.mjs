// A registry that answers with npm's real metadata, mutated one way, so the
// installer's verification branches can be driven from a test.
//
// The signature check pins npm's public key, so no server can produce metadata
// that passes it — which is the point. This exists to make the checks fail in
// each distinct way and prove the installer refuses, not to fake a good install.
//
// Everything is fetched once at startup, from names derived here rather than
// from any request, so nothing this server sends upstream depends on what a
// client asks for.
import { createServer } from 'node:http'

const REGISTRY = 'https://registry.npmjs.org'
const WRAPPER = 'pnpm'
const PLATFORM_PACKAGE = `@pnpm/exe.${process.platform}-${process.arch}`

const [mode, portArg, version] = process.argv.slice(2)
const port = Number(portArg)

const MUTATIONS = {
  // Metadata is passed through untouched, so the signature verifies and the
  // tarball is what fails.
  'bad-tarball': (meta) => meta,
  'bad-integrity': (meta) => ({ ...meta, dist: { ...meta.dist, integrity: `sha512-${'A'.repeat(86)}==` } }),
  'no-signature': (meta) => ({ ...meta, dist: { ...meta.dist, signatures: [] } }),
  'wrong-keyid': (meta) => ({
    ...meta,
    dist: { ...meta.dist, signatures: [{ ...meta.dist.signatures[0], keyid: 'SHA256:not-the-pinned-key' }] },
  }),
  'no-integrity': (meta) => {
    const dist = { ...meta.dist }
    delete dist.integrity
    return { ...meta, dist }
  },
}

if (!MUTATIONS[mode]) {
  console.error(`unknown mode: ${mode}. Expected one of ${Object.keys(MUTATIONS).join(', ')}`)
  process.exit(2)
}
if (!/^[0-9][0-9A-Za-z.+-]*$/.test(version ?? '')) {
  console.error(`not a version: ${version}`)
  process.exit(2)
}

const packages = new Map()
for (const name of [PLATFORM_PACKAGE, WRAPPER]) {
  const meta = await (await fetch(`${REGISTRY}/${name}/${version}`)).json()
  const tarball = Buffer.from(await (await fetch(meta.dist.tarball)).arrayBuffer())
  meta.dist.tarball = `http://127.0.0.1:${port}/tarball/${encodeURIComponent(name)}`
  packages.set(name, { meta: MUTATIONS[mode](meta), tarball })
}

// install.ps1 resolves dist-tags before fetching a version, and needs to find
// the version it was asked for. Nothing here is worth breaking.
const packument = {
  'dist-tags': { latest: version, 'next-12': version },
  versions: { [version]: {} },
}

const json = (res, body) => {
  res.writeHead(200, { 'content-type': 'application/json' })
  res.end(JSON.stringify(body))
}

createServer((req, res) => {
  const path = decodeURIComponent(req.url)

  if (path === `/${WRAPPER}`) {
    json(res, packument)
    return
  }

  const tarballOf = path.startsWith('/tarball/') && packages.get(decodeURIComponent(path.slice('/tarball/'.length)))
  if (tarballOf) {
    const { tarball } = tarballOf
    res.writeHead(200, { 'content-type': 'application/octet-stream' })
    res.end(mode === 'bad-tarball' ? Buffer.concat([tarball, Buffer.from('tampered')]) : tarball)
    return
  }

  const versionDoc = packages.get(path.replace(`/${version}`, '').slice(1))
  if (versionDoc && path.endsWith(`/${version}`)) {
    json(res, versionDoc.meta)
    return
  }

  res.writeHead(404)
  res.end()
}).listen(port, '127.0.0.1', () => {
  console.log(`mock registry (${mode}) on ${port}`)
})
