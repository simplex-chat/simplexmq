# Delayed AUTH error responses

## Decisions

- Responses that include `ERR AUTH` are sent at the next multiple of the delay after the start time.
- Delayed response sets:

  | Source | Responses sent together | Start time |
  |---|---|---|
  | `receive`, failed verification | verification and parsing errors of one received block | block receipt |
  | `client`, command processing | responses and messages of one batch | batch read from `rcvQ` |
  | `RFWD`, forwarded command | the `RRES` of that command | start of forwarded command processing |

- A thread created by `forkClient` writes the responses to the send queue.
- Delay 0: the responses are written to the send queue directly.
- `authDelayExceeded`: incremented when processing took longer than the delay.
  - Prometheus counter `simplex_smp_auth_delay_exceeded`.
  - Not saved in the stats backup.
  - Not in the daily stats log.
- Configuration:

  | Item | Value |
  |---|---|
  | INI section | `TRANSPORT` |
  | INI key | `auth_error_delay_ms` |
  | default | 50 |
  | `ServerConfig` field | `authErrorDelay`, microseconds |
  | test servers | 20 ms |

- AUTH timing test: elapsed time of 5 requests, test servers' delay.
- Out of scope: NTF and XFTP servers.

## Mechanics

- `Server.hs`:
  - `isAuthError`: response is `ERR AUTH`.
  - `sendResponses`: responses with `ERR AUTH` to `sendAfterDelay`, others to the send queue.
  - `sendAfterDelay`: writes responses to the send queue at the next multiple of the delay.
  - `receive`: block receipt time from the `rcvActiveAt` reading.
  - `client`: batch time.
  - `processForwardedCommand`: start time.
- `Server/Env/STM.hs`: `authErrorDelay` field, `defaultAuthErrorDelayMs`.
- `Server/Stats.hs`: `authDelayExceeded` in `ServerStats` and `ServerStatsData`.
- `Server/Prometheus.hs`: `simplex_smp_auth_delay_exceeded`.
- `Server/Main.hs`: INI value.
- `Server/Main/Init.hs`: INI template line.
- `simplexmq.cabal`: `timeit` removed from the test suite.
- `tests/SMPClient.hs`: `authErrorDelay = 20000`.
- `tests/ServerTests.hs`:
  - delayed AUTH for wrong key, absent queue, absent link and suspended queue; immediate `SOK`.
  - AUTH timing test measures elapsed time.
- `tests/SMPProxyTests.hs`: delayed AUTH to forwarded `SEND` and `LGET`.
