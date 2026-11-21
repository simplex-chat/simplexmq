# Stalled XFTP connections closed and memory use reduced

## Problem

On xftp-server:

- connections of unreachable or stalled peers are to be closed, with inactive-client expiry on or off;
- `xftp-server init` writes `[INACTIVE_CLIENTS] disconnect = off`, and inactive clients of a server set up with it are not disconnected;
- each received chunk is read back from disk for its digest;
- the recipients of one FNEW or FADD request are added one at a time, in separate store transactions;
- with `log_stats = off`, the download counts of these Prometheus metrics are not reset:
  - `simplex_xftp_files_count_daily`;
  - `simplex_xftp_files_count_weekly`;
  - `simplex_xftp_files_count_monthly`;
- `xftp-server start` applies PostgreSQL migrations and starts the server in one command;
- socket counts are exported to Prometheus by smp-server only;
- errors of sending a file are printed to standard output, outside the log;
- the server is run with the RTS defaults of GHC unless `+RTS` flags are given;
- the Prometheus gauges of stored files are not lowered by file expiry, and start at 0 without the stats backup:
  - `simplex_xftp_files_count_total`;
  - `simplex_xftp_files_size`;
- other quantities than the exported ones are named in the help texts of file metrics;
- `FILE_IO` is returned to a repeated upload of a chunk while an earlier upload of it is open, and the file send of the client is ended with an error;
- `FILE_IO` in place of `TIMEOUT` is returned to an upload that exceeds `fileTimeout`, as the timeout exception is caught by `receiveFile`.

## Decisions

- Limits are applied with inactive-client expiry on or off, except where expiry is named.
- New fields of `TransportServerConfig`, with their values in `mkTransportServerConfig`:
  - `firstRequestTimeout :: Int`: 60 s, in microseconds;
  - `tcpKeepAlive :: Maybe KeepAliveOpts`: `Nothing`;
  - `tcpUserTimeout :: Maybe Int`: `Nothing`; in milliseconds, the unit of `TCP_USER_TIMEOUT`.
- `tcpKeepAlive` has the name of the field in the client configuration types.
- Socket options of xftp-server are compiled constants of `FileTransfer/Server/Env.hs`, set in `serverConfig` (`FileTransfer/Server/Main.hs`):
  - `tcpKeepAlive = Just defaultXFTPKeepAlive`:
    - `keepIdle = 60`;
    - `keepIntvl = 10`;
    - `keepCnt = 6`;
  - `tcpUserTimeout = Just defaultXFTPUserTimeout`: 180000.
- With these values, a connection is closed when neither keep-alive probes nor sent data are acknowledged by its peer for 3 minutes.
- The time of each of these steps is limited by `fileTimeout` (5 minutes in `serverConfig`):
  - the first block of a request body (`xftpBlockSize`, 16384 bytes), for each request other than a CORS preflight and a static page;
  - a new chunk, as before;
  - the body of a repeated upload of a committed chunk;
  - a file response, from the read of its chunk file until its last block is queued by http2.
- A connection whose queued response is not read by the client is closed by inactive-client expiry.
- `closeSession :: IO ()` is passed by `runHTTP2ServerWith_` to the request handler and is equal to `killThread` of the connection thread. The TLS context and the socket are then closed by the release actions of `runTransportServerSocketState_` (`closeConnection`) and `runTCPServerSocket` (`gracefulClose`).
- In inactive-client expiry, the idle time is measured from the end of the last request, and connections with a request in progress are skipped.
- `closeTLS` is changed for every TLS connection of simplexmq servers and clients; #2059 contains the same implementation.
- Responses without a file are sent with `H.responseBuilder`.
- A received chunk is hashed while it is written:
  - in xftp-server, by `receiveFile` (FPUT);
  - in clients, by `receiveEncFile` (`downloadXFTPChunk`).
- In `receiveSbFile`, blocks are written through `receiveSbBlocks`, and the digest is not computed, as before.
- `addRecipient` of `FileStoreClass` is replaced by `addRecipients :: s -> SenderId -> NonEmpty FileRecipient -> IO (Either XFTPErrorType ())`; all recipients of a call are added in one transaction, or none.
- `retryAdd` is used for new file ids and for new recipient ids; after `DUPLICATE_`, every id of the call is generated again.
- The period download sets are reset also with `log_stats = off`, by `resetPeriodStats`.
- `delayUntilDayTime` is defined in `Simplex.Messaging.Util` and called in:
  - `Simplex.Messaging.Server` (`logServerStats`);
  - `Simplex.Messaging.Notifications.Server` (`logServerStats`);
  - `Simplex.FileTransfer.Server` (`logServerStats` and `resetPeriodStats`).
