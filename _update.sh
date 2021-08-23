rm SHASUMS256.txt SHASUMS256.txt.sig
sha256sum v6.js >> SHASUMS256.txt
sha256sum v6.6.js >> SHASUMS256.txt
sha256sum v6.7.js >> SHASUMS256.txt
sha256sum v6.14.js >> SHASUMS256.txt
sha256sum v6.14.js >> SHASUMS256.txt
sha256sum install.sh >> SHASUMS256.txt
gpg --local-user pnpm --detach-sign SHASUMS256.txt

