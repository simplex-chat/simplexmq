# Simplex.Messaging.Transport.HTTP2

> Bridges TLS transport to HTTP/2 configuration, buffer management, and body reading.

**Source**: [`Transport/HTTP2.hs`](../../../../../src/Simplex/Messaging/Transport/HTTP2.hs)

## allocHTTP2Config — manual buffer allocation

`allocHTTP2Config` uses `mallocBytes` to allocate a write buffer (`Ptr Word8`) for the `http2` package's `Config`. The config bridges TLS to HTTP/2 by passing `cPut c` and `cGet c` from the `Transport` typeclass into the HTTP/2 config's `confSendAll` and `confReadN`.

## http2TLSParams

`http2TLSParams` uses `ciphersuite_strong_det` (from `Network.TLS.Extra`), distinct from the `ciphersuite_strong` used in `defaultSupportedParamsHTTPS`. This is the default `suportedTLSParams` in the HTTP/2 client configuration.
