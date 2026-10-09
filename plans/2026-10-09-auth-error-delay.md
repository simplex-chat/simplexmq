# Delayed AUTH error responses

## Decisions

- `ERR AUTH` responses to all commands except `LGET` are sent no earlier than the delay.
- Delayed response sets:

  | Source | Responses sent together | Delay counted from |
  |---|---|---|
  | `receive`, failed verification | verification and parsing errors of one received block | block receipt |
  | `client`, command processing | responses and messages of one batch | batch read from `rcvQ` |
  | `RFWD`, forwarded command | the `RRES` of that command | start of forwarded command processing |

- When the delay has already passed, the responses are written to the send queue directly.
- Otherwise a thread created by `forkClient` waits for the remaining time and writes them.
- Configuration:

  | Item | Value |
  |---|---|
  | INI section | `TRANSPORT` |
  | INI key | `auth_error_delay_ms` |
  | default | 250 |
  | `ServerConfig` field | `authErrorDelay`, microseconds |
  | test servers | 0 |

- Out of scope: NTF and XFTP servers.

## Mechanics

- `Server.hs`:
  - `delayedAuthError`: `ERR AUTH` to a command other than `LGET`.
  - `sendAfterDelay`: writes responses to the send queue after the remaining delay.
  - `receive`: block receipt time, delay flag from `verified`.
  - `client`: batch time, delay flag from processed responses.
  - `processForwardedCommand`: start time, delay flag from the forwarded command and its response.
- `Server/Env/STM.hs`: `authErrorDelay` field, `defaultAuthErrorDelayMs`.
- `Server/Main.hs`: INI value.
- `Server/Main/Init.hs`: INI template line.
- `tests/SMPClient.hs`: `authErrorDelay = 0`.
- `tests/ServerTests.hs`: delayed AUTH for wrong key, absent queue and suspended queue; immediate AUTH to `LGET`; immediate `SOK`.
- `tests/SMPProxyTests.hs`: delayed AUTH to forwarded `SEND`; immediate AUTH to forwarded `LGET`.