- The delay of `delayUntilDayTime` is computed by `secondsUntilDayTime :: Int64 -> DiffTime -> Int64`, from the start time and the time of the day.
- `xftp-server start --maintenance` (`-m`) prints the message of smp-server and ntf-server: `Server started in 'maintenance' mode, exiting`.
- The socket state of xftp-server is created in `newXFTPServerEnv` (field `sockets` of `XFTPEnv`) and passed to `runHTTP2Server`; `socketsMetric` of xftp-server is defined in `FileTransfer/Server/Prometheus.hs`, apart from the one of smp-server.
- Errors of `sendEncFile` are logged with `logInfo` as `sendEncFile: <error>` and thrown again.
- RTS defaults are compiled into the `xftp-server` executable; the allocation area limit (`-AL`) is left at the RTS default.
- `xftp-server init` writes inactive-client expiry on; existing ini files are read as written.
- Stored files are the file records with a path.
- `getUsedStorage :: s -> IO (Int, Int64)` returns the count and the size of stored files; the used storage, `filesCount` and `filesSize` are set from it in `newXFTPServerEnv`.
- `subtractStoredFile` lowers the used storage, `filesCount` and `filesSize` by one file.
- `blockFile :: s -> SenderId -> BlockingInfo -> IO (Either XFTPErrorType (Maybe FilePath))` clears the path in both stores and returns the path it cleared; in PostgreSQL, the row is read with `SELECT ... FOR UPDATE` and updated in one transaction.
- `deleteFile :: s -> SenderId -> IO (Either XFTPErrorType (Maybe FilePath))` returns the path of the deleted record; in PostgreSQL, with `DELETE ... RETURNING`.
- `deleteFiles :: s -> [SenderId] -> IO [(SenderId, Maybe FilePath, Word32)]` returns the deleted rows; in PostgreSQL, with `DELETE ... RETURNING`.
- In a deletion or a block, the file of the path returned by the store is subtracted and removed from disk; its removal error is logged.
- The stats backup is restored before the expiry at start; `filesCount` and `filesSize` of the backup are replaced by the values from the store; when the expiry at start fails, the store is closed and the stats are saved.
- In PostgreSQL, the path of rows blocked before this change is kept, and they are counted until they expire.
- The chunk of each FPUT is received into its own `.tmp` file in `filesPath`, renamed to the chunk file before `setFilePath`; `.tmp` files are removed at start, and a removal error is logged.
- On a failed rename, the reservation is released, the `.tmp` file is removed, and `FILE_IO` is returned.
- `setFilePath :: s -> SenderId -> FilePath -> IO (Either XFTPErrorType SetFilePathResult)`:
  - `FilePathSet`: the path is stored;
  - `FilePathAlreadySet`: a path of another upload is stored for an active record;
  - `AUTH`: the record is blocked or absent.
- In the catch-all handler of `receiveFile`, cancellations are thrown again (`isAsyncCancellation`, as in other handlers of simplexmq): `TIMEOUT` is returned to an upload that exceeds `fileTimeout`, and the request of an upload ended by http2 (`KilledByHttp2ThreadManager`) is ended without a response. `FILE_IO` is returned for `StackOverflow`, `HeapOverflow` and `AllocationLimitExceeded`, as before.
- Help texts:
  - `simplex_xftp_file_downloads`: `Started file downloads`;
  - `simplex_xftp_files_count_total`: `Stored files`;
  - `simplex_xftp_files_size`: `Size of stored files, bytes`;
  - `simplex_xftp_files_count_daily`: `Distinct files downloaded in the current day`;
  - `simplex_xftp_files_count_weekly`: `Distinct files downloaded in the current week`;
  - `simplex_xftp_files_count_monthly`: `Distinct files downloaded in the current month`.

## One connection

State of a connection, `ClientActivity` (`Transport/HTTP2/Server.hs`):

```
activity :: TVar ClientActivity

data ClientActivity
  = NoRequestSince SystemTime  -- connection start, before the first request
  | RequestsInFlight Int       -- requests started and not ended, at least 1
  | IdleSince SystemTime       -- end of the last request

idleSince :: ClientActivity -> Maybe SystemTime
  NoRequestSince ts -> Just ts
  RequestsInFlight _ -> Nothing
  IdleSince ts -> Just ts
```

```
runHTTP2ServerWith_ expCfg_ firstRequestTimeout_ (on a connection after TLS setup):
  activity <- newTVar (NoRequestSince now)
  fork expireInactiveClient, if expCfg_ is Just
  fork closeWithoutRequest, if firstRequestTimeout_ is Just
  run HTTP/2; each request: trackRequest activity (handler sniUsed closeSession ...)
  finally: the forked threads are killed

trackRequest activity handler:
  activity := RequestsInFlight (n + 1), or RequestsInFlight 1 from the other states
  run handler
  finally: activity := RequestsInFlight (n - 1) when n > 1, else IdleSince now

expireInactiveClient:
  every checkInterval seconds:
    idleSince activity < now - ttl -> close the connection

closeWithoutRequest:
  wait firstRequestTimeout
  activity is NoRequestSince -> close the connection

closeSession = close the connection = killThread of the connection thread
```

