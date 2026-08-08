// A registry that answers with npm's real metadata, mutated one way, so the
// installer's verification branches can be driven from a test.
//
// The signature check pins npm's public key, so no server can produce metadata
// that passes it — which is the point. This exists to make the checks fail in
// each distinct way and prove the installer refuses, not to fake a good install.
import { createServer } from 'node:http'

const UPSTREAM = 'https://registry.npmjs.org'
const mode = process.argv[2]
const port = Number(process.argv[3])

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

createServer((req, res) => {
  handle(req, res).catch((err) => {
    res.writeHead(500)
    res.end(String(err))
  })
}).listen(port, '127.0.0.1', () => {
  console.log(`mock registry (${mode}) on ${port}`)
})

async function handle (req, res) {
  const path = decodeURIComponent(req.url)

  if (path.startsWith('/tarball/')) {
    const upstream = await fetch(`${UPSTREAM}${path.slice('/tarball'.length)}`)
    const body = Buffer.from(await upstream.arrayBuffer())
    res.writeHead(200, { 'content-type': 'application/octet-stream' })
    res.end(mode === 'bad-tarball' ? Buffer.concat([body, Buffer.from('tampered')]) : body)
    return
  }

  const upstream = await fetch(`${UPSTREAM}${path}`)
  if (!upstream.ok) {
    res.writeHead(upstream.status)
    res.end()
    return
  }
  const meta = await upstream.json()
  // Point the tarball at this server so its bytes can be mutated too.
  meta.dist.tarball = `http://127.0.0.1:${port}/tarball${new URL(meta.dist.tarball).pathname}`
  res.writeHead(200, { 'content-type': 'application/json' })
  res.end(JSON.stringify(MUTATIONS[mode](meta)))
}
