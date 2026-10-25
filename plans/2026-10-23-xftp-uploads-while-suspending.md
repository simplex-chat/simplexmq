# XFTP uploads while the agent is suspending

On iOS, a file sent shortly before the app left the foreground was delivered only after the app was opened again. Once the agent began to suspend, the next chunk was not started, and the result of the chunk in flight was recorded only in foreground.
While the agent is suspending, it continues the uploads that it started in foreground. Their files are counted by a new operation, `AOSndFiles`, with its own count and set, in a stage between `AORcvNetwork` and `AOMsgDelivery`. The next stage is entered after these files are deleted by the chat, removed by TTL cleanup or `closeAgentClient`, or removed at the start of the suspension when their rows are absent or flagged deleted or failed. At the suspend timeout, the stage of `AOSndNetwork` is entered if the agent is still suspending.

Chat side: https://github.com/evgeny-simplex/simplex-chat/pull/5

## Decisions

- Stages of `suspendAgent` with a timeout above 0:

  | Order | Operation | Count | At count 0 |
  |---|---|---|---|
  | 1 | `AORcvNetwork` | received transmission batches in processing by the subscriber | `AOSndFiles` suspended |
  | 2 | `AOSndFiles` | counted files | `AOMsgDelivery` suspended |
  | 3 | `AOMsgDelivery` | submitted messages not yet taken by delivery workers | `AOSndNetwork` suspended |
  | 4 | `AOSndNetwork` | delivery workers and async command workers processing work | `AODatabase` suspended |
  | 5 | `AODatabase` | database transactions | `SUSPENDED` sent; agent state `ASSuspended` |

  - The actions of "At count 0" are taken only while the agent state is `ASSuspending`.
  - `AONtfNetwork` is suspended at the start; the stages are entered independently of its count.
  - After the timeout, if the agent is still suspending, stage 4 is entered whatever stage is in progress; stage 5 is entered when the count of stage 4 is 0, as in the table.
- Counted files, the set `sndFilesInProgress`:
  - inserted: files started by `xftpStartSendFile'` while the agent state is `ASForeground`;
  - removed:
    - files deleted by `deleteSndFilesInternal`, after its database work, also when an exception is thrown;
    - files expired by TTL cleanup, before their prefix path and row are deleted;
    - at the start of `suspendAgent` with a timeout above 0, while `AODatabase` is not suspended: files whose rows are absent or flagged `deleted = 1` or `failed = 1`, found by one query; the suspended flag of `AODatabase` is checked and the operation is begun in one STM transaction;
    - every file, by `closeAgentClient`.
  - kept until the chat deletes them: files with complete or error rows; the file descriptions are sent while these files are counted.
  - kept until TTL cleanup, `closeAgentClient` or process exit: counted files completed or failed by another process; each suspension in between waits for the suspend timeout.
- `deleteSndFilesInternal` is run by `xftpDeleteSndFileInternal`, which is called by the chat after `SFDONE` and `SFERR`.
- Uncounted files:
  - files resumed at worker start;
  - files started while suspending or suspended.
- Condition of the send prepare and upload workers, `uploadsAllowed`:

  | Agent state | Counted files | `AOSndNetwork` suspended | Condition |
  |---|---|---|---|
  | `ASForeground` | any | any | true |
  | `ASSuspending` | above 0 | no | true |
  | `ASSuspending` | 0 | any | false |
  | `ASSuspending` | any | yes | false |
  | `ASSuspended` | any | any | false |

  - While the condition is false, the send prepare and upload workers wait until the agent state is `ASForeground`.
  - While the condition is true, uncounted files are uploaded too.
- Receive and delete workers: unchanged.
- `foregroundAgent`: suspended flags cleared; counted files kept.

```
xftpStartSendFile' f           ASForeground -> add f
deleteSndFilesInternal fs      rows deleted or marked deleted; finally: remove each f
deleteSndFilesExpired f        remove f; prefix path and row deleted
suspendAgent, timeout > 0      AODatabase not suspended -> begin AODatabase; remove each f whose row is absent, deleted or failed; end AODatabase
closeAgentClient               remove each f
add f                          f not in set -> insert f; count + 1
remove f                       f in set -> delete f; endAgentOperation AOSndFiles
```

