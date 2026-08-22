# XFTP variable file storage time

## Summary

The server stores a storage time for each file. The sender sets it in the FNEW command and resets it with a new FTTL command. The sender may present a proof of an entitlement to raise the maximum storage time the server allows. Each proof is bound to the uploaded chunk and to the TLS session, so it cannot be reused for another chunk or another session.

## Entitlement

An entitlement is a level, an expiration, and an extra string. It is the disclosed content of a BBS proof: the holder's secret remains undisclosed, and the three fields are revealed. The server reads `entLevel` to select a maximum storage time, checks `entExpires`, and ignores `entExtra`; the interpretation of `entExtra` is out of scope here. The protocol references only the entitlement, never a badge; chat maps its own badge to an entitlement before it asks the agent to send.

The proof discloses the entitlement and includes the issuer key index and the BBS proof. The holder's secret and the BBS signature remain with the sender and are never transmitted. The origin of the sender's signed entitlement, from the entitlement service, is out of scope here.

```
entitlement = entLevel entExpires entExtra
entLevel = shortString       ; e.g. "supporter", "legend"
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

`storageMax` requests the maximum the server allows for the presented entitlement, or the default maximum when no proof is present; this maximum may be permanent. `storageFor` requests a specific number of hours.

## Commands, new XFTP version

The new protocol version extends FNEW and adds FTTL.

```
fnew = %s"FNEW " fileInfo rcvKeys optBasicAuth fileStorageTime optEntitlementProof
fttl = %s"FTTL " fileStorageTime optEntitlementProof
optEntitlementProof = %s"0" / (%s"1" entitlementProof)
```

FTTL is authorized with the sender key of the file, as the other sender commands are. It sets the expiration to the resolved storage time (see [Maximum storage time](#maximum-storage-time)) and may reduce the current expiration, since the sender can also delete the file.

`fileInfo`, `rcvKeys`, and `optBasicAuth` are defined by the current XFTP protocol. Version 3 and earlier encode neither `fileStorageTime` nor the proof, and the server applies the default storage time.

## Responses

FNEW extends the SIDS response with the granted storage, and FTTL adds a response.

```
sndIds = %s"SIDS " senderId rcvIds grantedStorage
fileTime = %s"TTL " grantedStorage
grantedStorage = grantedExpires / grantedPerm
grantedExpires = %s"F" expiresSeconds
grantedPerm = %s"P"
expiresSeconds = 8*8 OCTET   ; Int64 seconds since epoch, network byte order
```

`grantedExpires` returns the absolute expiration, and `grantedPerm` indicates permanent storage. `senderId` and `rcvIds` are defined by the current XFTP protocol.

## Binding

The presentation header binds each proof to the TLS session and to the specific chunk. The server reconstructs it and rejects a proof generated for any other session or chunk.

```
fnewPresHeader = sessionId sndKey digest
fttlPresHeader = sessionId senderId
```

On FNEW the chunk is identified by the sender key and the digest, which the server verifies for every later command on the file. On FTTL the chunk is identified by `senderId`, which the server has assigned by then. `sessionId` is the TLS session identifier; `sndKey` and `digest` are the fields of `fileInfo`.

## Maximum storage time

The server configures a maximum storage time for each entitlement level, and a default maximum for requests with no proof. Each maximum is a number of hours or permanent. The server exits at startup if any level maximum is below the default, so a proof never reduces the allowed time. The server treats an entitlement whose expiration has passed as no proof.

If the requested time exceeds the maximum, the server stores the file for the maximum and does not reject the request. `storageMax` yields permanent storage when the level maximum is permanent, and the finite maximum otherwise.

## Encoding primitives

```
shortString = length *OCTET   ; 0-255 bytes
largeString = length2 *OCTET
length = 1*1 OCTET
length2 = 2*2 OCTET           ; Word16, network byte order
```

`senderId`, `rcvIds`, `fileInfo`, `sndKey`, `digest`, `rcvKeys`, `optBasicAuth`, and `sessionId` are defined by the current XFTP and SMP protocols.
