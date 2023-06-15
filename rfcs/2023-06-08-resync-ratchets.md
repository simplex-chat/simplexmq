# Re-sync encryption ratchets

## Problem

See https://github.com/simplex-chat/simplexmq/pull/743/files for problem and high-level solution.

## Implementation

### Ratchet re-synchronization

Message decryption happens in `agentClientMsg`, in `agentRatchetDecrypt`, which can return decryption result or error. Decryption error can be differentiated in `agentClientMsg` result pattern match, in Left cases, where we already differentiate duplicate error (`AGENT A_DUPLICATE`).

Question: On which decryption errors should ratchet re-synchronization start?

Possibly on any `AGENT A_CRYPTO` error. Definitely on `RATCHET_HEADER`, TBC other. See `cryptoError :: C.CryptoError -> AgentErrorType` for conversion from decryption errors to `A_CRYPTO` or other agent errors. We're only interested in crypto errors, as other are either other client implementation errors, internal errors, or already processed duplicate error.

Question: How to start ratchet re-synchronization?

State whether the ratchet re-synchronization is in progress should be tracked in database via `connections` table new `ratchet_resync` flag (?).

- Generate new keys.
- Update database connection state.
  - Set `ratchet_resync` to True.
  - Delete old ratchet from `ratchets` (is it safe?), create new ratchet.
- Send "EKEY" message, see link above.
- Notify client - `RESYNC` event.
  - On `RESYNC` chat should create chat item, and reset connection verification.

EKEY message should be on the level of AgentMsgEnvelope (?) - encrypted with queue level e2e encryption, but not with connection level e2e encryption (since ratchet de-synchronized). Will call EKEY as AgentResynchronization.

Unclear in previous rfc:

- Why `EREADY` is needed?
- It seems to be getting wrong that second ratchet key is sent in a ratchet e2e encrypted response (otherwise how would the first party get the second public key to compute shared secret), so `EREPLY` also seems unnecessary. Only auxiliary data in confirmation seems to be encrypted with ratchet e2e. Difference between initial handshake and re-sync is that first ratchet key is sent out-of-band in initial handshake, though since it's already a trusted channel it shouldn't matter.

``` haskell
data AgentMsgEnvelope
  = ...
  | AgentResynchronization
      { agentVersion :: Version,
        e2eEncryptionResync :: E2ERatchetParams 'C.X448
      }
```

On receiving `AgentResynchronization`, if the receiving client hasn't started the ratchet re-synchronization itself (check `ratchet_resync`), it should:

- Generate new keys and compute new shared secret.
- Update database connection state.
  - Delete old ratchet from `ratchets`, create new ratchet.
- Reply with its own `AgentResynchronization`.
- Notify client with `RESYNC` (`RESYNC_COMPLETE`?).

Should it be different / parameterized event after computing shared secret? E.g. `RESYNC_COMPLETE`. It would allow to distinguish: start and end of re-synchronization for initiating party; chat item direction - `RESYNC`/`RESYNC_STARTED` is snd, `RESYNC_COMPLETE` is rcv.

On receiving `AgentResynchronization`, if the receiving client started re-sync:

- Compute new shared secret.
- Update database connection state.
  - Set `ratchet_resync` to False.
  - Update ratchet.
- Notify client with `RESYNC_COMPLETE`.

### Skipped messages

Options:

1. Ignore skipped messages.
2. Stop sending new messages while connection re-synchronizes (can use `ratchet_resync` flag).
  - Initiator shouldn't send new messages until receives `AgentResynchronization` from second party.
  - Second party knows new shared secret immediately after processing first `AgentResynchronization`, so it's not necessary to limit?
3. 2 + Re-send skipped messages first.
  - Add `last_external_snd_msg_id` to `AgentResynchronization`? + see link above
4. Re-send only messages after the latest ratchet step. *

It may be okay to ignore skipped messages, or at most implement option 2, as ratchet de-synchronization is usually caused by misuse (human error) - the most common cause of ratchet de-sync seems to be sending and receiving messages after running agent with old database backup. In this case user has already seen most skipped messages, and it can be expected to not have them after switching to an old backup. So in this case the only "really skipped" messages are those that were sent during the latest ratchet step and failed to decrypt, triggering ratchet re-sync (* another option is to only re-send those).

Besides, depending on time of backup there may be an arbitrary large number of skipped messages, which may consume a lot of traffic and may halt delivery of up-to-date messages for some time.

It may be better to have request for repeat delivery as a separate feature, that can be requested in necessary contexts - for example for group stability.

Can servers delivery failure lead to de-sync? If message is lost on server and never delivered, ratchet wouldn't advance, so there's no room for de-sync? If yes, re-evaluate.
