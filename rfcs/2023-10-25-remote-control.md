# SimpleX Remote Control protocol

Using profiles in SimpleX Chat mobile app from desktop app with minimal risk to the security model of SimpleX protocols.

## Problem

Synchronizing profiles that use double ratchet for e2e encryption is effectively impossible in a way that tolerates partitioning between devices.

We are not considering replacing double ratchet to allow profile synchronization, as some other messengers did. We are also not considering Signal model, when profile is known to the server and adding devices results in changing security code and no visibility of conversation history, as it would be substantially different from the current model.

## Solution

The proposed option is remote access/control protocol, when the application on host device (usually mobile) acts as a server, and application on another device (usually desktop) acts as a controller usually running in the same local network.

Service discovery and remote control protocols known to us are vulnerable to spoofing, spamming and MITM attacks. This design aims to solve these problems.

## Requirements

- Strong, cryptographically verified identity of the controller device, with the initial connection requiring out-of-band communication of public keys (QR code or link).
- Protection against malicious "controllers" trying to make host connect to them instead of valid controller on the same network.
- Protection against replay attacks, both during discovery and during control session.
- Additional encryption layer inside TLS.
- Protect host device from unauthorized access in case of controller compromise.
- Have post-compromised security - that is, even if long term secrets were copied from the controller, and host device was made to connect to malicious controller device, prevent malicious controller from accessing the host device data.
- Support general high-level interactions common for many applications:
  - RPC pattern for commands executed by the host application.
  - Events sent by host to update controller UI.
  - Uploading and downloading files between host and controller, either to be processed by the host or to be presented in the controller UI.

This design is quite close to how SimpleX Chat UI interacts with SimpleX Chat core - there is a similar RPC + events protocol and support for files.

## Protocol phases

Protocol consists of four phases:
- controller session announcement
- establishing session TLS connection
- session verification and protocol negotiation
- session operation

### Session announcement

The first session between host and controller pair MUST be announced out-of-band, to establish a long term identity keys/certificates of the controller to host device.

The subsequent sessions will be announced via an application-defined site-local multicast group, e.g. `224.0.0.251` (also used in mDNS/bonjour) and an application-defined port (SimpleX Chat uses 5227).

The session announcement contains this data:
- supported version range for remote control protocol
- application name
- device name
- session start time in seconds since epoch
- if multicast is used, counter of announce packets sent by controller
- network address (ipv4 address and port) of the controller
- CA TLS certificate fingerprint of the controller - this is part of long term identity of the controller established during the first session, and repeated in the subsequent session announcements.
- Session Ed25519 public key used to verify the announcement and commands - this mitigates the compromise of the long term signature key, as the controller will have to sign each command with this key first.
- Long-term Ed25519 public key used to verify the announcement and commands - this is part of the long term controller identity.
- Session X25519 DH key and sntrup761 KEM encapsulation key to agree session encryption (both for multicast announcement and for commands and responses in TLS), as described in https://datatracker.ietf.org/doc/draft-josefsson-ntruprime-hybrid/. The new keys are used for each session, and if client key is already available (from the previous session), the computed shared secret will be used to encrypt the announcement multicast packet. The initial out-of-band announcement is always unencrypted. These DH and KEM key are always sent unencrypted. NaCL Cryptobox is used for encryption.
- additional application specific parameters, e.g controller settings.

Host device decrypts (except the first session) and validates the announcement:
- Session signature is valid.
- Timestamp is within some window from the current time.
- Long-term key signature is valid.
- Long-term CA and key are the same as in the first session.
- Some version in the range can be supported.

OOB announcement is a URI with this syntax:

```abnf
sessionAddressUri = "xrcp://" encodedCAFingerprint "@" host ":" port "#/?" qsParams
encodedCAFingerprint = base64url
qsParams = param *("&" param)
param = versionRangeParam / appInfoParam / sessionTsParam /
        sessPubKeyParam / idPubKeyParam / kemEncKeyParam / dhPubKeyParam /
        sessSignatureParam / idSignatureParam
versionRangeParam = "v=" (versionParam / (versionParam "-" versionParam))
versionParam = 1*DIGIT
appInfoParam = "app=" escapedJSON ; optional
sessionTsParam = "ts=" 1*DIGIT
sessPubKeyParam = "skey=" base64url ; required
idPubKeyParam = "idkey=" base64url ; required
kemEncKeyParam = "kem=" base64url ; required, can we have x509encoded?
dhPubKeyParam = "dh=" base64url ; required
sessSignatureParam = "ssig=" base64url ; required, signs the URI with this and idSignatureParam param removed
idSignatureParam = "idsig=" base64url ; required, signs the URI with this param removed
base64url = <base64url encoded binary> ; RFC4648, section 5
```

Multicast announcement is a binary encoded packet with this syntax:

