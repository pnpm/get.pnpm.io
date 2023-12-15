set -e
rm -f SHASUMS256.txt SHASUMS256.txt.sig
{
  shasum -a 256 v6.js;
  shasum -a 256 v6.6.js;
  shasum -a 256 v6.7.js;
  shasum -a 256 v6.14.js;
  shasum -a 256 v6.16.js;
  shasum -a 256 v6.32.js;
  shasum -a 256 install.sh;
  shasum -a 256 install.ps1;
} >> SHASUMS256.txt
gpg --local-user pnpm --detach-sign SHASUMS256.txt

