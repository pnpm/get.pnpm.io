A private CA and a certificate it issued for `127.0.0.1` and `localhost`,
valid for 100 years. The CA key was discarded. To make a new pair:

```sh
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
  -days 36500 -subj '/CN=get-pnpm-test-ca' -keyout ca.key -out ca.pem
openssl req -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
  -subj '/CN=localhost' -keyout server.key -out server.csr
openssl x509 -req -in server.csr -CA ca.pem -CAkey ca.key -CAcreateserial \
  -days 36500 -out server.crt -extfile <(printf '%s\n' \
  'subjectAltName=DNS:localhost,IP:127.0.0.1' 'basicConstraints=CA:FALSE' \
  'keyUsage=digitalSignature' 'extendedKeyUsage=serverAuth')
rm ca.key server.csr ca.srl
```