```abnf
sessionAddressPacket = dhPubKey nonce encrypted(unpaddedSize serviceAddress sessSignature idSignature pad)
dhPubKey = length x509encoded
nonce = length *OCTET
serviceAddress = largeLength serviceAddressJSON
sessSignature = length *OCTET ; signs the preceding announcement packet
idSignature = length *OCTET ; signs the preceding announcement packet including sessSignature
length = 1*1 OCTET ; for binary data up to 255 bytes
largeLength = 2*2 OCTET ; for binary data up to 65535 bytes
```

addressJSON is a JSON string valid against this JTD (RFC 8927) schema:

```json
{
  "definitions": {
    "versionRange": {
      "type": "string",
      "metadata": {
        "format": "[0-9]+(-[0-9]+)?"
      }
    },
    "base64url": {
      "type": "string",
      "metadata": {
        "format": "base64url"
      }
    }
  },
  "properties": {
    "ca": {"ref": "base64url"},
    "host": {"type": "string"},
    "port": {"type": "uint16"},
    "v": {"ref": "versionRange"},
    "ts": {"type": "uint64"},
    "skey": {"ref": "base64url"},
    "idkey": {"ref": "base64url"},
    "kem": {"ref": "base64url"}
  },
  "optionalProperties": {
    "app": {"type": "string"}
  },
  "additionalProperties": true
}
```

### Establishing session TLS connection

Host connects to controller via TCP session and validates CA credentials during TLS handshake. Controller acts as a TCP server in this connection, to avoid host device listening on a port, which might create an attack vector. During TLS handshake the controller's TCP server presents a self-signed two-certificate chain where the fingerprint of the first certificate MUST be the same as in the announcement.

Host device presents its own client certificate chain with CA representing a long-term identity of the host device.

### Session verification and protocol negotiation

Once TLS session is established, both the host and controller device present a "session security code" to the user who must match them (e.g., visually or via QR code scan) and confirm on the host device. The session security code must be a digest of tlsunique channel binding. As it is computed as a digest of the TLS handshake for both the controller and the host, it will validate that the same TLS certificates are used on both sides, and that the same TLS session is established.

Once the session is confirmed by the user, the host device sends "hello" block to the controller. ALPN TLS extension is not used to obtain tlsunique prior to sending any packets.

Block size should be 16384 bytes.

Hello block must contain:
- KEM ciphertext with encapsulated secret and new session DH key - used to compute new shared secret with the controller keys from the announcement.
- encrypted part of hello block (JSON object), containing:
  - chosen protocol version.
  - host CA TLS certificate fingerprint - part of host long term identity - must match the one presented in TLS handshake and the previous sessions, otherwise the connection is terminated.
  - host device name
  - chosen application version.
  - additional application specific parameters, e.g host settings or JSON encoding format.

Hello block syntax:
  
```abnf
helloBlock = unpaddedSize %s"HELLO " dhPubKey kemCiphertext nonce encrypted(unpaddedSize helloBlockJSON pad) pad
unpaddedSize = 2*2 OCTET
pad = <pad block size to 16384 bytes>
kemCiphertext = length *OCTET
```

Controller decrypts (including the first session) and validates the received hello block:
- Chosen versions are supported (must be within offered ranges).
- CA fingerprint matches the one presented in TLS handshake and the previous sessions - in subsequent sessions TLS connection should be rejected if the fingerprint is different.

JTD schema for the encrypted part of hello block:

```json
{
  "definitions": {
    "version": {
      "type": "string",
      "metadata": {
        "format": "[0-9]+"
      }
    },
    "base64url": {
      "type": "string",
      "metadata": {
        "format": "base64url"
      }
    }
  },
  "properties": {
    "v": {"ref": "version"},
    "ca": {"ref": "base64url"},
  },
  "optionalProperties": {
    "app": {"type": "string"}
  },
  "additionalProperties": true
}
```

Controller should reply with with `ok` or `err` block:

```
ok = unpaddedSize %s"OK" pad
err = unpaddedSize %s"ERR " length error pad
```

### Сontroller/host session operation

The protocol for communication during the session is out of scope of this protocol.

SimpleX Chat will use HTTP2 encoding, where host device acts as a server and controller acts as a client (these roles are reversed compared with TLS connection).

Payloads in the protocol must be encrypted using NaCL cryptobox using the shared secret agreed during session establishment.

Commands of the controller must be signed after the encryption using the controller's session and long term Ed25519 keys.

tlsunique channel binding from TLS session MUST be included in commands (included in the signed body).

The syntax for encrypted command and response body encoding:

```
commandBody = length encrypted(tlsunique counter length command) sessSignature idSignature
responseBody = length encrypted(tlsunique counter length response) ; should match counter in the command
tlsunique = length 1*OCTET
counter = 8*8 OCTET ; int64
```

