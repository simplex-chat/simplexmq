To generate fixtures:

(keep these instructions and *openssl_ca.conf* and *openssl_server.conf* files consistent with certificate generation on server)

```sh
# CA certificate (identity/offline)
openssl genpkey -algorithm ED448 -out ca.key
openssl req -new -x509 -days 999999 -config openssl_ca.conf -extensions v3 -key ca.key -out ca.crt

# Server certificate (online)
openssl genpkey -algorithm ED448 -out server.key
openssl req -new -config openssl_server.conf -reqexts v3 -key server.key -out server.csr
openssl x509 -req -days 999999 -extfile openssl_server.conf -extensions v3 -in server.csr -CA ca.crt -CAkey ca.key -CAcreateserial -out server.crt

# Web certificate (RSA 4096, signed by web_ca, followed by web_ca.crt in the same file)
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:4096 -out web2.key
openssl req -new -subj "/CN=localhost" -key web2.key -out web2.csr
printf 'subjectAltName = DNS:localhost\nbasicConstraints = CA:FALSE\nkeyUsage = digitalSignature, nonRepudiation, keyAgreement\nextendedKeyUsage = serverAuth\nsubjectKeyIdentifier = hash\nauthorityKeyIdentifier = keyid\n' > web.ext
openssl x509 -req -days 999999 -extfile web.ext -in web2.csr -CA web_ca.crt -CAkey web_ca.key -set_serial 0x$(openssl rand -hex 16) -out web2.crt
cat web_ca.crt >> web2.crt

# Web certificate with a key smp-server does not accept: the same commands with web_rsa2048 for web2 and rsa_keygen_bits:2048

# Web certificate with an ECDSA P-256 key: the same commands with web_ecdsa for web2 and this key
openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out web_ecdsa.key

# A second ECDSA P-256 key, without a certificate
openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out web_ecdsa2.key

# Web certificate with a DSA key: the same commands with web_dsa for web2 and this key, without appending web_ca.crt
openssl genpkey -genparam -algorithm DSA -pkeyopt dsa_paramgen_bits:2048 -out dsa.param
openssl genpkey -paramfile dsa.param -out web_dsa.key

# To pretty-print
openssl x509 -in ca.crt -text -noout
openssl req -in server.csr -text -noout
openssl x509 -in server.crt -text -noout
```

To compute fingerprint for tests:

```haskell
stack ghci
> import Data.X509.Validation (Fingerprint (..))
> Fingerprint fp <- loadFingerprint "tests/fixtures/ca.crt"
> strEncode fp
```
