# Errors

## Problems

- using numbers and strings to indicate errors (in protocol and in code) - ErrorType, AgentErrorType, TransportError
- re-using the same type in multiple contexts (with some constructors not applicable to all contexts) - ErrorType

## Error types

### ErrorType (Protocol.hs)

See haddock

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
  - SIMPLEX - connection is simplex, but operation requires another queue
- SMP ErrorType - forwarding SMP errors (SMPServerError) to the agent client
- BROKER e - SMP server errors
  - RESPONSE ErrorType - invalid SMP server response
  - UNEXPECTED - unexpected response
  - NETWORK - network TCP connection error
  - TRANSPORT TransportError -- handshake or other transport error
  - TIMEOUT - command response timeout
- AGENT e - errors of other agents
  - A_MESSAGE - SMP message failed to parse
  - A_PROHIBITED - SMP message is prohibited with the current queue status
  - A_ENCRYPTION - cannot RSA/AES-decrypt or parse decrypted header
  - A_SIGNATURE - invalid RSA signature
- INTERNAL ByteString - agent implementation or dependency error

### SMPClientError (Client.hs)

see haddock

### StoreError (Agent/Store.hs)

- SEInternal ByteString - signals exceptions in store actions.
- SEConnNotFound - connection alias not found (or both queues absent).
- SEConnDuplicate - connection alias already used.
- SEBadConnType ConnType - wrong connection type, e.g. "send" connection when "receive" or "duplex" is expected, or vice versa. `updateRcvConnWithSndQueue` and `updateSndConnWithRcvQueue` do not allow duplex connections - they would also return this error.
- SEBadQueueStatus - the intention was to pass current expected queue status in methods, as we always know what it should be at any stage of the protocol, and in case it does not match use this error. **Currently not used**.
- SENotImplemented - used in `getMsg` that is not implemented/used.

### CryptoError (Crypto.hs)

- RSAEncryptError R.Error - RSA encryption error
- RSADecryptError R.Error - RSA decryption error
- RSASignError R.Error - RSA signature error
- AESCipherError CE.CryptoError - AES initialization error
- CryptoIVError - IV generation error
- AESDecryptError - AES decryption error
- CryptoLargeMsgError - message does not fit in SMP block
- CryptoHeaderError String - failure parsing RSA-encrypted message header

### TransportError (Transport.hs)

  - TEBadBlock - error parsing block
  - TEEncrypt - block encryption error
  - TEDecrypt - block decryption error
  - TEHandshake HandshakeError

### HandshakeError (Transport.hs)

  - ENCRYPT - encryption error
  - DECRYPT - decryption error
  - VERSION - error parsing protocol version
  - RSA_KEY - error parsing RSA key
  - AES_KEYS - error parsing AES keys
  - BAD_HASH - not matching RSA key hash
  - MAJOR_VERSION - lower agent version than protocol version
  - TERMINATED - transport terminated
