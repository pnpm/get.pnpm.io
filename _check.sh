set -e
grep v6.js SHASUMS256.txt | sha256sum -c -
grep v6.6.js SHASUMS256.txt | sha256sum -c -
grep v6.7.js SHASUMS256.txt | sha256sum -c -
grep v6.14.js SHASUMS256.txt | sha256sum -c -
grep v6.16.js SHASUMS256.txt | sha256sum -c -
grep v6.32.js SHASUMS256.txt | sha256sum -c -
grep install.sh SHASUMS256.txt | sha256sum -c -
grep install.ps1 SHASUMS256.txt | sha256sum -c -
curl https://keybase.io/pnpm/pgp_keys.asc | gpg --import
gpg --verify SHASUMS256.txt.sig SHASUMS256.txt