`Just (firstRequestTimeout transportConfig)` is passed by `runHTTP2Server`; `Nothing` is passed for both timers by `runHTTP2ServerWith`.

```mermaid
stateDiagram-v2
    state "TLS setup" as T
    state "Before the first request" as A
    state "Request in progress" as R
    state "Idle" as I
    state "Closed" as C
    [*] --> T: socket accepted, socket options set
    T --> C: tlsSetupTimeout, 60 s
    T --> A: TLS established, timers started
    A --> R: request started
    A --> C: firstRequestTimeout, 60 s
    A --> C: expiry on, NoRequestSince older than ttl at a check
    R --> R: another request started or ended
    R --> I: last request ended, IdleSince written
    I --> R: request started
    I --> C: expiry on, IdleSince older than ttl at a check
    R --> C: closeSession after fileTimeout
    C --> [*]: closeTLS, then gracefulClose of the socket
    note right of C
        Also reached from every state when the kernel
        aborts the TCP connection after TCP_USER_TIMEOUT, 180 s.
    end note
```

## Socket options

```
setServerSocketOptions TransportServerConfig {tcpKeepAlive, tcpUserTimeout} socket:
  tcpKeepAlive is Just opts -> setSocketKeepAlive socket opts; error -> logged
  UserTimeout supported and tcpUserTimeout is Just ms -> UserTimeout := ms; error -> logged
```

`setServerSocketOptions` is called in `setupTLS` of `runTransportServerSocket` and of `runTransportServerSocketState`, on each accepted socket, before the TLS handshake.

```mermaid
flowchart LR
    A[accepted socket]
    K{tcpKeepAlive}
    U{UserTimeout supported and tcpUserTimeout set}
    T[TLS handshake]
    A --> K
    K -- "Just opts, setSocketKeepAlive" --> U
    K -- "Nothing" --> U
    U -- "yes, UserTimeout set" --> T
    U -- "no" --> T
```

## Requests

```
xftpServer handler sniUsed closeSession sessionId sessionALPN request sendResponse:
  OPTIONS, with CORS -> preflight response
  GET, with SNI -> static page
  other -> timeout fileTimeout (getHTTP2Body request xftpBlockSize)
    Nothing -> log "request receiving timeout, closing connection"; closeSession
    Just reqBody -> handshake or processRequest, as before

FPUT, chunk committed -> timeout fileTimeout (drain size)
  Nothing -> FRErr TIMEOUT
FPUT, chunk new -> timeout fileTimeout (receiveFile getBody spec)
  Nothing -> FRErr TIMEOUT   -- changed: the timeout was caught by receiveFile as FILE_IO

sendXFTPResponse transmission serverFile_:
  encoding error -> sendResponse (responseBuilder "padding error")
  serverFile_ == Nothing -> sendResponse (responseBuilder transmission)
  serverFile_ == Just file ->
    withAsync (wait fileTimeout; log "file sending timeout, closing connection"; closeSession)
      (sendResponse (responseStreaming: transmission, then the encrypted file))
```

Green: added. Blue: changed.

```mermaid
flowchart TD
    Q[HTTP/2 request]
    T[trackRequest start]
    M{method}
    O[CORS preflight response]
    G[static page]
    B{first body block read within fileTimeout}
    X[logged, closeSession]
    P{handshake or command}
    D{chunk committed}
    DR{body drained within fileTimeout}
    OK[FROk or FRErr SIZE]
    TO[FRErr TIMEOUT]
    RC[chunk received and hashed within fileTimeout]
    F[file response under the withAsync timer]
    R[builder response]
    E[trackRequest end]
    Q --> T
    T --> M
    M -- "OPTIONS, with CORS" --> O
    M -- "GET, with SNI" --> G
    M -- "other" --> B
    B -- "no" --> X
    B -- "yes" --> P
    P -- "FPUT" --> D
    D -- "yes" --> DR
    DR -- "yes" --> OK
    DR -- "no" --> TO
    D -- "no" --> RC
    P -- "FGET with a file" --> F
    P -- "other commands and errors" --> R
    OK --> R
    TO --> R
    RC --> R
    O --> E
    G --> E
    R --> E
    F --> E
    RC -- "no, fileTimeout" --> TO
    linkStyle 5,10,21 stroke:#008800
    linkStyle 0,1,4,6,12,13,17,18,19,20 stroke:#1155cc
```

A download, with the order of steps and who takes them:

