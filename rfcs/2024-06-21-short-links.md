# Short invitation links

## Problem

Long links look scary and unsafe for many users. While this is a perceived problem, rather than a real one, it hurts adoption.

What is worse, long links do not fit in profile descriptions of other social networks where people might want to advertize their contact addresses.

The current link size limitation is also the reason for not including PQ KEM keys into invitation links and addresses, postponing the moment when PQ-resistant encryption kicks in - if we include PQ KEM key into the link, the QR code will not be scannable.

## Solution

MITM-resistant link shortening.

Instead of generating the random address that would resolve into the link - doing so would create the possibility of MITM by the server hosting this link - we can hash the full link with SHA256 or SHA512 and use this hash as part of the shorter address.

The proposed syntaxt:

```abnf
shortConnectionRequest = connectionScheme "/" connReqType "#/" smpServer "/" linkHash
connReqType = %s"invitation" / %s"contact"
connectionScheme = (%s"https://" clientAppServer) / %s"simplex:"
clientAppServer = hostname [ ":" port ]
  ; client app server, e.g. simplex.chat
smpServer = serverIdentity "@" srvHosts [":" port] ; no smp:// prefix, no escaping
srvHosts = <hostname> ["," srvHosts] ; RFC1123, RFC5891
linkHash = <base64url encoded SHA256 or SHA512 hash of the original link>
```

Example link:

```
https://simplex.chat/contact/#0YuTwO05YJWS8rkjn9eLJDjQhFKvIYd8d4xG8X1blIU=@smp8.simplex.im/abcdefghij0123456789abcdefghij0123456789abc=
```

This link has the length of ~199 characters (256 bits), which is a bit shorter than the full contact address (~310 characters) and much shorter than invitation links (~528 characters) even without post-quantum keys added to them.

This size can be further reduced by
- not pinning server TLS certificate - the downside here is that while the attack that compromises TLS will not be able to substitute the link (because it's hash will not match), it will be able to intercept and to block it.
- do not include onion address, as the connection happens via proxy anyway, if it's untrusted server.
- use server domain for the link.
- using shorter hash, e.g. SHA128 - reducing the collision resistance.

If the server is known, the client could use it's hash and onion address, otherwise it could trust the proxy to use any existing session with the same hostname or to accept the risk of interception - given that there is no risk of substitution.

With some of these "improvements" the link could be ~122 characters:

```
https://smp8.simplex.im/contact/#0YuTwO05YJWS8rkjn9eLJDjQhFKvIYd8d4xG8X1blIU@/abcdefghij0123456789abcdefghij0123456789abc
```

Preserving onion address it will be ~184 characters:

```
https://smp8.simplex.im/contact/#0YuTwO05YJWS8rkjn9eLJDjQhFKvIYd8d4xG8X1blIU@beccx4yfxxbvyhqypaavemqurytl6hozr47wfc7uuecacjqdvwpw2xid.onion/abcdefghij0123456789abcdefghij0123456789abc
```

If we implement it, the request to resolve the link would be made via proxied SMP command (to avoid the direct connection between the client and the recipient's server).

Pros:
- a bit shorter link.
- possibility to include post-quantum keys into the full link keeping the same shortened link size.

Cons:
- the length reduction, compared with the current contact address, is less than 25%.
- protocol complexity.
- even though the server cannot replace the link, it will have access to it.

Overall, there is a strong argument for postponing this improvement until we add identity/addressing layer with short memorizable addresses.

## Protocol

To support short links, the SMP servers would provide a simple key-value store enabled by three additional commands: `WRT`, `CLR` and `READ`

`WRT` command is used to store and to update values in the store. The size of the value is limited by the same size as sent messages (or, possibly, smaller - as connection information size used in confirmation messages) - the clients would use this fixed size irrespective of the content. `WRT` command will be sent with the data blob ID in the transaction entityId field, public authorization key used to authorize `WRT` and `CLR` commands (subsequent WRT commands to the existing key must use the same key), and the data blob.

`CLR` command must use with the same entity ID and must be authorized by the same key.

`READ` command must use the ID which hash would be equal of the ID used to create the data blob, and this ID would also be used as public authorization

Algorigthm to store and to retrieve data blob.

**Store data blob**

- the data blob owner generates X25519 key pair: `(k, pk)`.
- private key `pk` will be included in the short link shared with the other party (only base64url encoded key bytes, not X509 encoding).
- `HKDF(pk)` will be used to encrypt the link data with secret_box before storing it on the server.
- the hash of public key `sha256(k)` will be used as ID by the owner to store and to remove the data blob (`WRT` and `CLR` commands).

**Retrieve data blob**

- the sender uses the public key `k` derived from the private key `pk` included in the link as entity ID to retrive data blob (the server will compute the ID used by the owner as `sha256(k)` and will be able to look it up). This provides the quality that the traffic of the parties has no shared IDs inside TLS. It also means that unlike message queue creation, the ID to retrieve the blob was never sent to the blob creator, and also is not known to the server in advance (the second part is only an observation, in itself it does not increase security, as server has access to an encrypted blob anyway).
- note that the sender does not authorize the request to retrieve the blob, as it would not increase security unless a different key is used to authorize, and adding a key would increase link size.
- server session keys with the sender will be `(sk, spk)`, where `sk` is public key shared with the sender during session handshake, and `spk` is the private key known only to the server.
- this public key `k` will also be combined with server session key `spk` using `dh(k, spk)` to encrypt the response, so that there is no ciphertext in common in sent and received traffic for these blobs. Correlation ID will be used as a nonce for this encryption.
- having received the blob, the client can now decrypt it using secret_box with `HKDF(pk)`.

Using the same key as ID for the request, and also to additionally ecrypt the response allows to use a single key in the link, without increasing the link size.
