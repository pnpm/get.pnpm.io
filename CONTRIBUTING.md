Creating a new SHASUM file

```
sha256sum v6.js > SHASUMS256.txt
```

Signing:

```
gpg --local-user pnpm --detach-sign SHASUMS256.txt
```

Downloading a new pnpm CLI script:

```
curl -fsSL https://unpkg.com/pnpm@latest/dist/pnpm.cjs > v6.16.js
```

Downloading a new pnpm CLI script and minifying it:

```
curl https://unpkg.com/pnpm@6.32.18/dist/pnpm.cjs | pnpm dlx esbuild --minify > v6.32.js
```

