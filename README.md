# Verifying files

To download `SHASUMS256.txt` using curl:

```
curl -O https://get.pnpm.io/SHASUMS256.txt
```

To check that a downloaded file matches the checksum, run it through sha256sum with a command such as:

```
grep v6.js SHASUMS256.txt | sha256sum -c -
```