```mermaid
sequenceDiagram
    participant C as Client
    participant H as http2
    participant X as request handler
    participant W as withAsync timer
    participant S as connection thread
    C->>H: FGET request
    H->>X: handler started, requestsInFlight + 1
    X->>X: first body block read within fileTimeout
    X->>W: timer started, fileTimeout
    X->>H: blocks of the encrypted chunk file queued
    alt last block queued within fileTimeout
        X->>W: timer cancelled
        X->>H: handler ended, requestsInFlight - 1, idleSince written
        H->>C: queued end of the response sent
    else fileTimeout reached
        W->>S: closeSession, connection closed
    end
```

## Closing TLS

```
closeTLS ctx:
  byeDone <- new empty TMVar
  fork with unmask:
    timeout 1 s (bye ctx); errors ignored
    finally: put byeDone
  take byeDone
  finally: contextClose ctx; errors ignored
```

```mermaid
sequenceDiagram
    participant C as caller of closeTLS
    participant B as forked thread
    participant T as TLS context
    C->>B: forked, unmasked
    B->>T: bye, limited to closeTLSTimeout, 1 s
    B->>C: byeDone put, also after an error or the timeout
    C->>C: byeDone taken
    C->>T: contextClose
```

## Receiving a chunk

```
receiveFile_ receive XFTPRcvChunkSpec {filePath, chunkSize, chunkDigest}:
  hashCtx <- IORef (hashInit :: Context SHA256)
  write h block = hPut h block; hashCtx := hashUpdate hashCtx block
  withFile filePath WriteMode: receive (write h) chunkSize
  hashFinalize hashCtx /= chunkDigest -> DIGEST
```

`receive` is `receiveFileBlocks` (`receiveFile`) or `receiveSbBlocks` (`receiveEncFile`). `hReceiveFile` is renamed `receiveFileBlocks`, with a write function as its parameter in place of the handle.

```
receiveFile getBody spec = receiveFile_ ... `catches`, in order:
  HTTP2Error -> logWarn; Left TIMEOUT
  SomeException e:
    isAsyncCancellation e -> throwIO e   -- added: timeout of fileTimeout, killThread, KilledByHttp2ThreadManager
    otherwise -> logError; Left FILE_IO
```

```mermaid
flowchart LR
    X[exception in receiveFile_]
    H{HTTP2Error}
    A{isAsyncCancellation}
    TO[Left TIMEOUT]
    RT[thrown again]
    T[timeout of receiveChunk: FRErr TIMEOUT]
    FI[Left FILE_IO]
    X --> H
    H -- "yes" --> TO
    H -- "no" --> A
    A -- "added - yes" --> RT
    RT -- "added - fileTimeout" --> T
    A -- "no: StackOverflow, HeapOverflow, AllocationLimitExceeded, IO errors" --> FI
    linkStyle 3,4 stroke:#008800
```

Green: added. Red: removed.

```mermaid
flowchart LR
    B[request body blocks]
    W[write]
    F[chunk file]
    H[SHA-256 context]
    D{digest equal}
    E[DIGEST]
    OK[Right]
    B -- "read by getBody" --> W
    W -- "written" --> F
    W -- "added - hashUpdate" --> H
    H -- "added - hashFinalize" --> D
    F -- "removed - read back, sha256Hash" --> D
    D -- "no" --> E
    D -- "yes" --> OK
    linkStyle 2,3 stroke:#008800
    linkStyle 4 stroke:#cc0000
```

## Uploads of one chunk

```
FPUT of a chunk without a path:
  quota reserved
  tmpPath = filesPath/<sender id>.<16 random base64url characters>.tmp
  chunk received into tmpPath, limited by fileTimeout
  error -> reservation released; tmpPath removed; error returned
  tmpPath renamed to fPath = filesPath/<sender id>
    error -> logged; reservation released; tmpPath removed; FILE_IO
  setFilePath store senderId fPath:
    Right FilePathSet        -> FPUT record logged; stats; OK
    Right FilePathAlreadySet -> reservation released; OK
    Left AUTH                -> reservation released; fPath removed; AUTH
    Left error               -> reservation released; the error

xftpServer start:
  files with the extension .tmp in filesPath removed; errors logged
```

Each upload is written to its own file: a repeated upload of a chunk is received while an earlier upload of it is open, and only its own file is removed at a failure. The chunk file is renamed into place before its path is stored, so a stored path always names a complete file. The file of the first committed upload is kept; the chunk file is replaced with equal content by an upload completed later, and OK is returned to it.

Green: added. Red: removed.

