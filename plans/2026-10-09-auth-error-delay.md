# Delayed AUTH error responses

## Decisions

- Scope: responses written by `receive`, the verification and parsing errors of one received block.
- When any of these responses is `ERR AUTH`, all of them are sent at block receipt time + delay.
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

- Out of scope:
  - AUTH responses to forwarded commands (`RFWD`).
  - AUTH returned after verification.
  - NTF and XFTP servers.

## Mechanics

- `Server.hs`, `receive`: receipt time after `tGetServer`; delayed write of the error responses.
- `Server/Env/STM.hs`: `authErrorDelay` field, `defaultAuthErrorDelayMs`.
- `Server/Main.hs`: INI value.
- `Server/Main/Init.hs`: INI template line.
- `tests/SMPClient.hs`: `authErrorDelay = 0`.
- `tests/ServerTests.hs`: AUTH responses after the delay, other responses without it.