## Mechanics

- `src/Simplex/Messaging/Agent/Client.hs`:
  - `AgentClient` (:380-381), fields created in `newAgentClient` (:555-556):
    - `sndFilesOp :: TVar AgentOpState`;
    - `sndFilesInProgress :: TVar (Set SndFileId)`.
  - `AgentOperation`: `AOSndFiles` (:481).
  - `sndFilesOp` added to:
    - `agentOpSel` (:488);
    - `agentOperations` (:494).
  - `closeAgentClient` (:1029): every counted file removed by `removeSndFileInProgress`.
  - `endAgentOperation` (:2372-2386): at the end of `AORcvNetwork`, `AOSndFiles` is suspended; at the end of `AOSndFiles`, `suspendMsgDelivery` is called.
  - `suspendMsgDelivery` (:2388-2391): `AOMsgDelivery` is suspended; `suspendSendingAndDatabase` is called when its count is 0.
  - new:
    - `addSndFileInProgress` (:2423-2426);
    - `removeSndFileInProgress` (:2428-2431);
    - `removeDeletedOrFailedSndFilesInProgress` (:2433-2443): when the set is not empty and `AODatabase` is begun by `tryBeginAgentOperation`, the counted files missing from `getNotDeletedOrFailedSndFileIds` are removed; on a query error, the error is logged and the set is unchanged;
    - `tryBeginAgentOperation` (:2454-2455): `beginAgentOperation`, or `False` by `orElse` while the operation is suspended; `True` when begun;
    - `waitUntilUploadsAllowed` (:2480-2490), with the condition `uploadsAllowed`.
- `src/Simplex/Messaging/Agent/Store/AgentStore.hs`, new: `getNotDeletedOrFailedSndFileIds` (:3897-3899), the entity IDs of `snd_files` rows with `deleted = 0` and `failed = 0`.
- `src/Simplex/Messaging/Agent.hs`:
  - `suspendAgent`:
    - `removeDeletedOrFailedSndFilesInProgress` (:3442), in the branch with a timeout above 0;
    - stages (:3447-3449): `AORcvNetwork`, `AOSndFiles`, then `suspendMsgDelivery`.
  - `deleteSndFilesExpired` (:3548), local to `cleanupManager`: `removeSndFileInProgress`.
- `src/Simplex/FileTransfer/Agent.hs`:
  - `xftpStartSendFile'` (:406): `addSndFileInProgress` when `ASForeground`.
  - `assertUploadsAllowed` in place of `assertAgentForeground`:
    - `runXFTPSndPrepareWorker` (:423, :486, :506);
    - `runXFTPSndWorker` (:527, :548, :559).
  - `uploadFileChunk` (:561): `waitUntilUploadsAllowed` in place of `waitUntilForeground`.
  - `deleteSndFilesInternal` (:662): `removeSndFileInProgress` in `E.finally`.
  - `assertUploadsAllowed` (:748-751): `throwWhenInactive`, then `waitUntilUploadsAllowed`.

## Tests

`tests/XFTPAgent.hs`, "agent XFTP API":
- "should complete sending file while agent is suspending" (:641):
  - suspend timeout 60 s;
  - all `SFPROG` within 30 s, then `SFDONE`;
  - events absent for 300 ms;
  - after `xftpDeleteSndFileInternal`, `SUSPENDED` within 5 s.
- "should suspend on timeout when file is not sent" (:656):
  - XFTP server down, suspend timeout 0.5 s: `SUSPENDED`;
  - server started: events absent for 1 s;
  - after `foregroundAgent`, `SFDONE`.
- "should not wait for file started while agent is suspending" (:672):
  - file 1 started, suspend timeout 60 s, file 2 started;
  - `SFDONE` of file 1 within 30 s;
  - after `xftpDeleteSndFileInternal` of file 1, `SUSPENDED` within 5 s; events of file 2 before it are skipped.
- "should continue sending file when another file is deleted twice while agent is suspending" (:686):
  - file 1 of 128 KB and file 2 of 17 MB started, suspend timeout 60 s;
  - `xftpDeleteSndFileInternal` of file 1, twice;
  - `SFDONE` of file 2 within 30 s; `SUSPENDED` before it: test failure;
  - after `xftpDeleteSndFileInternal` of file 2, `SUSPENDED` within 5 s; events of file 1 before it are skipped.
