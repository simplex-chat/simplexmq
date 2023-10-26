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
- Support general high-level interactions common for many applications:
  - RPC pattern for commands executed by the host application.
  - Events sent by host to update controller UI.
  - Uploading and downloading files between host and controller, either to be processed by the host or to be presented in the controller UI.

This design is quite close to how SimpleX Chat UI interacts with SimpleX Chat core - there is a similar RPC + events protocol and support for files.

## Protocol phases

Protocol consists of four phases:
- optional controller discovery.
- controller authentication via out-of-band communication.
- establishing TLS / HTTP2 connection between controller and host devices.
- controller/host session operation.

Out-of-band authentication is only required during the first controller/host agreement, and can be repeated to rotate long term keys identifying controller.

### Controller discovery

Initially posted [here](https://github.com/simplex-chat/simplex-chat/blob/remote-desktop/docs/rfcs/2023-10-24-robust-discovery.md).

Controller discovery allows to connect to the known controller on the same local network without out-of-band communication. This step is optional, as the session can be initiated with the new or known controller via out-of-band communication.

Discovery uses an application-defined site-local multicast group, e.g. `224.0.0.251` (also used in mDNS/bonjour) and an application-defined port (SimpleX Chat uses 5227).

The process of discovery has these steps:

1. Controller initiates UDP broadcast sending `identify` packets to confirm its own IP address and network support. Receiving this packet confirms to controller its network source address that will be used for further broadcast, without relying on some other logic to determine it via network interfaces.
2. Controller validates the source address of the received packets with matching random string against the list of network interfaces, ignoring unknown addresses. If after several packets the source addresses are not found among the network interfaces, terminates the session.
3. Controller obtains a free TCP port for remote control session and starts listening on it.
4. Controller generates a set of credentials (for the new host connection - long term CA key pair and long term signing key pair; for each session - DH key and and TLS key) for a particular host device and starts broadcasting `announce` packets with public credentials.
5. In parallel, if this is a connection to a new device Controller provides to the end user a QR code/link for out-of-band authentication from the host device.
6. Host device starts listening to the same multicast group and port - this MUST be initiated by the user action.
7. Having received `announce` packet with the valid signature, the host either initiates connection to the controller (if it is a known controller and credentials match host records), or offers the end user to authenticate this controller via out-of-band communication.

`identify` packet:

```abnf
identify = versionRange %s"I" systemSeconds counter randomBytes
counter = 2*2 OCTET ; counter of identify packets sent by controller
versionRange = version version ; version range for the remote control protocol itself
systemSeconds = 8*8 OCTET ; session start system time in seconds since epoch
randomBytes = length *OCTET ; random bytes to confirm source address
length = 1*1 OCTET
```

`announce` packet:

```abnf
announce = versionRange %s"A" systemSeconds counter serviceAddress
           caFingerprint sigPubKey signature
counter = 2*2 OCTET ; counter of announce packets sent by controller
serviceAddress = ipv4 port ; address of the controller
ipv4 = 4*4 OCTET
port = 2*2 OCTET
caFingerprint = length *OCTET ; SHA256 fingerprint of controller CA certificate (unique per host device)
sigPubKey = length x509encoded
signature = length *OCTET ; signs the preceding announcement packet
length = 1*1 OCTET
```

### Controller authentication

Controller authentication is done via link/scanning QR code - in most cases the user of both devices will be in the same location (and discovery process assumes it is the same network).

The format for the link is the following:

```abnf
sessionAddress = "xrcp://" encodedCAFingerprint ":" controllerBasicAuth "@" host ":" port "#/?" qsParams
encodedCAFingerprint = base64url
controllerBasicAuth = 1*(ALPHA / DIGIT / "-" / "_") ; MUST be included in `hello` response from the host
qsParams = param *("&" param)
param = versionRangeParam / appNameParam / sigPubKeyParam / deviceNameParam / signatureParam
versionRangeParam = "v=" (versionParam / (versionParam "-" versionParam))
versionParam = 1*DIGIT
appNameParam = "app=" 1*(ALPHA / DIGIT / "-" / "_")
sigPubKeyParam = "key=" base64url ; required
deviceNameParam = "device=" base64url ; optional
signatureParam = "sig=" base64url ; required, signs the URI with this param removed
base64url = <base64url encoded binary> ; RFC4648, section 5
```

In case the controller was "discovered", the parameters in session address should be the same as in `announce` packet:
- serviceAddress = host:port
- caFingerprint = encodedCAFingerprint
- sigPubKey = sigPubKeyParam
- dhPubKey = dhPubKeyParam

The host MUST validate the signature (having removed signature parameter from URI).

### Controller connection

Host connects to controller via TCP session and validates CA credentials during TLS handshake. Controller acts as a TCP server in this connection, to avoid host device listening on a port, which might create an attack vector. During TLS handshake the controller's TCP server presents a self-signed two-certificate chain where the fingerprint of the first certificate MUST be the same as in `announce` packet and in the session address.

During the first connection:
- the controller maintains the port available for the new connections until the valid auth token is presented in `hello` response in the next phase, to protect from other devices trying to connect to the same port.
- the host generates client CA certificate for TLS, and the controller will save it as a trusted certificate for this host device once `hello` with the valid auth token is received.

During subsequent connections:
- the controller validates presented client certificate against trusted CA certificate for this host device, and if it is not valid terminates the connection. Once the valid host connects the controller stops accepting the new connections.
- the host still must present valid auth token in hello.

For remote control session HTTP2 encoding is used, with the HTTP2 server started on host device (acting as TCP client). This matches remote control semantics better than making controller a server, but requires the implementation to connect HTTP2 server to the TLS connection of the TCP client.

Once connection is established, the controller and host device communicate using control protocol.

### controller/host session operation

The protocol for the session consists of variable size HTTP2 requests and responses. HTTP2 REST semantics are not used to allow additional encryption layer inside TLS. All requests are sent as POST to the path "/" of the host device HTTP2 server.

Body of the requests and responses has this format:

```abnf
request = signature signed [largeLength attachment]
response = %x00 signed [largeLength attachment]
body = sessionIdentifier corrId hostId cmdResp
; corrId is required in controller commands and host responses,
; it is empty in server notifications.
corrId = length *OCTET
hostId = length *OCTET ; will be %x01 %x01 – reserved for future use
; empty queue ID is used with "create" command and in some server responses
cmdResp = largeLength hello / largeLength encrypted(rcCommand / rhResponse)
hello = <json> ; rcHello / rhHello
rcCommand = <json> ; send / recv / storeFile / getFile
rhResponse = <json> ; resp / event / fileStored / file / error
signature = length *OCTET
largeLength = 4*4 OCTET ; length of JSON or of attachment
; empty signature can be used with "send" before the queue is secured with secure command
; signature is always empty with "ping" and "serverMsg"
```

Commands and responses (rcCommand / rhResponse) are encoded as JSON to simplify extensibility. The schema for the commands is described by JTD (RFC 8927) in [rc-command.schema.json](./remote-control/rc-command.schema.json) and for responses - in [rc-response.schema.json](./remote-control/rc-response.schema.json).

The first command sent by the controller and accepted by host MUST be hello, this is sent without additional encryption, the response contains the DH key of the host.

`sessionIdentifier` MUST be tlsunique channel binding from TLS session - this prevents replay attacks.
