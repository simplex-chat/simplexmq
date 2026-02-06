# HELLO Format Verification Report

Verification of four identified issues in the HELLO message construction and handshake flow.

## 1. PrivHeader: Is `_` (PHEmpty) expected in HELLO?

**Answer: YES — `_` (PHEmpty) is required.**

### Message Structure

After per-queue E2E decryption (`agentCbDecrypt`), the plaintext is parsed as a `ClientMessage`:

```
ClientMessage = PrivHeader <> AgentMsgEnvelope
```

**`src/Simplex/Messaging/Protocol.hs:1091-1110`:**
```haskell
data ClientMessage = ClientMessage PrivHeader ByteString

instance Encoding ClientMessage where
  smpEncode (ClientMessage h msg) = smpEncode h <> msg
  smpP = ClientMessage <$> smpP <*> A.takeByteString
```

PrivHeader has two variants (`Protocol.hs:1093-1106`):
- `PHConfirmation key` → encoded as `"K" <> smpEncode key`
- `PHEmpty` → encoded as `"_"`

### HELLO always uses PHEmpty

When sending any agent message (including HELLO), `sendAgentMessage` always uses `PHEmpty`:

**`src/Simplex/Messaging/Agent/Client.hs:1799-1803`:**
```haskell
sendAgentMessage c sq@SndQueue {..} msgFlags agentMsg = do
  let clientMsg = SMP.ClientMessage SMP.PHEmpty agentMsg
  msg <- agentCbEncrypt sq Nothing $ smpEncode clientMsg
  sendOrProxySMPMessage ...
```

The receiver confirms this expectation at **`Agent.hs:2727`:**
```haskell
(SMP.PHEmpty, AgentMsgEnvelope {agentVersion, encAgentMessage}) -> do
```

### Conclusion

If `_` is missing in the implementation, the parser at `Protocol.hs:1102-1106` will hit the `fail "invalid PrivHeader"` branch. The byte layout after per-queue E2E decryption MUST be:

```
'_' | <AgentMsgEnvelope bytes>
```

`PHConfirmation` (`K` prefix) is only used for Confirmation messages when `senderCanSecure` is false (`Client.hs:1648`).

---

## 2. AgentVersion: What version is sent in HELLO?

**Answer: The sender's `maxVersion smpAgentVRange` (currently 7), NOT the negotiated `connAgentVersion`.**

### HELLO message delivery path

HELLO is enqueued via `enqueueMessage` and delivered through the standard agent message delivery path. At delivery time:

**`src/Simplex/Messaging/Agent.hs:1788-1794`:**
```haskell
Just PendingMsgPrepData {encryptKey, paddedLen, sndMsgBody} -> do
  let agentMsgStr = encodeAgentMsgStr sndMsgBody internalSndId prevMsgHash
  AgentConfig {smpAgentVRange} <- asks config
  encAgentMessage <- liftError cryptoError $ CR.rcEncryptMsg encryptKey paddedLen agentMsgStr
  let agentVersion = maxVersion smpAgentVRange   -- <== THIS IS THE KEY LINE
      msgBody' = smpEncode $ AgentMsgEnvelope {agentVersion, encAgentMessage}
  sendAgentMessage c sq msgFlags msgBody'
```

The `agentVersion` in the `AgentMsgEnvelope` is set to `maxVersion smpAgentVRange`, which is **`currentSMPAgentVersion = VersionSMPA 7`** (`Agent/Protocol.hs:307-308`).

### Comparison with Confirmation

In contrast, the Confirmation uses the negotiated `connAgentVersion`:

**`src/Simplex/Messaging/Agent.hs:3268`:**
```haskell
pure . smpEncode $ AgentConfirmation {agentVersion = connAgentVersion, ..}
```

### Wire format of AgentMsgEnvelope

**`src/Simplex/Messaging/Agent/Protocol.hs:798-799`:**
```haskell
AgentMsgEnvelope {agentVersion, encAgentMessage} ->
  smpEncode (agentVersion, 'M', Tail encAgentMessage)
```

