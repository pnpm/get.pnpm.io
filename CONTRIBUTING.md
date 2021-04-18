Creating a new SHASUM file

```
sha256sum v6.js > SHASUMS256.txt
```

Signing:

```
gpg --detach-sign SHASUMS256.txt
```
