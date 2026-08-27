# XFTP variable file storage time

## Summary

The server stores a storage time for each file. The sender sets it in the FNEW command. The sender may present a proof of an entitlement to raise the maximum storage time the server allows. Each proof is bound to the uploaded chunk and to the TLS session, so it cannot be reused for another chunk or another session.

## Entitlement

An entitlement is a name, an expiration, and an extra string. It is the disclosed content of a BBS proof: the holder's secret remains undisclosed, and the three fields are revealed. The server reads `entName` to select a maximum storage time, checks `entExpires`, and ignores `entExtra`; the interpretation of `entExtra` is out of scope here. The protocol references only the entitlement, never a badge; chat maps its own badge to an entitlement before it asks the agent to send.

The proof discloses the entitlement and includes the issuer key index and the BBS proof. The holder's secret and the BBS signature remain with the sender and are never transmitted. The origin of the sender's signed entitlement, from the entitlement service, is out of scope here.

```
entitlement = entName entExpires entExtra
entName = shortString        ; e.g. "supporter", "legend"
entExpires = shortString     ; expiration, encoded as signed
entExtra = shortString       ; opaque, interpretation out of scope

entitlementProof = issuerKeyIndex bbsProof entitlement
issuerKeyIndex = 2*2 OCTET   ; Word16, network byte order
bbsProof = largeString       ; BBS proof bytes
```

The presentation header that the BBS proof is generated over is not transmitted; the server reconstructs it from the command context (see [Binding](#binding)), which is what binds the proof.

## Storage time

```
fileStorageTime = storageMax / storageFor
storageMax = %s"M"
storageFor = %s"F" storageHours
storageHours = 4*4 OCTET     ; Word32, network byte order
```

`storageMax` requests the maximum the server allows for the presented entitlement, or the default maximum when no proof is present. `storageFor` requests a specific number of hours.

## Commands, new XFTP version

The new protocol version extends FNEW.

```
fnew = %s"FNEW " fileInfo rcvKeys optBasicAuth fileStorageTime optEntitlementProof
optEntitlementProof = %s"0" / (%s"1" entitlementProof)
```

`fileInfo`, `rcvKeys`, and `optBasicAuth` are defined by the current XFTP protocol. Version 3 and earlier encode neither `fileStorageTime` nor the proof, and the server applies the default storage time.

## Responses

FNEW extends the SIDS response with the granted storage.

```
sndIds = %s"SIDS " senderId rcvIds grantedStorageTime
grantedStorageTime = grantedExpires
grantedExpires = %s"F" expiresAt
expiresAt = 8*8 OCTET        ; Int64, seconds since epoch (absolute UTC instant), network byte order
```

`grantedExpires` returns the absolute expiration. The sum encoding retains a one-character prefix so further variants can be added. `senderId` and `rcvIds` are defined by the current XFTP protocol.

## Binding

The presentation header binds each proof to the TLS session and to the specific chunk. The server reconstructs it and rejects a proof generated for any other session or chunk.

```
presHeader = sessionId sndKey digest
```

The chunk is identified by the sender key and the digest, which the server verifies for every command on the file. `sessionId` is the TLS session identifier; `sndKey` and `digest` are the fields of `fileInfo`.

## Maximum storage time

The server configures a maximum storage time for each entitlement name, and a default maximum for requests with no proof. Each maximum is a number of hours. The server exits at startup if any name's maximum is below the default, so a proof never reduces the allowed time. The server treats an entitlement whose expiration has passed as no proof.

If the requested time exceeds the maximum, the server stores the file for the maximum and does not reject the request.

## Encoding primitives

```
shortString = length *OCTET   ; 0-255 bytes
largeString = length2 *OCTET
length = 1*1 OCTET
length2 = 2*2 OCTET           ; Word16, network byte order
```

`senderId`, `rcvIds`, `fileInfo`, `sndKey`, `digest`, `rcvKeys`, `optBasicAuth`, and `sessionId` are defined by the current XFTP and SMP protocols.