So the bytes after `_` (PHEmpty) are: `<version-word16> 'M' <encrypted-agent-message>`

### What happens with version mismatch?

The receiver calls `updateConnVersion` (`Agent.hs:2727-2728`) which checks compatibility:

**`src/Simplex/Messaging/Agent.hs:2836-2847`:**
```haskell
updateConnVersion conn' cData' msgAgentVersion = do
  aVRange <- asks $ smpAgentVRange . config
  let msgAVRange = fromMaybe (versionToRange msgAgentVersion) $
        safeVersionRange (minVersion aVRange) msgAgentVersion
  case msgAVRange `compatibleVersion` aVRange of
    Just (Compatible av)
      | av > agreedAgentVersion -> do
          withStore' c $ \db -> setConnAgentVersion db connId av
          ...
```

If version 5 were sent instead of 7, it would still be accepted because:
- `minSupportedSMPAgentVersion = duplexHandshakeSMPAgentVersion = VersionSMPA 2`
- Version 5 falls within the supported range [2..7]
- The connection's `connAgentVersion` would be set to `min(5, 7) = 5`
- PQ double ratchet features (version 5+) would be available, but features from versions 6-7 (secure reply queues, ratchet-on-conf) would not

### Version history

| Version | Feature | Defined at |
|---------|---------|------------|
| 2 | Duplex handshake | `Protocol.hs:286-287` |
| 3 | Ratchet sync | `Protocol.hs:289-290` |
| 4 | Delivery receipts | `Protocol.hs:292-293` |
| 5 | PQ double ratchet | `Protocol.hs:295-296` |
| 6 | Secure reply queues with provided keys | `Protocol.hs:298-299` |
| 7 | Initialize ratchet on processing confirmation | `Protocol.hs:301-302` |

---

## 3. Padding: Is 15840 correct for HELLO?

**Answer: 15840 is the INNER (double-ratchet) padding. The OUTER (per-queue E2E) padding is 16000. Both are applied.**

### Two-layer encryption with different padding

HELLO messages are encrypted twice, each with its own padding:

#### Layer 1: Inner — Double Ratchet (e2eEncAgentMsgLength = 15840)

**`src/Simplex/Messaging/Agent/Protocol.hs:322-326`:**
```haskell
e2eEncAgentMsgLength :: VersionSMPA -> PQSupport -> Int
e2eEncAgentMsgLength v = \case
  PQSupportOn | v >= pqdrSMPAgentVersion -> 13618
  _ -> 15840
```

Applied at `Agent.hs:1716`:
```haskell
(mek, paddedLen, pqEnc) <- agentRatchetEncryptHeader db cData e2eEncAgentMsgLength pqEnc_ currentE2EVersion
```

And at delivery (`Agent.hs:1791`):
```haskell
encAgentMessage <- liftError cryptoError $ CR.rcEncryptMsg encryptKey paddedLen agentMsgStr
```

#### Layer 2: Outer — Per-Queue DH E2E (e2eEncMessageLength = 16000)

**`src/Simplex/Messaging/Protocol.hs:315-316`:**
```haskell
e2eEncMessageLength :: Int
e2eEncMessageLength = 16000 -- 15988 .. 16005
```

Applied in `agentCbEncrypt` (`Client.hs:1925-1933`):
```haskell
agentCbEncrypt SndQueue {e2eDhSecret, smpClientVersion} e2ePubKey msg = do
  cmNonce <- atomically . C.randomCbNonce =<< asks random
  let paddedLen = maybe SMP.e2eEncMessageLength (const SMP.e2eEncConfirmationLength) e2ePubKey
  cmEncBody <- liftEither . first cryptoError $
    C.cbEncrypt e2eDhSecret cmNonce msg paddedLen
```

For HELLO, `e2ePubKey = Nothing`, so `paddedLen = e2eEncMessageLength = 16000`.