```mermaid
sequenceDiagram
    participant C as client
    participant S1 as first FPUT, stalled
    participant S2 as repeated FPUT
    participant D as files directory
    C->>S1: FPUT, body stalled
    S1->>D: write <sender id>.<a>.tmp
    C->>S2: FPUT on a new connection
    S2->>D: added - write <sender id>.<b>.tmp
    S2->>D: added - rename to <sender id>, then setFilePath
    S2-->>C: OK
    S1->>D: fileTimeout - remove <sender id>.<a>.tmp only
    Note over S2,D: removed - FILE_IO on the file lock, and the file of the first FPUT removed
```

## Recipients

```
retryAdd n newIds add:
  n == 0 -> Left INTERNAL
  ids <- newIds
  add ids
    Left DUPLICATE_ -> retryAdd (n - 1) newIds add
    result -> result

addFileRetry: newIds = one random file id; add = addFile
addRecipientsRetry: newIds = one random recipient id per key; add = addRecipients
n = 3 in FNEW and FADD
```

```
addRecipients, memory store (one STM transaction):
  file missing -> Left AUTH
  an id repeated in the call -> Left DUPLICATE_
  an id among the recipients of the file -> Left DUPLICATE_
  an id in the recipients map -> Left DUPLICATE_
  otherwise -> every id added to the recipients of the file and to the recipients map; Right ()

addRecipients, PostgreSQL (one transaction):
  INSERT INTO recipients, executeMany for every recipient
    unique violation -> Left DUPLICATE_
    foreign key violation -> Left AUTH
  inserted, db_store_log on -> one AddRecipients record with every recipient
```

- In FNEW, the file is added by `addFileRetry`, then its recipients by `addRecipientsRetry`.
- One `AddRecipients` record per FNEW or FADD is written to the store log of the memory store, as before.
- In `readFileStore`, an `AddRecipients` record is replayed by `addRecipients` of the memory store.

```mermaid
flowchart TD
    R[FNEW or FADD]
    I[random recipient id per key]
    A{addRecipients}
    D[DUPLICATE_]
    N{attempts left}
    OK[recipients added, store log record]
    E[INTERNAL]
    ERR[AUTH or another error]
    R --> I
    I --> A
    A -- "Right ()" --> OK
    A -- "Left DUPLICATE_" --> D
    A -- "other Left" --> ERR
    D --> N
    N -- "yes" --> I
    N -- "no" --> E
```

## File expiry

```
expireServerFiles itemDelay expCfg:
  loop:
    expired <- expiredFiles store now old 10000
    for each expired file with a path that exists on disk:
      removeFile path; then wait itemDelay
      error -> logged
    expired == [] -> end
    DeleteFile records written
    deleted <- deleteFiles store (ids of the batch)
    for each deleted row: subtractStoredFile when it has a path; filesExpired + 1
    loop

itemDelay:
  at the start of xftp-server -> Nothing
  every checkInterval -> Just 0.1 s
```

At most `limit` rows in total are returned by the PostgreSQL query of `expiredFiles`:

```sql
SELECT sender_id, file_path, file_size FROM (
  (SELECT ... FROM files WHERE expires_at < ? LIMIT ?)
  UNION ALL
  (SELECT ... FROM files WHERE expires_at IS NULL AND created_at < ? LIMIT ?)
) expired LIMIT ?
```

All expired files are returned by the memory store, as before.

Blue: changed.

```mermaid
flowchart TD
    Q[expiredFiles, limit 10000]
    E{batch empty}
    DONE[expiry check completed]
    P{file path on disk}
    R[removeFile]
    W[wait itemDelay]
    N{more files in the batch}
    D[batch deleted from the store]
    A[subtractStoredFile and filesExpired, for the deleted rows]
    Q --> E
    E -- "yes" --> DONE
    E -- "no" --> P
    P -- "yes" --> R
    R -- "file removed" --> W
    P -- "no" --> N
    W --> N
    R -- "error, logged" --> N
    N -- "yes" --> P
    N -- "no" --> D
    D -- "changed - deleted rows returned" --> A
    A --> Q
    linkStyle 4,5,10 stroke:#1155cc
```

## Stored files

```
newXFTPServerEnv:
  (count, size) <- getUsedStorage store      -- records with a path
  usedStorage = size; filesCount = count; filesSize = size

xftpServer start:
  removeTmpUploads                           -- .tmp files of unfinished uploads
  restoreServerStats                         -- backup counters; count and size kept from the store
  expireServerFiles Nothing                  -- on error: stopServer (store closed, stats saved)
  raceAny_ server threads `finally` stopServer
```

Green: added. Blue: changed.

```mermaid
flowchart TD
    S[xftpServer start]
    U[removeTmpUploads]
    R[restoreServerStats]
    E[expireServerFiles Nothing]
    T[server threads]
    X[stopServer: store closed, stats saved]
    S -- "added" --> U
    U --> R
    R -- "changed - before the expiry" --> E
    E -- "done" --> T
    E -- "added - error" --> X
    T -- "end" --> X
    linkStyle 0,4 stroke:#008800
    linkStyle 2 stroke:#1155cc
```