- "should wait for complete file until it is deleted while agent is suspending" (:702):
  - file of 128 KB started; `SFDONE` within 30 s;
  - suspend timeout 60 s; events absent for 300 ms;
  - after `xftpDeleteSndFileInternal`, `SUSPENDED` within 5 s.
- `testXFTPAgentSuspendAfter` (:715), for the next four tests:
  - XFTP server down; file of 128 KB started;
  - the test's step;
  - suspend timeout 60 s: `SUSPENDED` within 5 s; events of the file before it are skipped.
- "should not wait for file deleted from database while agent is suspending" (:102): `DELETE FROM snd_files` through the agent's store.
- "should not wait for file marked deleted while agent is suspending" (:104): `UPDATE snd_files SET deleted = 1` through the agent's store.
- "should not wait for file marked failed while agent is suspending" (:106): `UPDATE snd_files SET failed = 1` through the agent's store.
- "should not wait for file after agent client is closed" (:108): `disconnectAgentClient`, then `resumeAgentClient`.
- "should not access database when suspending while database is suspended" (:726):
  - XFTP server down; file of 128 KB started;
  - suspend timeout 0;
  - while the test holds the agent store connection, `suspendAgent` with timeout 60 s returns within 5 s.
- "should not wait for file removed by TTL cleanup while agent is suspending" (:737):
  - cleanup after 1 s and every 1 s; `sndFilesTTL` 1 s;
  - XFTP server down; file of 128 KB started;
  - suspend timeout 60 s: `SUSPENDED` within 10 s, after the cleanup removes the expired file; events of the file before it are skipped.
- "should not wait for file resumed at worker start" (:748):
  - XFTP server down; file of 128 KB started by agent 1;
  - agent 2 on the same database resumes it at `xftpStartWorkers`;
  - after 0.5 s, suspend timeout 60 s: `SUSPENDED` within 5 s.
- "should stop uploads when sending network is suspended while agent is suspending" (:760):
  - `AOSndNetwork` begun by the test; file of 128 KB started;
  - suspend timeout 1 µs: `SFDONE` absent for 3 s;
  - after the test ends `AOSndNetwork`, `SUSPENDED` within 5 s.
- "should retry creating file chunks while agent is suspending" (:773):
  - XFTP server down; file of 128 KB started; suspend timeout 60 s;
  - server started after 3 s: `SFDONE` within 30 s;
  - after `xftpDeleteSndFileInternal`, `SUSPENDED` within 5 s.
- "should retry uploading file chunks while agent is suspending" (:787):
  - file of 17 MB started; the server is stopped after the first `SFPROG`;
  - suspend timeout 60 s; server started after 1 s: `SFDONE` within 30 s;
  - after `xftpDeleteSndFileInternal`, `SUSPENDED` within 5 s.
- "should remove counted file when its deletion fails" (:804):
  - XFTP server down; file of 128 KB started;
  - agent store closed: `xftpDeleteSndFileInternal` throws, and the set is empty.
- "should keep counted files when database query fails at suspension start" (:815):
  - XFTP server down; file of 128 KB started;
  - agent store closed; suspend timeout 60 s: the set still contains the file.
- "should wait for counted file again after agent is in foreground" (:826):
  - XFTP server down; file of 128 KB started;
  - suspend timeout 0.5 s: `SUSPENDED` within 5 s;
  - `foregroundAgent`; suspend timeout 60 s: `SUSPENDED` absent for 1 s;
  - after `xftpDeleteSndFileInternal`, `SUSPENDED` within 5 s.

`tests/AgentTests/FunctionalAPITests.hs`, "Suspending agent":
- "should send messages queued after file is sent before agent is suspended" (:3137):
  - b starts a file, suspend timeout 60 s;
  - once `sndFilesOp` is suspended, the `opSuspended` flags of `rcvNetworkOp`, `sndFilesOp`, `msgDeliveryOp`: `[True, True, False]`;
  - after `SFDONE`, `sendMessage` and `xftpDeleteSndFileInternal`: `[True, True, True]`;
  - `SENT`, then `SUSPENDED` within 5 s;
  - a receives the message.
