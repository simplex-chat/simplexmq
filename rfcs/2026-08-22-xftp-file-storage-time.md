# XFTP variable file storage time

## Summary

The server stores a storage time for each file. The sender sets it in the FNEW command and resets it with a new FTTL command. The sender may present a proof of an entitlement to raise the maximum storage time the server allows. Each proof is bound to the uploaded chunk and to the TLS session, so it cannot be reused for another chunk or another session.

## Entitlement

An entitlement is a level, an expiration, and an extra string:

```
data Entitlement = Entitlement
  { level :: Text,
    expiresAt :: UTCTime,
    extraInfo :: Text
  }
```

The entitlement is the disclosed content of a BBS proof: the holder's secret remains undisclosed, and the three fields are revealed. The server interprets `level` to select a maximum storage time and ignores `extraInfo`; interpretation of `extraInfo` is out of scope here.

The protocol layers know only the entitlement, never a badge. Chat maps its own badge to an entitlement before it asks the agent to send.

simplexmq defines the entitlement, its BBS proof generation and verification, the disclosed-message encoding, and the issuer public keys, in `Simplex.Messaging.Crypto.Entitlement`. The protocol form is `EntitlementProof` (the issuer key index, the presentation header, the BBS proof, and the entitlement). The signing form is `EntitlementCredential` (the issuer key index, the holder secret, the BBS signature, and the entitlement); the server never receives it.

## Storage time

```
data FileStorageTime = FSTMax | FSTFor Word32   -- hours
```

`FSTFor` requests a specific number of hours. `FSTMax` requests the maximum the server allows for the presented entitlement, or the default maximum when no proof is present.

## Commands, new XFTP version

FNEW gains a storage time and an optional entitlement proof:

```
FNEW FileInfo (NonEmpty RcvPublicAuthKey) (Maybe BasicAuth) FileStorageTime (Maybe EntitlementProof)
```

FTTL is a new `FileCommand FSender`, authorized with the sender key of `senderId`:

```
FTTL FileStorageTime (Maybe EntitlementProof)
```

FTTL sets the expiration to `now + min(requested, maximum)`. It may reduce the current expiration, since the sender can also delete the file.

Each command binds its proof to a presentation header:

- FNEW: `sessionId <> sndKey <> digest`
- FTTL: `sessionId <> senderId`

Both commands return the granted expiration: FNEW extends the `FRSndIds` response with it, and FTTL uses a new response that returns it.

Version 3 and earlier encode neither the storage time nor the proof, and the server applies the default storage time. `currentXFTPVersion` becomes 4.

## Maximum storage time

The server configures a maximum storage time for each entitlement level, and a default maximum for requests with no proof. The server exits at startup if any level maximum is below the default, so a proof never reduces the allowed time. The server treats an entitlement whose `expiresAt` has passed as no proof.

## Binding

The presentation header binds each proof to the TLS session and to the specific chunk. On FNEW the chunk is identified by the sender key and the digest, which the server already verifies for every later command on the file. On FTTL the chunk is identified by `senderId`, which the server has assigned by then. A proof generated for one session and chunk verifies for no other, which prevents reuse.