```
FPUT committed:        filesCount + 1; filesSize + size   (used storage reserved before the upload)
FDEL, control delete:  file of the read path removed
                       path <- deleteFile                 -- path at deletion
                       path -> subtractStoredFile size; file removed when on disk
control block:         as deletion, with blockFile        -- path at blocking, then cleared
expiry:                deleteFiles returns the deleted rows; row with a path -> subtractStoredFile size

subtractStoredFile size:
  usedStorage - size; filesCount - 1; filesSize - size
```

Green: added. Blue: changed. Red: removed.

```mermaid
flowchart LR
    ST[(store: records with a path)]
    ENV[newXFTPServerEnv]
    G[usedStorage, filesCount, filesSize]
    SUB[subtractStoredFile]
    DEL[FDEL, control delete]
    BLK[control block]
    EXP[expiry]
    RS[restoreServerStats]
    BK[(stats backup)]
    DISK[file on disk]
    ST -- "added - count and size at start" --> ENV
    ENV --> G
    DEL -- "added - path returned by the store delete" --> SUB
    BLK -- "added - path returned by the store block, then cleared" --> SUB
    EXP -- "changed - deleted rows only" --> SUB
    SUB -- "added - all three lowered" --> G
    BK -- "counters except count and size" --> RS
    RS -- "changed - before the expiry at start" --> G
    DISK -- "removed - count and size lowered when the file existed" --> G
    linkStyle 0,2,3,5 stroke:#008800
    linkStyle 4,7 stroke:#1155cc
    linkStyle 8 stroke:#cc0000
```

## Period stats

```
serverStatsThread_:
  logStatsInterval == Just interval -> logServerStats logStatsStartTime interval, as before
  logStatsInterval == Nothing -> resetPeriodStats logStatsStartTime

resetPeriodStats startAt:
  delayUntilDayTime startAt
  forever:
    periodStatCounts filesDownloaded now
    wait periodStatsInterval, 86400 s

delayUntilDayTime startAt:
  d = startAt - seconds since 00:00 UTC
  wait d seconds, or d + 86400 seconds when d < 0
```

In `periodStatCounts`, these sets are reset:

- day: at every call;
- week: at a call on a Monday;
- month: at a call on the first day of a month.

Green: added. Blue: changed.

```mermaid
flowchart LR
    C{log_stats}
    L[logServerStats]
    P[resetPeriodStats]
    D[delayUntilDayTime]
    S[periodStatCounts filesDownloaded]
    M[Prometheus metrics]
    C -- "on" --> L
    C -- "added - off" --> P
    L -- "changed - start" --> D
    P -- "added - start" --> D
    L -- "every interval" --> S
    P -- "added - every 86400 s" --> S
    S -- "sets read" --> M
    linkStyle 1,3,5 stroke:#008800
    linkStyle 2 stroke:#1155cc
```

## Maintenance

```
xftp-server start --maintenance (-m):
  checkSavedFingerprint
  readFileStoreType
  checkFileStoreMode
  runWithStoreConfig, with --confirm-migrations:
    migrateFileStore storeCfg:
      memory store -> pure ()
      PostgreSQL -> newFileStore (migrations applied), then closeFileStore
    print "Server started in 'maintenance' mode, exiting"
    exitSuccess
```

Green: added.

```mermaid
flowchart TD
    S[xftp-server start]
    C[fingerprint and store mode checked]
    R[runWithStoreConfig]
    M{maintenance option}
    K{store}
    PG[migrations applied by newFileStore, then closeFileStore]
    X[message printed, exitSuccess]
    RUN[printXFTPConfig, runXFTPServer]
    S --> C
    C --> R
    R --> M
    M -- "added - yes" --> K
    K -- "memory" --> X
    K -- "PostgreSQL" --> PG
    PG --> X
    M -- "no" --> RUN
    linkStyle 3,4,5,6 stroke:#008800
```

## Socket metrics

Gauges, each with the label `port` equal to `xftpPort`, read from `sockets` of `XFTPEnv` by `getSocketStats`:

- `simplex_xftp_sockets_accepted`;
- `simplex_xftp_sockets_closed`;
- `simplex_xftp_sockets_active`;
- `simplex_xftp_sockets_leaked`: accepted, less closed, less active.

## RTS defaults

`ghc-options` of the `xftp-server` executable contain `"-with-rtsopts=..."` with these flags:

- `-N`;
- `-F1.2`;
- `-A16m`;
- `-I0.01`;
- `-Iw15`;
- `-T`;
- `-ki2k`;
- `--disable-delayed-os-memory-return`.

Of the compiled defaults, only the ones matched by flags given at run time are overridden.

## init

`xftp-server init` writes:

