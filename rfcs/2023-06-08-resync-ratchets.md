# Re-sync encryption ratchets

## Problem

See https://github.com/simplex-chat/simplexmq/pull/743/files for problem and high-level solution.

## Implementation

### Diagnosing ratchet de-synchronization

Message decryption happens in `agentClientMsg`, in `agentRatchetDecrypt`, which can return decryption result or error. Decryption error can be differentiated in `agentClientMsg` result pattern match, in Left cases, where we already differentiate duplicate error (`AGENT A_DUPLICATE`).

Question: Which decryption errors can be diagnosed as ratchet de-synchronization?

Possibly any `AGENT A_CRYPTO` error. Definitely on `RATCHET_HEADER`, TBC other. See `cryptoError :: C.CryptoError -> AgentErrorType` for conversion from decryption errors to `A_CRYPTO` or other agent errors. We're only interested in crypto errors, as other are either other client implementation errors, internal errors, or already processed duplicate error.

Proposed classification of crypto errors, based on `AgentCryptoError`:

`DECRYPT_AES` -> re-sync allowed (recommended/required?)

`DECRYPT_CB` -> re-sync allowed (recommended/required?)

`RATCHET_HEADER` -> **re-sync required**

`RATCHET_EARLIER` -> re-sync allowed

`RATCHET_SKIPPED` -> **re-sync required**

Ratchet re-synchronization could be started automatically on diagnosing de-synchronization, based on these errors. As a potentially dangerous feature (e.g., implementation error could lead to infinite re-sync loop causing large traffic consumption), initially it will be available via agent functional api for client to call. Ratchet de-synchronization will instead produce an event prompting client to re-synchronize.

Diagnosing possible ratchet de-synchronization also will be recorded as connection state - `ratchet_desync_state` field in `connections` table. Client should be prohibited to start ratchet re-synchronization unless `ratchet_desync_state` is set.

Event should not be repeated for following received messages that can't be decrypted - based on `ratchet_desync_state`. If a received message can be decrypted, `ratchet_desync_state` should be set to NULL and a new event sent, indicating ratchet has healed.

New event - `RDESYNC :: RatchetDesyncState -> ConnectionStats -> ACommand Agent AEConn`

```haskell
data RatchetDesyncState
  = RDResyncAllowed
  | RDResyncRequired
  | RDHealed
```

New field should be added to `ConnectionStats` - `ratchetDesyncState :: Maybe RatchetDesyncState`, based on `ratchet_desync_state`.

> On `RDESYNC` events chat should create chat item, prompting ratchet re-synchronization or notifying it has healed.
> If connection has diagnosed ratchet de-sync, chat item should have a button to start ratchet re-sync.
> We'd have to get `ConnectionStats` on chat level for this instead of chat info.
> This wouldn't work for groups. One option is to add `ConnectionStats` to `GroupMember` type and update on events.
> Same could be done for `Contact` then.

To consider - allow to start ratchet re-synchronization at any time regardless of this field as an experimental feature. In chat it could be behind "Developer tools" + additional "Experimental" toggle. Agent api would have `force :: Bool` as parameter, allowing to bypass `ratchet_desync_state`. Should `ratchet_resync_state` (see below) still be honored in this case?

### Re-synchronization process

\*\*\*\*\*

Basic idea is the following:

Both agents send new ratchet keys and compute a new shared secret. Agent that starts re-synchronization should record this fact in the connection state. Agent that receives a new key should respond with a key of its own, unless it has recorded that it itself started re-synchronization in the connection state.

It can happen that both agents start re-synchronizing simultaneously. In this case they both would record it in the connection state and would not respond with a new message - instead they would use each other's already sent keys.

Agent has both keys if:

- It initiates with the first key, and then receives the second key;
- It receives the first key and then generates its own in response.

After agent has both keys, it initiates new ratchet depending on keys' hashes. The agent that sent the key with the lower hash should use `x3dhRcv` function, the agent that sent the key with the greater hash should use `x3dhSnd` (or vice versa - but they should deterministically choose different sides).

\*\*\*\*\*

State whether the ratchet re-synchronization is in progress should be tracked in database via `connections` table new `ratchet_resync_state` field.

New functional api:

```haskell
resyncConnectionRatchet :: AgentErrorMonad m => AgentClient -> ConnId -> m ConnectionStats
```

or if we want to allow re-synchronizing ratchet at any time even if de-synchronization wasn't diagnosed:

