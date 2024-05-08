# Migrating existing connections to post-quantum double ratchet algorithm

## Problem

Post-quantum variant of double ratchet algorithm represents an almost full-stack change affecting all parts of the protocol stack except client-server protocol (SMP):
- double-ratchet end-to-end encryption: different encoding (additional large keys require byte-strings larger than 255 bytes with 2-byte length prefixes) and larger message headers (increased by ~2200 bytes).
- agent-agent protocol: a smaller maximum message size to accomodate larger headers and to fit in 16kb blocks, reduced by ~2200 bytes for the messages and by almost ~4000 bytes for connection information.
- chat protocol: also a smaller message size compensated by zstd comression of JSON messages.

We want the versioning that achieves these objectives:
- all changes in all protocol layers happen at the same time, when both clients support it.
- ability to downgrade the clients to the previous version without losing connection.
- ability to opt-in into this functionality via "experimental" feature toggle, that enables post-quantum encryption in connections when both contacts enable this toggle.

To have ability to downgrade the clients we have two options:
- roll-out this functionality in two stages: 1) roll-out clients support but do not enable the new version, and then 2) upgrade client version. The problem here is that the clients won't be able to opt-in into this experiment.
- make offered range dependent on experimental feature being enabled. Currently we have an option to enable PQ encryption in agent API, and this option can be used as a proxy to maxium supported protocol version - if the option is passed, it can be seen as an indication that higher version range (or version) should offered (or accepted).

## Solution

Currently ratchet state stores version range. It's unclear what was the intended semantics of that version range - it simply stores the offered/supported version range at the time ratchet was initialised, but only a high bound is used to send in message headers, and it is never upgraded. In JSON this range is encoded as tuple (an array of two elements in JSON).

We could continue using this range with the meaning of the lower bound to be "currently used ratchet version" and the meaning of higher boundary to be "maximum supported ratchet version". We could also use the version communicated in message headers to upgrade ratchet version, with the condition that upgrade should only happen if both sides want it. Currently it's defined by pqEnableKEM property in ratchet state. We could also make it more explicit by defining maximum version to which ratchet should upgrade. Given that irreversible upgrades are not very common, it is probably ok to keep it implicit.

We can define a better type than VersionRange to reflect semantics of the range in ratchet (current/max supported range), but for backward compatibility it needs to be encoded in the same way as now.

To summarize, the proposed solution for ratchet versioning is:
- define ratchet versions as new type to include current and maximum allowed versions, where maximum allowed will be either the same or lower than maximum supported based on PQ option (in 5.6), and in 5.7 it will be changed to maximum supported, so version starts upgrading independently from PQ being enabled.
- make encodings in ratchet depend on current version (in curent code it depends on max version).
- include max allowed in message header.
- upgrade current if in range on each new message if less than max and higher than current (same as we do for connections).
- increase max allowed once PQ is enabled (only in 5.6). Make max allowed the same as max supported (global constant).

```haskell
data RatchetVR = RatchetVR
  { currentVersion :: Version,
    maxAllowedVersion :: Version
  }

instance ToJSON RatchetVR where
  toEncoding (RatchetVR v1 v2) = toEncoding (v1, v2)
  toJSON (RatchetVR v1 v2) = toJSON (v1, v2)

instance FromJSON RatchetVR where
  parseJSON v = do
    -- this also verifies that v2 > v1 (although we could remove JSON instances for VersionRange)
    VersionRange v1 v2 <- parseJSON v
    pure $ RatchetVR v1 v2
```

For connections, we could also make version used for the purposes of encoding dependent on the PQ being enabled, and version for decoding taken from message header, but then we'd have to not only upgrade ratchets but the connection as well every time PQ mode changes.

Another suggestion to ensure that correct version range is used in correct contexts could be:
- using different newtypes for different version ranges.
- define generic type class for version aware encoding that would also accept only specific type class for the version to use the correct range. This may be justified as there will be several version-aware encodings, and not just the protocol as now.

```haskell
class Ord v => EncodingV v a where
  {-# MINIMAL smpEncodeV, (smpDecodeV | smpVP) #-}
  smpEncodeV :: v -> a -> ByteString
  -- default decode uses parser
  smpDecodeV :: v -> ByteString -> Either String a
  smpDecodeV = parseAll . smpVP
  -- default parser decodes from length-specified bytestring
  smpVP :: v -> Parser a
  smpVP v = smpDecodeV v <$?> smpP
```

The version will be passed from currently agreed version, it may only change when message is received, not when message is sent. The version will not be extracted from the encoding itself as it happens now in ratchet encodings.

## Various options how the problem can be simplified

1. Do not support connection downgrade once both devices upgraded. If applied to all existing connections then it is a bad option, as it would disrupt some important conversations.

2. Do not provide ability to opt-in into PQ encryption until v5.7 where it will be rolled out automatically. That is also suboptimal, as it won't allow announcing technology design and have testing outside of the team devices.

3. The logic explained above where connection upgrade and downgrade is possible and applied to all existing connections if both parties consent to it. There are these important downsides:
  - complexity of this logic
  - regression risks when this logic is removed.
  - some non-coordinated upgrades of existing, potentially important conversations, simply because two users opt-in into the experiment without any expectation that another side also opts-in.

4. Apply upgrade/downgrade logic and enable PQ encryption as opt-in, based on the toggle in the UX, only for the new connections. This seems the least risky, and also simpler than option 3, as it would only apply to the new connections, and both users will have to enable experimental toggle prior to connecting.

Option 4 seems the best trade-off, and has these sub-options regarding where it is controlled:
a) in chat based on connection flag. Chat will pass PQ options only to connections that were created when experimental option was enabled.
b) in agent - there will be additional logic to ignore PQ option for existing connections.
c) both in chat and in agent.

Option 4a seems better, as it would:
- simplify agent code
- minimise required changes when releasing v5.7 (as we do want that all direct and small groups connections migrate to PQ encryption at the time, without any toggles)
- allow tests for connection upgrade in the currect code.
