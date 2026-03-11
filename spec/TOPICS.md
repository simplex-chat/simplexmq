# Topic Candidates

> Cross-cutting patterns noticed during module documentation. Each entry may become a topic doc in `spec/` after all module docs are complete.

- **Exception handling strategy**: `catchOwn`/`catchAll`/`tryAllErrors` pattern (defined in Util.hs) used across server, client, and agent modules. The three-category classification (synchronous, own-async, cancellation) and when to use which catch variant is not obvious from any single call site.

- **Padding schemes**: Three different padding formats across the codebase — Crypto.hs uses 2-byte Word16 length prefix (max ~65KB), Crypto/Lazy.hs uses 8-byte Int64 prefix (file-sized), and both use '#' fill character. Ratchet header padding uses fixed sizes (88 or 2310 bytes). All use `pad`/`unPad` but with incompatible formats. The relationship between padding, encryption, and message size limits spans Crypto, Lazy, Ratchet, and the protocol layer.

- **NaCl construction variants**: crypto_box, secret_box, and KEM hybrid secret all use the same XSalsa20+Poly1305 core (Crypto.hs `xSalsa20`), but with different key sources (DH, symmetric, SHA3_256(DH||KEM)). The lazy streaming variant (Lazy.hs) adds prepend-tag vs tail-tag placement. File.hs wraps lazy streaming with handle-based I/O. Full picture requires reading Crypto.hs, Lazy.hs, File.hs, and SNTRUP761.hs together.
