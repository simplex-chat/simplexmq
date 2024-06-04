# Relay metadata and SimpleX network decentralization

## Problem

Currently, the clients configure/choose which servers to use, but they cannot see who operates them, in which geography and hosting provider, what is the server source code (in case it was modified from the reference implementation we provide) and also any administrative and feedback contacts.

Further, we currently use simplex.chat domain to host group links, and as diversity of the groups grows it is beginning to require managing feedback from the users about groups. It is important that this feedback is directed to relay owners and not to us, in case they are not our relays, as we are simply providing software here.

We also need to make it much easier to access administrative actions - e.g., if the relay owner wants to block some address based on the feedback, they should be able to do so effectively. While freedom of speech of users is important the autonomy and sovereignty of relay operators allowing them to decide what they want or don't want to host, irrespective of the reasons, is as important - public relays constitute a public space rather than a service, and while there is no authentication or authorization required to use them, the relay owners should be able to decide their conditions and limitations of use, as is the case for any public space.

## Why it is important

1. We are building network and not a service, so contrary to the traditional approach when service collects users metadata and conceals its own, it appears important to do the opposite - expose all relay metadata that may have any effect on users privacy and security and provide access to this metadata with the minimal friction, via the app UI.
2. We need to remove the only remaining bit of centralization - using simplex.chat website to show the QR code and help new users onboarding - this role can be delegated to the relays.
3. We need to make it easy for the users to submit feedback and to the relay operators to manage that feedback. That includes ourselves, as relay operators, and also any other person or organization that operates public relays.
4. It is important to stress the requirement of AGPLv3 license to provide access to the source code to the relay users, as any code modifications might undermine user privacy and security and must be made transparent to the relay users.

While this document is not the end of the journey to decentralize the network, it's an important first step.

## Proposed solution

The proposed solution consists of two parts:

- communicate server metadata via protocol, so it can be observed by the clients.
- create home page for the relays, with all the same metadata.
- create invitation and address links in the same domain name as the relay.

The latter point is important so it is clear to the users who operates and owns the relay and where the access point to the content or group is hosted. Even though simplex.chat domain is never accessed by the app, and the meaningful part of the address is never sent to the page hosting server, it creates an impression of centralization, and some dependency on simplex.chat domain for anything other that showing the link QR code.

Moving invitation links to the domain of the relay (primary relay, in case the link has redundancy) will both clarify relay ownership, solve the incorrect mis-perception of centralization, remove the dependency on simplex-chat domain without any user effort, and provides the means to submit content complaints to the relay operators (should they wish to receive them, which seems reasonable for large public relays, but may be unnecessary for private relays where unidentified parties cannot create links).

## Solution details

Extend server INI file with information section:

```
[INFORMATION]
# Please note that under AGPLv3 license conditions you MUST make
# any source code modifications available to the end users of the server.
# LICENSE: https://github.com/simplex-chat/simplexmq/blob/stable/LICENSE
# Not doing so would constitute a license violation.
# Declaring an incorrect information here amounts to a fraud.
# The license holders reserve the right to prosecute missing or incorrect
# information about the server source code to the fullest extent permitted by the law.
# The server will show warning on start if this field is absent
# and will not launch from v6.0 until this field is added.
# If any other information field is present, source code property also MUST be present.
source_code: https://github.com/simplex-chat/simplexmq

# Declaring all below information is optional, any of these fields can be omitted.
# Declaring an incorrect information here would amount to a fraud.

# We should split this document to the model one, where specific parameters will be external to the document,
# and specific to us, so that relay operators can adopt our recommended policy and publish any amendments separately.
usage_conditions: https://github.com/simplex-chat/simplex-chat/blob/_archived-ep/ios-file-provider/PRIVACY.md
# condition_amendments: link

server_country: SE
operator: SimpleX Chat Ltd.
operator_country: GB # operator country
website: https://simplex.chat
admin_simplex: administrative SimpleX address
admin_email: chat@simplex.chat
admin_pgp: PGP key
complaints_simplex: SimpleX address for feedback, comments and complaints
complaints_email: complaints@simplex.chat
complaints_pgp: PGP key
hosting: Linode / Akamai Inc.
hosting_country: US
```

Server home page would show whether queue creation is allowed and/or password protected, server retention policy (e.g., preserve messages on restart or not, and persist connections or not).

Server queue address/contact pages will optionally, provide the UI to submit feedback, comments and complaints directly from the web page (not an MVP, initially we would simply show addresses for feedback, and, probably, create link that opens in the app with pre-populated message, and we could also use this addresses defined in server meta-data to submit feedback from inside of the app - it's also out of MVP scope).

If server is available on .onion address, the web pages would show "open via .onion" in Tor browser.

Extend server handshake header with these information fields:

```haskell
data ServerHandshake = ServerHandshake
  { smpVersionRange :: VersionRangeSMP,
    sessionId :: SessionId,
    -- pub key to agree shared secrets for command authorization and entity ID encryption.
    authPubKey :: Maybe (X.CertificateChain, X.SignedExact X.PubKey),
    -- ^^ existing fields
    -- vv new field that will be sent as length-prefixed JSON in the handshake
    information :: Maybe ServerInformation
  }

data ServerInformation = ServerInformation
  { config :: ServerPublicConfig,
    info :: ServerPublicInfo
  }

-- based on server configuration
data ServerPublicConfig = ServerPublicConfig
  { persistence :: SMPServerPersistenceMode,
    messageExpiration :: Int,
    statsEnabled :: Bool,
    newQueuesAllowed :: Bool,
    basicAuthEnabled :: Bool -- server is private if enabled
  }

-- based on INFORMATION section of INI file
data ServerPublicInfo = ServerPublicInfo
  { sourceCode :: Text, -- note that this property is not optional, in line with AGPLv3 license
    conditions :: Maybe ServerConditions,
    operator :: Maybe Entity,
    website :: Maybe Text,
    adminContacts :: Maybe ServerContactAddress,
    complaintsContacts :: Maybe ServerContactAddress,
    hosting :: Maybe Entity,
    serverCountry :: Maybe Text
  }

data ServerPersistenceMode = SMPMemoryOnly | SPMQueues | SPMQueuesMessages

data ServerConditions = ServerConditions {conditions :: Text, amendments :: Maybe Text}

data Entity = Entity {name :: Text, country :: Maybe Text}

data ServerContactAddress = ServerContactAddress
  { simplex :: Maybe Text,
    email :: Maybe Text, -- it is recommended that it matches DNS email address, if either is present
    pgp :: Maybe Text
  }
```

This extended server information will be stored in the chat database every time it changes and shown in the UI of the server configuration.