## Key agreement for announcement packet and for session

Initial announcement is shared out-of-band, and it is not encrypted.

This announcement contains DH and KEM keys, which are used to agree session encryption keys - the HELLO block will containt DH key and KEM ciphertext with encapsulated secret that will be used to determine the shared secret (using SHA512 over concatenated DH shared secret and KEM encapsulated secret).

During the next session we send announcement via encrypted multicast block. The shared key for this secret is determined using the KEM shared secred from the previous session and DH shared secret computed using the host DH key from the previous session and the new controller DH key from the announcement.

For the session, the shared secred is computed again using the KEM shared secret encapsulated using the new KEM key from the announcement and DH shared secret computed using the host DH key from HELLO block and the new controller DH key from the announcement.

To describe it in pseudocode:

```
// session 1
sessionSecret(1) = sha512(dhSecret(1) || kemSecret(1)) // to encrypt session 1 data, incl. hello
dhSecret(1) = dh(hostHelloDhKey(1), controllerAnnouncementDhKey(1))
kemCiphertext(1) = enc(kemSecret(1), kemEncKey(1))
kemSecret(1) = dec(kemCiphertext(1), kemDecKey(1))

// announcement for session n
announcementSecret(n) = sha512(dhSecret(n') || kemSecret(n - 1))
dhSecret(n') = dh(hostHelloDhKey(n - 1), controllerAnnouncementDhKey(n))

// session n
sessionSecret(n) = sha512(dhSecret(n) || kemSecret(n))
dhSecret(n) = dh(hostHelloDhKey(n), controllerAnnouncementDhKey(n))
kemCiphertext(n) = enc(kemSecret(n), kemEncKey(n))
kemSecret(n) = dec(kemCiphertext(n), kemDecKey(n))
```

If controller fails to store the new host DH key after receiving HELLO block, the encryption will become out of sync and the host won't be able to decrypt the next announcement. To mitigate it, the host should keep the last session DH key and also previous session DH key to try to decrypt the next announcement computing shared secret using both keys (first the new one, and in case it fails - the previous).

## Other options

The proposed design has these pros/cons:

Pros:
- mobile host that has sensitive data doesn't act as TLS server.
- multicast is optional - all sessions can happen via QR code only.

Cons:
- reversing of client/server roles between TLS and HTTP2.
- in the first session mobile host TLS client credentials are verified after TLS connection is accepted.
- cannot be used with host that runs in VM.

The alternative design will use mobile host device as TLS server. The session negotiation process:

- desktop shares its initial credentials via QR code, only for the first session
- mobile sends encrypted multicast with session address, TLS CA fingerprint, DH key in clear text
- desktop connects to mobile
- session tlsunique presented to users on both devices - either user would have to confirm session on both devices or the mobile would have to send an additional "ready" block.

Pros:
- no reversing server role between TLS and HTTP2
- TLS credentials are exchanged before TLS, so invalid credentials can be rejected during the handshake of the first session.
- if some other way to pass data from host to controller is added, then it can be used with host running in VM. 

Cons:
- multicast is mandatory, as there is no efficient way to communicate from mobile to desktop.
- still needs hello or confirmation on both devices
- mobile is now acting as TLS server creating additional attack vector

In both proposed and alternative design mobile host has chat data, acts as HTTP2 server, commands are signed with desktop key presented out-of–band, and both commands and responses are encrypted inside TLS session.

Other considered options:
- SSH - more work integrating it.
- use SMP connection to negotiate TLS session - it seems wrong to require Internet connection to negotiate a local network connection between desktop and mobile.
- other multicast service discovery protocols - quite insecure.

## Threat model

#### A passive network adversary able to monitor the site-local traffic:

*can:*
- observe session times, duration and volume of the transmitted data between host and controller.

*cannot:*
- observe the content of the transmitted data.
- substitute the transmitted commands or responses.
- replay transmitted commands or events from the hosts.

#### An active network adversary able to intercept and substitute the site-local traffic:

*can:*
- prevent host and controller devices from establishing the session

*cannot:*
- same as passive adversary, provided that user visually verified session code out-of-band.

#### An active adversary with the access to the network:

*can:*
- spam controller device.

*cannot:*
- compromise host or controller devices.

#### An active adversary with the access to the network who also observed OOB announcement:

*can:*
- connect to controller instead of the host.
- present incorrect data to the controller.

*cannot:*
- connect to the host or make host connect to itself.

#### Compromised controller device:

*can:*
- observe the content of the transmitted data.
- access any data of the controlled host application, within the capabilities of the provided API.

*cannot:*
- access other data on the host device.
- compromise host device.

#### Compromised host device:

*can:*
- present incorrect data to the controller.
- incorrectly interpret controller commands.

*cannot:*
- access controller data, even related to this host device.