```
[INACTIVE_CLIENTS]
# TTL and interval to check inactive clients
disconnect = on
ttl = 21600
check_interval = 3600
```

## Composition

Green: added. Blue: changed. Red: removed.

```mermaid
flowchart LR
    MAIN[Server/Main.hs serverConfig]
    CFG[TransportServerConfig]
    SO[setServerSocketOptions]
    ENV[XFTPEnv]
    H2[runHTTP2Server]
    CA[ClientActivity]
    XH[xftpServer request handler]
    PR[processRequest]
    TLS[closeTLS]
    RF[receiveFile_]
    ST[addRecipients]
    SL[store log]
    EX[expireServerFiles]
    EF[expiredFiles]
    PS[resetPeriodStats]
    DU[delayUntilDayTime]
    LS[logServerStats<br>smp-server<br>ntf-server<br>xftp-server]
    PM[Prometheus metrics]
    MIG[migrateFileStore]
    SE[sendEncFile]
    LOG[log]
    OUT[standard output]
    SS[newSocketState in runHTTP2Server]
    AT[activeAt written at request start]
    RB[chunk file read back]
    AR[addRecipient per recipient]
    MAIN -- "added - socket options" --> CFG
    CFG -- "added - applied to each accepted socket" --> SO
    CFG -- "added - firstRequestTimeout" --> H2
    ENV -- "added - sockets" --> H2
    ENV -- "added - sockets" --> PM
    H2 -- "added - trackRequest and timers" --> CA
    H2 -- "added - closeSession" --> XH
    XH -- "added - first body block under fileTimeout" --> PR
    PR -- "added - closeSession after fileTimeout" --> H2
    MAIN -- "added - maintenance option" --> MIG
    PS -- "added - start" --> DU
    PS -- "added - period sets reset" --> PM
    H2 -- "changed - connection closed, bye limited to 1 s" --> TLS
    PR -- "changed - hashed while written" --> RF
    PR -- "changed - all recipients in one call" --> ST
    ST -- "changed - one AddRecipients record in db_store_log" --> SL
    SL -- "changed - replayed by addRecipients" --> ST
    EX -- "changed - PostgreSQL total LIMIT" --> EF
    LS -- "changed - start" --> DU
    SE -- "changed - errors logged with logInfo" --> LOG
    H2 -- "removed - created per server" --> SS
    H2 -- "removed - activity time" --> AT
    RF -- "removed - digest" --> RB
    PR -- "removed - one store call per recipient" --> AR
    SE -- "removed - errors printed" --> OUT
    classDef removed fill:#f4cccc,stroke:#cc0000
    classDef added fill:#d9ead3,stroke:#008800
    class SS,AT,RB,AR removed
    class SO,CA,PS,DU,MIG added
    linkStyle 0,1,2,3,4,5,6,7,8,9,10,11 stroke:#008800
    linkStyle 12,13,14,15,16,17,18,19 stroke:#1155cc
    linkStyle 20,21,22,23,24 stroke:#cc0000
```

## Tests

- XFTP server with a store log (`xftpStoreLogServerTests`), run once with the memory store:
  - `testExpireNotUploadedFiles`: 50 files without chunks, added through store log records with an expiry 2 s ahead, are expired within 6 s with `checkInterval = 1`, and `AUTH` is returned to an FADD of each;
  - `testFileStatsRestart`, with and without the stats backup: of a store log with an expired stored file, a stored file and a file without a chunk, `files_expired = 1`, `files_count_total = 1` and `files_size = 131072` are exported after start;
  - `testRemoveTmpUploads`: of a chunk file and a `.tmp` file in `filesPath` before start, only the chunk file is left after start.
