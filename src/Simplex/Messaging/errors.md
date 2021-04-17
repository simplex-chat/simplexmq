# Errors

## Problems

- using numbers and strings to indicate errors (in protocol and in code) - ErrorType, AgentErrorType, TransportError
- re-using the same type in multiple contexts (with some constructors not applicable to all contexts) - ErrorType
- inconsistent error semantics (e.g. SENotFound and SEBadConnection used to indicate missing connection - TBC)
- unused constructors in error types
- unhandled constructors in error types
- store errors are not translated to meaningful errors (e.g. duplicate connection alias)

## Error types

### ErrorType (Protocol.hs)

- PROHIBITED - command is valid but not allowed in the current context:
  1. server response sent from client or vice versa
  2. acknowledging the message without message
- SYNTAX error - command is unknown or has invalid syntax, where `error` can be:
  - TRANSMISSION - incorrect transmission format or encoding
  - COMMAND - error parsing command
  - NO_AUTH - transmission has no required credentials (signature or queue ID)
  - HAS_AUTH - transmission has not allowed credentials
  - NO_QUEUE - transmission has not queue ID
- AUTH - command is not authorised (queue does not exist or signature verification failed).
- INTERNAL - internal server error.
- DUPLICATE_ - it is used internally to signal that the queue ID is already used. This is NOT used in the protocol, instead INTERNAL is sent to the client. It has to be removed.

### AgentErrorType (Agent/Transmission.hs)

Some of these errors are not correctly serialized/parsed - see line 322 in Agent/Transmission.hs

- CMD e - command or response error
  - PROHIBITED - server response sent as client command (and vice versa)
  - SYNTAX - command is unknown or has invalid syntax.
  - NO_CONN - connection is required in the command (and absent)
  - SIZE - incorrect message size of messages (when parsing SEND and MSG)
  - LARGE -- message does not fit SMP block
- CONN e - connection errors
  - UNKNOWN - connection alias not in database
  - DUPLICATE - connection alias already exists
  - SIMPLEX_RCV - operation requires send queue
  - SIMPLEX_SND - operation requires receive queue
- SMP ErrorType - forwarding SMP errors (SMPServerError) to the agent client
- BROKER e - SMP server errors
  - RESPONSE ErrorType - invalid SMP server response
  - QUEUE - queue in response is different from the queue in sent command
  - UNEXPECTED - unexpected response
  - NETWORK - network TCP connection error
  - TRANSPORT - handshake or other transport error
  - TIMEOUT - command response timeout
- AGENT e - errors of other agents
  - A_MESSAGE - SMP message failed to parse
  - A_PROHIBITED - SMP message is prohibited with the current queue status
- INTERNAL ByteString - agent implementation or dependency error

### SMPClientError (Client.hs)

- SMPServerError ErrorType - this is correctly parsed server ERR response. This error is forwarded to the agent client as `ERR SMP err`
- SMPResponseError ErrorType - this is invalid server response that failed to parse - forwarded to the client as `ERR BROKER RESPONSE`.
- SMPQueueIdError - queue ID in response is different from queue ID in the sent command (commands are correlated using sequential correlation ID) - forwarded to the client as `ERR BROKER QUEUE`.
- SMPUnexpectedResponse - different response from what is expected to a given command, e.g. server should respond `IDS` or `ERR` to `NEW` command, other responses would result in this error - forwarded to the client as `ERR BROKER UNEXPECTED`.
- SMPResponseTimeout - used for TCP connection and command response timeouts.
- SMPNetworkError - fails to establish TCP connection
- SMPTransportError - fails connection handshake or some other transport error
- SMPCryptoError RSA.Error - error when cryptographically "signing" the command returned by RSA primitives.

### StoreError (Agent/Store.hs)

- SEInternal ByteString - signals exceptions in store actions.
- SEConnNotFound - connection alias not found (or both queues absent).
- SEConnDuplicate - connection alias already used.
- SEBadConnType ConnType - wrong connection type, e.g. "send" connection when "receive" or "duplex" is expected, or vice versa. `updateRcvConnWithSndQueue` and `updateSndConnWithRcvQueue` do not allow duplex connections - they would also return this error.
- SEBadQueueStatus - the intention was to pass current expected queue status in methods, as we always know what it should be at any stage of the protocol, and in case it does not match use this error. **Currently not used**.
- SENotImplemented - used in `getMsg` that is not implemented/used.

### CryptoError (Crypto.hs)

- CryptoRSAError R.Error - RSA encryption/decryption error
- CryptoCipherError CE.CryptoError - AES initialization error
- CryptoIVError - IV generation error
- CryptoDecryptError - AES decryption error
- CryptoLargeMsgError - message does not fit in SMP block
- CryptoHeaderError String - failure parsing RSA-encrypted message header

### TransportError (Transport.hs)

- TransportCryptoError C.CryptoError - handshake (RSA) of transport decryption (AES) error
- TransportParsingError - error parsing transmission
- TransportHandshakeError String - should be probably enumerable constructor, currently we use strings