### Summary of padding constants

| Constant | Value | Layer | Used For |
|----------|-------|-------|----------|
| `e2eEncAgentMsgLength` | **15840** (or 13618 with PQ) | Inner (double ratchet) | HELLO, A_MSG, all agent messages |
| `e2eEncConnInfoLength` | **14832** (or 11106 with PQ) | Inner (double ratchet) | Confirmation messages |
| `e2eEncMessageLength` | **16000** | Outer (per-queue DH) | All messages (non-confirmation) |
| `e2eEncConfirmationLength` | **15904** | Outer (per-queue DH) | Confirmation messages only |

### Confirmation vs HELLO

The user is correct: HELLO uses **message padding** (16000 outer, 15840 inner), NOT confirmation padding (15904 outer, 14832 inner). The distinction is:
- `e2ePubKey = Nothing` → message padding (HELLO, A_MSG)
- `e2ePubKey = Just _` → confirmation padding (CONF only)

---

## 4. SKEY Timing: Must SKEY be sent before HELLO?

**Answer: SKEY is sent before the Confirmation (which precedes HELLO). The accepting party's reply queue does NOT need SKEY from the initiator.**

### Connection handshake sequence

The full handshake flow between Initiator (I) and Accepting Party (A):

```
I: Creates invitation queue (rcvQueue), publishes invitation URI
A: Joins via joinConnection → calls secureConfirmQueue:
   1. agentSecureSndQueue  →  SKEY on I's queue        [Agent.hs:3252]
   2. mkAgentConfirmation  →  Creates A's reply queue   [Agent.hs:3253]
   3. sendConfirmation     →  Sends CONF on I's queue   [Agent.hs:3255]
I: Receives CONF, processes it
I: Sends HELLO on A's reply queue                       [Agent.hs:1551]
A: Receives HELLO, responds with HELLO (duplex)         [Agent.hs:2992-2995]
```

### SKEY in secureConfirmQueue

**`src/Simplex/Messaging/Agent.hs:3250-3257`:**
```haskell
secureConfirmQueue c nm cData rq_ sq srv connInfo e2eEncryption_ subMode = do
  sqSecured <- agentSecureSndQueue c nm cData sq    -- Step 1: SKEY
  (qInfo, service) <- mkAgentConfirmation ...       -- Step 2: Create reply queue
  msg <- mkConfirmation qInfo                       -- Step 3: Build CONF
  void $ sendConfirmation c nm sq msg               -- Step 4: Send CONF
```

**`Agent.hs:3270-3281`:** agentSecureSndQueue sends SKEY only when:
- `senderCanSecure queueMode` is True (queue is `QMMessaging`)
- Queue status is `New` (not already secured via LKEY from short links)

### Reply queue security

The accepting party's reply queue does NOT need SKEY from the initiator because:

1. **The accepting party creates the reply queue** in `mkAgentConfirmation` → `createReplyQueue` (`Agent.hs:1212-1221`)
2. The reply queue info is sent to the initiator inside the CONF message
3. The initiator uses the queue as a sender — it never needs to "secure" a queue it's sending to; the queue is already authenticated by the fact that the accepting party created it and controls the receiver keys
4. The initiator sends HELLO on this reply queue via `enqueueMessage` (`Agent.hs:1551`) using `sendAgentMessage`, which authenticates with `sndPrivateKey` (`Client.hs:1803`)

### Short-link exception

When queues are created via short links with pre-provided sender keys (LKEY), the queue starts in `Secured` status and SKEY is skipped:

**`Agent.hs:3384`:**
```haskell
status = if isJust sndKeys_ then Secured else New
```

### Conclusion

The sequence is strictly: **SKEY → CONF → HELLO**. SKEY is always on the initiator's original queue. The accepting party's reply queue is inherently under its own control and needs no SKEY from either party. The initiator authenticates on the reply queue using the `sndPrivateKey` generated during queue creation.