- XFTP server (`XFTPServerTests.hs`), with the memory store and, in the PostgreSQL build, with the PostgreSQL store:
  - `testLongDownloadExpiration`: with `ttl = 1` and `checkInterval = 1`, the first 2 MB of a 4 MB download are read in 16 kB blocks 25 ms apart, the download is completed, PONG is returned to a PING after it, and the connection is closed by expiry after the PING;
  - `testPeriodStatsReset`: with `logStatsInterval = Nothing` and `logStatsStartTime` 10 s ahead, `simplex_xftp_files_count_daily` is 1 after a download and 0 after the reset time;
  - `testSocketMetrics`: the socket gauges are `accepted=1 closed=0 active=1 leaked=0` with one client connected, and `accepted=1 closed=1 active=0 leaked=0` after its disconnection;
  - `testStalledDownload`: with `fileTimeout` of 2 s and expiry off, a connection with an unread FGET response is closed, and the list of chunk files open in the server is empty;
  - `testStalledDownloadEnd`: with `fileTimeout` of 2 s, `ttl = 1` and `checkInterval = 1`, a connection is closed when the last 1 MB + k kB of a 4 MB response are unread, for k from 0 to 320 in steps of 64;
  - `testStalledRequestBody`: with `fileTimeout` of 2 s and expiry off, a connection whose request body is stalled after 1 byte is closed;
  - `testStalledUpload`: with `fileTimeout` of 2 s, `TIMEOUT` is returned within 5 s to an FPUT with a stalled body, of a committed chunk and of a new one;
  - `testRepeatedUploadDuringStalledUpload`: with `fileTimeout` of 2 s, while an FPUT with a stalled body is open, OK is returned to an FPUT of the same chunk on a new connection, the chunk is downloaded before and after the time-out of the stalled FPUT, and no `.tmp` file is left;
  - `testUploadAfterCommittedUpload`: OK is returned to an FPUT whose body is sent after another FPUT of the same chunk is committed, and the chunk is downloaded;
  - `testNoRequestTimeout`: with `firstRequestTimeout` of 1 s, with expiry off and on, a TLS connection without a request is closed within 5 s, and a client after its handshake stays connected for 2 s and receives PONG;
  - `testInactiveClientExpiration`: as before, with the client helper `connectXFTPClient`;
  - `testFileStatsDelete`: after two uploads, `files_count_total = 2` and `files_size = 262144`; after the deletion of both, one with its chunk file removed from disk, `files_deleted = 2`, `files_count_total = 0` and `files_size = 0`;
  - `testFileMetricsHelp`: the help texts of the six file metrics above are exported;
  - the metrics are read by one helper, `readMetrics`.
- Chunk receiving (`XFTPServerTests.hs`): with the chunk written to `/dev/null`, `Right ()` is returned by `receiveFile` and by `receiveEncFile` for the correct digest, and `DIGEST` for another one.
- Transport (`CoreTests/TransportTests.hs`, with its own credentials and fingerprint loading):
  - `testCloseBlockedTLS`: while the client is not reading and the server sender thread is blocked, `closeConnection` of the server returns within 5 s, and the sender thread is ended by an exception within 5 s;
  - `testServerKeepAlive`: `SO_KEEPALIVE` of the accepted socket is set with `tcpKeepAlive = Just defaultKeepAliveOpts` and unset with `Nothing`;
  - `testServerUserTimeout`: `TCP_USER_TIMEOUT` of the accepted socket is 180000 with `tcpUserTimeout = Just 180000` and 0 with `Nothing`.
- Stores (`CoreTests/XFTPStoreTests.hs`, in the PostgreSQL build):
  - `testAddRecipientsAtomically`, for both stores: with an id already stored or repeated in the call, `DUPLICATE_` is returned and the new recipient is not added; all recipients of a call with new ids are added; `AUTH` is returned for a missing file;
  - `testExpiredFilesTotalLimit`: of 6 expired PostgreSQL files of both kinds, 4 are returned with `limit = 4` and 6 with `limit = 10`;
  - `testStorageAndCountForStore`, for both stores: the count and size of files with a path are returned by `getUsedStorage`; a blocked file is excluded; `FilePathSet`, then `FilePathAlreadySet` is returned by `setFilePath`; the path is returned by `blockFile` and `deleteFile`, `Nothing` by a repeated block, and `AUTH` by a repeated deletion; only the deleted rows are returned by `deleteFiles`, with the path cleared for the blocked file, and `[]` when repeated;
  - `testSetFilePath`, PostgreSQL: `FilePathSet`, then `FilePathAlreadySet`; `AUTH` for a blocked and for an absent record;
  - `testAddRecipientsLog`, PostgreSQL with `db_store_log`: one FNEW and one FADD record for a file with two recipients, and both recipients after a replay into the memory store.
- Utilities (`CoreTests/UtilTests.hs`): `secondsUntilDayTime` for a time later in the day, a time of the next day, and the current second.
- CLI (`CLITests.hs`):
  - `xftpServerTest`: `init` writes `disconnect = on`, `ttl = 21600` and `check_interval = 3600`;
  - `xftpServerMaintenanceTest`: `start --maintenance` ends within 5 s, with the maintenance message in its output and without `Listening on port 443...`;
  - `xftpServerMaintenanceDBTest`: with PostgreSQL and `--confirm-migrations up`, migrations are applied to a new schema.
- Untested:
  - the XFTP CLI setting of keep-alive and the user timeout;
  - the logging of send errors;
  - `receiveSbFile`;
  - the start of `logServerStats` of each server with the shared `delayUntilDayTime`;
  - the retry of FNEW and FADD on duplicate ids;
  - the padding error response;
  - the wait after a file deletion;
  - the RTS defaults;
  - a deletion or a block during an expiry batch or an upload commit;
  - a failed expiry at start;
  - a failed rename of an upload, and a failed removal of a `.tmp` file at start.
