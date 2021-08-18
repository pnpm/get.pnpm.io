Creating a new SHASUM file

```
sha256sum v6.js > SHASUMS256.txt
```

Signing:

```
gpg --local-user pnpm --detach-sign SHASUMS256.txt
```
