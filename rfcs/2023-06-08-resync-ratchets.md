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

After agent has both keys, it initiates new ratchet depending on keys ordering. The agent that sent the lower key should use `initRcvRatchet` function, the agent that sent the greater key should use `initSndRatchet` (or vice versa - but they should deterministically choose different sides).

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
  | RRAgreedSnd
  | RRAgreedRcv
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
> Parameterized `RRESYNC` allows to distinguish: start and end of re-synchronization for initiating party; chat item direction - `RRESYNC RRStarted` is snd, `RRESYNC RRAgreedSnd/Rcv` and `RRESYNC RRComplete` are rcv (`RRESYNC RRAgreedSnd/Rcv` chat item could be omitted).

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

- Generate new keys and compute new shared secret, initializing ratchet based on keys comparison.
- Update database connection state.
  - Set `ratchet_resync_state` to `RRAgreedSnd/Rcv` (depending on whether ratchet was initialized as sending or receiving).
  - Delete old ratchet from `ratchets`, create new ratchet.
- Reply with its own `AgentRatchetKey`.
- Notify client with `RRESYNC RRAgreedSnd/Rcv`.
- If ratchet was initialized as sending, send `EREADY` message, notifying other agent ratchet is re-synced.

New agent message:

```haskell
data AMessage
  = ...
  | -- ratchet re-synchronization is complete, with last decrypted sender message id
    EREADY PrevExternalSndId
```

On receiving `AgentRatchetKey`, if the receiving client started re-sync:

- Compute new shared secret, initializing ratchet based on keys comparison.
- Update database connection state.
  - Set `ratchet_resync_state` to `RRAgreedSnd/Rcv` (depending on whether ratchet was initialized as sending or receiving).
  - Update ratchet.
- Notify client with `RRESYNC RRAgreedSnd/Rcv`.
- If ratchet was initialized as sending, send `EREADY` message.

After agent receives `EREADY` (or any other message that successfully decrypts):

- Reset `ratchet_resync_state` to NULL.
- Notify client with `RRESYNC RRComplete`.
- If ratchet was initialized as receiving, send reply `EREADY` message.

### State transitions

For initiating party:

```
    +------------+
    | Ratchet ok |
    +------------+
          |
          | message received, decryption error
   * ---->|-----------------------------------+
          |                                   |
          V          new (clarifying)         V
  +-----------------+     error      +------------------+
  | Re-sync allowed |--------------->| Re-sync required |
  +-----------------+                +------------------+
          |                                   |
          |-----------------------------------|
          |                                   | alternative - message received,
          | re-sync started by client         | successfully decrypted
          V                                   V
  +-----------------+                   +------------+
  | Re-sync started |                   | Ratchet ok |
  +-----------------+                   +------------+
          |
          | other party replied with new ratchet key
          V
  +----------------+
  | Re-sync agreed |----> * message received, decryption error
  |   snd / rcv    |        (should remember agreed state for reply EREADY?)
  +----------------+
          |
          | message received, successfully decrypted
          | (can be, but not necessarily, EREADY)
          V
    +------------+
    | Ratchet ok |
    +------------+
```

For replying party:

```
    +------------+
    | Ratchet ok |
    +------------+
          |
          | other party sent new ratchet key
          V
  +----------------+
  | Re-sync agreed |
  |   snd / rcv    |
  +----------------+
          |
          | message received, successfully decrypted
          | (can be, but not necessarily, EREADY)
          V
    +------------+
    | Ratchet ok |
    +------------+
```

### Ratchet state model

#### 2 state variables

Above we considered model with separate de-sync and re-sync state.

| Desync \ Resync      | Nothing | RRStarted | RRAgreedSnd | RRAgreedRcv |
| ---                  |  :---:  |   :---:   |    :---:    |    :---:    |
| **Nothing**          | 1       | 3         | 4           | 4           |
| **RDResyncAllowed**  | 2       |           | 5           | 5           |
| **RDResyncRequired** | 2       |           | 5           | 5           |

1: Ratchet is ok.

2: Re-sync diagnosed, not in progress.

3: Rs-sync started, diagnosing de-sync is prohibited.

4: Re-sync agreed.

5: Re-sync agreed, new de-sync is diagnosed.

Combination 5 is possible in case de-sync was diagnosed before message that could be decrypted is received, for example if `EREADY` failed to deliver and no other decryptable message followed. We shouldn't prohibit diagnosing de-sync in this case, because agent may never exit "Agreed" state (if new decryptable message is never received). We also shouldn't overwrite/forget state of re-sync, even if we diagnose new possible de-sync, because if the decryptable `EREADY` is received and ratchet is in `RRAgreedRcv` state, it should respond with reply `EREADY`.

