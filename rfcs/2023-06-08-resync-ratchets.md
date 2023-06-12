# Re-sync encryption ratchets

## Problem

See https://github.com/simplex-chat/simplexmq/pull/743/files for problem and high-level solution.

## Implementation

Message decryption happens in `agentClientMsg`, in `agentRatchetDecrypt`, which can return decryption result or error. Decryption error can be differentiated in `agentClientMsg` result pattern match, in Left cases, where we already differentiate duplicate error (`AGENT A_DUPLICATE`).

Question: On which decryption errors should ratchet re-synchronization start?

Possibly on any `AGENT A_CRYPTO` error. Definitely on `RATCHET_HEADER`, TBC other. See `cryptoError :: C.CryptoError -> AgentErrorType` for conversion from decryption errors to `A_CRYPTO` or other agent errors. We're only interested in crypto errors, as other are either other client implementation errors, internal errors, or already processed duplicate error.

Question: How to start ratchet re-synchronization?

- Generate new key.
- Send "EKEY" message, see link above.
- Update database connection state.

EKEY message should be on the level of AgentMsgEnvelope (?) - encrypted with queue level e2e encryption, but not with connection level e2e encryption (since ratchet de-synchronized). Will call EKEY as AgentResynchronization.

``` haskell
data AgentMsgEnvelope
  = ...
  | AgentResynchronization
      { agentVersion :: Version,
        e2eEncryptionResync :: E2ERatchetParams 'C.X448
      }
```

On receiving `AgentResynchronization`, if the receiving client hasn't started the ratchet re-synchronization itself, it should reply with its own `AgentResynchronization`. State whether the ratchet resynchronization was started should be tracked in database, possibly on `connections` table.

Also:
  - delete old ratchet?
