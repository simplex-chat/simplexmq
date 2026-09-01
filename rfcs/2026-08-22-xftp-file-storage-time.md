# XFTP variable file storage time

## Summary

The server stores a storage time for each file. The sender sets it in the FNEW command. The client may present a proof of an entitlement in the handshake to raise the maximum storage time the server allows. The proof is bound to the TLS session, so it cannot be reused for another session.

An entitlement belongs to the user, not to a file: the client presents it once per connection, and the server applies it to everything the client does in that session. The server can also vary other limits, such as throttling, by the entitlement.

## Entitlement

An entitlement is a name, an expiration, and an extra string. It is the disclosed content of a BBS proof: the holder's secret remains undisclosed, and the three fields are revealed. The server reads `entName` to select a maximum storage time, checks `entExpires`, and ignores `entExtra`; the interpretation of `entExtra` is out of scope here. The protocol references only the entitlement, never a badge; chat maps its own badge to an entitlement before it asks the agent to send.

The proof discloses the entitlement and includes the issuer key index and the BBS proof. The holder's secret and the BBS signature remain with the sender and are never transmitted. The origin of the sender's signed entitlement, from the entitlement service, is out of scope here.

```
entitlement = entExpires entName entExtra
entExpires = shortString     ; expiration as a UTCTime ISO8601 string
entName = shortString        ; e.g. "supporter", "legend"
entExtra = largeString       ; opaque, interpretation out of scope

entitlementProof = issuerKeyIndex bbsProof entitlement
issuerKeyIndex = 2*2 OCTET   ; Word16, network byte order
bbsProof = largeString       ; BBS proof bytes
```

The presentation header that the BBS proof is generated over is not transmitted; the server takes it from the session (see [Binding](#binding)), which is what binds the proof.

### Issuer keys

Client apps and servers share one list of issuer public keys, indexed by `issuerKeyIndex`. The secret key for the current index is held by the service that issues entitlements, on conditions that are out of scope here, such as payment.

The list holds eight keys so that the issuing service can rotate its current key without an app or server release: the next index is already known to every app and server. Each rotation consumes one index, so a new key has to be added to client apps and servers eventually, and released before the list is exhausted.

## Storage time

```
fileStorageTime = %s"0" / (%s"1" storageHours)
storageHours = 4*4 OCTET     ; Word32, network byte order
```

The storage time is an optional number of hours. Absent (`%s"0"`), or present as zero hours, requests the maximum the server allows for the presented entitlement, or the default maximum when no proof is present. A value above zero requests that number of hours, and the server grants the smaller of it and the maximum.

## Handshake, new XFTP version

The client handshake carries the entitlement proof.

```
clientHandshake = xftpVersion keyHash optEntitlementProof
optEntitlementProof = %s"0" / (%s"1" entitlementProof)
```

`xftpVersion` and `keyHash` are defined by the current XFTP protocol. Version 3 and earlier encode no proof.

The server verifies the proof when it accepts the handshake and keeps the result for the session; further handshakes on the same connection keep that result and verify nothing, so a session costs one verification however many handshakes it makes. A proof that names an entitlement the server does not configure, or one whose expiration passed 24 hours ago or more, is ignored without verification; a proof that fails to verify is logged. In each case the session gets the default maximum. The response is the same in every case, but only a configured, unlapsed name costs a verification, so the handshake latency tells the client which names the server configures.

## Commands

The new protocol version extends FNEW with the storage time.

```
fnew = %s"FNEW " fileInfo rcvKeys optBasicAuth fileStorageTime
```

`fileInfo`, `rcvKeys`, and `optBasicAuth` are defined by the current XFTP protocol. Version 3 and earlier encode no `fileStorageTime`, and the server applies the default storage time.

## Responses

FNEW extends the SIDS response with the granted storage.

```
sndIds = %s"SIDS " senderId rcvIds optGrantedStorageTime
optGrantedStorageTime = %s"0" / (%s"1" grantedStorageTime)
grantedStorageTime = grantedExpires
grantedExpires = %s"T" expiresAt
expiresAt = 8*8 OCTET        ; Int64, seconds since epoch (absolute UTC instant), network byte order
```

`grantedExpires` returns the absolute expiration — the same value stored for the file. The sum encoding retains a one-character prefix so further variants can be added. Version 3 and earlier omit `optGrantedStorageTime` entirely; a client decoding such a response reads it as absent. `senderId` and `rcvIds` are defined by the current XFTP protocol.

## Binding

The presentation header binds the proof to the TLS session, so a proof presented on any other session fails to verify.

```
presHeader = sessionId
```

`sessionId` is the TLS session identifier, the TLS unique channel binding. Both sides take it from the connection: the client has it once TLS is established, and the client checks that the identifier the server sends in its handshake matches.

Binding to the session is what stops a proof being replayed by another client. A proof is not bound to a file, because the entitlement belongs to the user and authorises everything the client does in that session.

BBS proofs of one credential are unlinkable, but every proof discloses the same `entExpires`, `entName` and `entExtra`, so a server can link the sessions of one holder by that triple, and two servers can correlate them. The issuing service decides how identifying it is: `entExpires` set to the same instant for everyone who buys in the same period, and an `entExtra` that carries nothing per-holder, make the holders of that period indistinguishable.

## Maximum storage time

The server configures a maximum storage time for each entitlement name, and a default maximum for requests with no proof. Each maximum is a number of hours. The server exits at startup if any name's maximum is below the default, so a proof never reduces the allowed time. The server honours an entitlement for 24 hours after its expiration; past that grace it is treated as no proof.

If the requested time exceeds the maximum, the server stores the file for the maximum and does not reject the request. The expiration is rounded up to the hour, stored, and returned as `grantedExpires`.

## Encoding primitives

```
shortString = length *OCTET   ; 0-255 bytes
largeString = length2 *OCTET
length = 1*1 OCTET
length2 = 2*2 OCTET           ; Word16, network byte order
```

`senderId`, `rcvIds`, `fileInfo`, `sndKey`, `digest`, `rcvKeys`, `optBasicAuth`, and `sessionId` are defined by the current XFTP and SMP protocols.
