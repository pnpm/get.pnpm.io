set -e
grep v6.js SHASUMS256.txt | sha256sum -c -
grep v6.6.js SHASUMS256.txt | sha256sum -c -
grep v6.7.js SHASUMS256.txt | sha256sum -c -
grep v6.14.js SHASUMS256.txt | sha256sum -c -
grep v6.16.js SHASUMS256.txt | sha256sum -c -
grep v6.32.js SHASUMS256.txt | sha256sum -c -
grep install.sh SHASUMS256.txt | sha256sum -c -
grep install.ps1 SHASUMS256.txt | sha256sum -c -
curl -fsSL https://keys.openpgp.org/vks/v1/by-fingerprint/4D20AD76D7BE567214F3F8EE4EABAE7510A044FA | gpg --import
gpg --verify SHASUMS256.txt.sig SHASUMS256.txt