Some combinations should be impossible:

  - `RDResyncAllowed` with `RRStarted`.

  - `RDResyncRequired` with `RRStarted`.

`RDHealed` is equivalent to `Nothing` and only used for `RDESYNC` event, `Maybe RatchetDesyncState` can be replaced with `RatchetDesyncState`, with single new constructor `RDNoDesync` replacing `Nothing` and `RDHealed`.

`RRComplete` is equivalent to `Nothing` and only used for `RRESYNC` event, `Maybe RatchetResyncState` can be replaced with `RatchetResyncState`, with single new constructor `RDNoResync` replacing `Nothing` and `RRComplete`.

#### Single state variable

Another option is two have a single state variable describing ratchet.

```haskell
data RatchetState
  = RSOk
  | RSResyncAllowed
  | RSResyncRequired
  | RSResyncStarted
  | RRResyncAgreedSnd
  | RRResyncAgreedRcv

-- When `resyncConnectionRatchet` is not prohibited. Can override with `force`.
-- Currently we check:`(isJust ratchetDesyncState || force) && ratchetResyncState /= Just RRStarted`.
resyncConnectionRatchetAllowed :: RatchetState -> Bool
resyncConnectionRatchetAllowed = \case
  RSOk -> False
  RSResyncAllowed -> True
  RSResyncRequired -> True
  RSResyncStarted -> False -- `force` shouldn't override
  RRResyncAgreedSnd -> False
  RRResyncAgreedRcv -> False

-- When we register and notify about ratchet de-synchronization.
-- Currently we check: `(isNothing ratchetDesyncState && ratchetResyncState /= Just RRStarted)`.
-- We should also allow to update from Allowed to Required.
shouldNotifyRDESYNC :: RatchetState -> Bool
shouldNotifyRDESYNC = \case
  RSOk -> True
  RSResyncAllowed -> False -- only if new error implies Required
  RSResyncRequired -> False
  RSResyncStarted -> False
  RRResyncAgreedSnd -> True
  RRResyncAgreedRcv -> True

-- When we prohibit connection switch, for `checkRatchetDesync`.
-- Currently we check: `(ratchetDesyncState == Just RDResyncRequired || ratchetResyncState == Just RRStarted)`
-- Also use in `runSmpQueueMsgDelivery` to pause delivery?
ratchetDesynced :: RatchetState -> Bool
ratchetDesynced = \case
  RSOk -> False
  RSResyncAllowed -> False
  RSResyncRequired -> True
  RSResyncStarted -> True
  RRResyncAgreedSnd -> False
  RRResyncAgreedRcv -> False
```

Having a single state variable limits differentiation described for combination 5 in matrix. It also limits possible differentiations in client between events when ratchet is healed on its own, and when ratchet re-sync is completed after agents negotiation. Overall, since matrix is not very sparse and allows for more fine-grained decision-making, having separate state variables for de-sync and re-sync seems preferred.

#### Single state variable simplified (final version)

```haskell
data RatchetSyncState
  = RSOk
  | RSAllowed
  | RSRequired
  | RSStarted
  | RSAgreed

-- event
RSYNC :: RatchetSyncState -> ConnectionStats -> ACommand Agent AEConn`

-- ConnectionStats field
ratchetSyncState :: RatchetSyncState
```

Updated design decisions:

1. Single constructor for "Agreed" state. Differentiating `RRResyncAgreedSnd` and `RRResyncAgreedRcv` allowed for easier processing of `EREADY` by helping to determine whether reply `EREADY` has to be sent. However, it duplicated information already present in ratchet's state, and can be instead worked around by remembering and analyzing ratchet state pre decryption.

2. Prohibit transition from "Agreed" state to "Desync" states. This would make possible edge-cases that leave ratchet in de-synchronized state without ability to progress (e.g. failed delivery of `AgentRatchetKey`), but would simplify state machine by removing dedicated "Desync" variable. Besides, there's still a recovery way with a `force` option.

3. Treat "Agreed" as unfinished state - prohibit new messages to be enqueued, etc. Reception of any decryptable message transitions ratchet to "Ok" state.

Possible improvements:

- Repeatedly triggering re-synchronization while in "Started"/"Agreed" state re-sends same keys and EREADY.
- Cooldown period, during which repeat re-synchronization is prohibited.

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
