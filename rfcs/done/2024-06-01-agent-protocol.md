# Evolving agent API

## Problem

Historically, agent API started as a TCP protocol with encoding. We do not use the actual protocol and maintaining the encoding complicates the evolution of the API.

Currently, I was trying to add ERRS event to combine multiple subscription errors into one to prevent overloading the UI with processing multiple subscription errors (e.g.):

```haskell
ERRS :: (ConnId, AgentErrorType) -> ACommand Agent AEConn
```

This constructor is not possible to encode/parse in a sensible way other than including lengths of errors.

## Proposal

Remove commands type and encodings for commands and events.

Only keep encodings for the commands that are saved to the database: NEW, JOIN, LET, ACK, SWCH, DEL (this one is no longer used but needs to be supported for backwards compatibility).