```haskell
resyncConnectionRatchet :: AgentErrorMonad m => AgentClient -> ConnId -> Bool -> m ConnectionStats
resyncConnectionRatchet c connId force = ...
```

Possibly client command?

``` haskell
data ACommand (p :: AParty) (e :: AEntity) where
  ...
  RESYNC_RATCHET :: Bool -> ACommand Client AEConn
```

New event - `RRESYNC :: RatchetResyncState -> ConnectionStats -> ACommand Agent AEConn`

```haskell
data RatchetResyncState
  = RRStarted
  | RRAgreed
  | RRComplete
```

New `ConnectionStats` field - `ratchetResyncState :: Maybe RatchetResyncState`.

When called, it should:

- Generate new keys.
- Update database connection state.
  - Set `ratchet_desync_state` to NULL.
  - Set `ratchet_resync_state` to `RRStarted`.
  - Delete old ratchet from `ratchets` (is it safe?), create new ratchet.
- Send `AgentRatchetKey` message.
- Return updated `ConnectionStats` to client.

> On `RRESYNC` events chat should create chat item, and reset connection verification.
> Parameterized `RRESYNC` allows to distinguish: start and end of re-synchronization for initiating party; chat item direction - `RRESYNC RRStarted` is snd, `RRESYNC RRAgreed` and `RRESYNC RRComplete` are rcv (`RRESYNC RRAgreed` chat item could be omitted).

AgentRatchetKey is a new message on the level of AgentMsgEnvelope - encrypted with queue level e2e encryption, but not with connection level e2e encryption (since ratchet de-synchronized).

```haskell
data AgentMsgEnvelope
  = ...
  | AgentRatchetKey
      { agentVersion :: Version,
        e2eEncryption :: E2ERatchetParams 'C.X448,
        info :: ByteString -- for extension
      }
```

On receiving `AgentRatchetKey`, if the receiving client hasn't started the ratchet re-synchronization itself (check `ratchet_resync_state`), it should:

- Generate new keys and compute new shared secret, initializing ratchet based on key hashes comparison.
- Update database connection state.
  - Set `ratchet_resync_state` to `RRAgreed`.
  - Delete old ratchet from `ratchets`, create new ratchet.
- Reply with its own `AgentRatchetKey`.
- Notify client with `RRESYNC RRAgreed`.
- Send `EREADY` message, notifying other agent ratchet is re-synced.

New agent message:

```haskell
data AMessage
  = ...
  | -- ratchet re-synchronization is complete, with last decrypted sender message id
    EREADY PrevExternalSndId
```

On receiving `AgentRatchetKey`, if the receiving client started re-sync:

- Compute new shared secret, initializing ratchet based on key hashes comparison.
- Update database connection state.
  - Set `ratchet_resync_state` to `RRAgreed`.
  - Update ratchet.
- Notify client with `RRESYNC RRAgreed`.
- Send `EREADY` message.

After agent receives `EREADY` (or any other message that successfully decrypts):

- Reset `ratchet_resync_state` to NULL.
- Notify client with `RRESYNC RRComplete`.

### Skipped messages

Options:

1. Ignore skipped messages.
2. Stop sending new messages while connection re-synchronizes (can use `ratchet_resync_state`).

- Initiator shouldn't send new messages until receives `AgentRatchetKey` from second party.
- Second party knows new shared secret immediately after processing first `AgentRatchetKey`, so it's not necessary to limit?

3. 2 + Re-send skipped messages first.

- Add `last_external_snd_msg_id` to `AgentRatchetKey`? + see link above

4. Re-send only messages after the latest ratchet step. \*

It may be okay to ignore skipped messages, or at most implement option 2, as ratchet de-synchronization is usually caused by misuse (human error) - the most common cause of ratchet de-sync seems to be sending and receiving messages after running agent with old database backup. In this case user has already seen most skipped messages, and it can be expected to not have them after switching to an old backup. So in this case the only "really skipped" messages are those that were sent during the latest ratchet step and failed to decrypt, triggering ratchet re-sync (\* another option is to only re-send those).

Besides, depending on time of backup there may be an arbitrary large number of skipped messages, which may consume a lot of traffic and may halt delivery of up-to-date messages for some time.

It may be better to have request for repeat delivery as a separate feature, that can be requested in necessary contexts - for example for group stability.

Can servers delivery failure lead to de-sync? If message is lost on server and never delivered, ratchet wouldn't advance, so there's no room for de-sync? If yes, re-evaluate.
