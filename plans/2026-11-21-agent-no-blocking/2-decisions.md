# Decisions

Place "conversation" is the maintainer's chat with the agent that writes this plan; "decision page" is the private answer page of that conversation.

## Scope

D1. In scope: server requests without any held lock that other calls take; the acknowledgement deadlock, with acknowledgements ordered through the database; the crash window in message storage. Rotation defects move out (D36). Rules R1, R2, R4, R7.
- Date: 2026-11-25
- Place: conversation
- Words: "yes, this is not acceptable, and we cannot do any network IO while holding any locks that any other calls may use. Network calls only need global synchronization when ordering is essential, and we already use database for it" … "not acceptable too. but at the same time ACKs must be ordered, if you change order of acks, and simply write them from threads, then they will stop being ordered. So ACKs must be delivered via the database. Async commands achieve it I think." … "that might belong here, as it's the same code."

D2. Out of scope: API calls that wait for space in the event queue while the app holds its own locks.
- Date: 2026-11-25
- Place: conversation
- Words: "this is the worst issue and I don't think we can solve it in this scope - it requires rethinking, and maybe partially applying ideas from ep/conc-msgs. We have fundamental issue with this deadlock I think, bringing it in scope of 2095 is wrong. Unless you see simple and elegant solution here."

D3. Out of scope: the order of link data. It is a separate change, with versioned link data and RKEY.
- Date: 2026-11-25
- Place: conversation
- Words: "Links orderring - I'd keep out of scope." … "I see it as a separate problem that requires versioning and support for RKEY."

D4. The protocol client is solid in its reviewed form; a further change to it is raised with ep.
- Date: 2026-11-25
- Place: conversation
- Words: "client.hs seems quite solid to me now - are you changing it too?"

D5. Connection deletion keeps master's structure. Deletions are not moved to command rows. A queue already marked deleted is deleted with its connection, by a fix without command rows. Rule R12.
- Date: 2026-11-26
- Place: conversation
- Words: "this needs a simple fix that doesn't require moving deletions to commands" … "what was the reason to change it in the first place?"; on two DELs for one queue: "the problem is theoretic and causes zero user issues."

D6. Downgrade is not a design case. Rule R11.
- Date: 2026-11-26
- Place: conversation
- Words: "I don't think we need to worry about downgrade - firsltly, from which to which version? second, it's a super edge case, we don't need to support downgrade during handshake. Appstores do not even allow downgrades."

## Objective

D22. No regression from master; every common problem in scope is solved; an edge case may be left only when it is complex to solve. All rules.
- Date: 2026-11-27
- Place: conversation
- Words: "no, we can't have absolutely any regression from master" … "The non-negotiable objective is: - zero regressions from master - solve all common problems - possibly accept some edge cases if they are complex to solve."

D23. The one edge case accepted: a receipt is skipped when the next message of the queue starts ratchet synchronization before the receipt is stored. Ratchet synchronization is reworked separately. Rule R4.
- Date: 2026-11-27
- Place: conversation
- Words: "this is the only item in the category rare edge case that can be accepted, especially because ratchet resync needs a separate rework anyway - and it's out of scope here"

D24. Accept becomes asynchronous. A failed acceptance is retried by the agent, and when it fails for good it is shown as a state of the contact, not as an alert. Rule R9.
- Date: 2026-11-27
- Place: conversation
- Words: "both async command must retry, and having exhausted retries it must change state of the chat visibly, so failure must not be silent. It won't be an alert, obviously, but it will be a state instead." … "I decided that accept becomes background"

D32 (Q13). Reject stays synchronous and unchanged; its notice with notify=on is addressed when reject is reworked. Rule R9.
- Date: 2026-11-27
- Place: conversation
- Words: "reject never sends anything to network. Reject can of course stay sync." … "it needs to be addressed later when we implement reject, currently it's not used"

D33 (Q14). Accept returns at once; bots wait for ContactSndReady before they send, as the apps do. Rule R9.
- Date: 2026-11-27
- Place: conversation
- Words: "yes, bots will have to change to wait for event that we need to add anyway, as it changes UI state. UI also won't allow sending messages until event arrives. That's ok."

D34 (Q16). A queue's recipient key is stored with a record of the queue before NEW is sent; the record is removed on the response, used to delete the queue after a late response, or removed by the cleanup manager. Rule R8.
- Date: 2026-11-27
- Place: conversation
- Words: "it's not request key, it's queue's recipient key, and of course it must be saved, together with queue record before the request is sent - then it can be either removed on response, or record removed in cleanup manager"

D37 (Q18). A manual accept whose confirmation expires after the acceptance ended is accepted as a rare case: the contact never connects and "failed to accept" is not shown. The code marks it with a TODO for the separate work that bounds unbounded cases in time. Rule R9.
- Date: 2026-11-27
- Place: conversation
- Words: "ok, with TODO and timeout. We have a separate case to bound in time all unbounded cases, can be left here"

D38. The chat commands that hold a group lock across synchronous agent network calls (adding a member, adding a member via a group, joining a group, creating a group link, adding relays) validate under the lock, call the agent without it, and check again and commit under it, in the chat pull request of this change. Rule R9.
- Date: 2026-11-28
- Place: conversation
- Words: "yes", to: "Adding a member, joining a group, creating a group link and adding relays hold the group lock across synchronous agent network calls. Meanwhile the chat's single event thread waits for that lock, so messages of all contacts stop while a server is slow. This is the same class as accept, on the chat side. I recommend the plan's chat pull request."

D39. Races of master in message delivery that this change also removes, by cause: in simplexmq, resuming stored deliveries and commands without waiting for every server's subscriptions (C2), deleting a queue created while its connection is deleted (C6), the gaps of connection deletion (C7), resubscribing a queue whose message failed before its acknowledgement was stored (C8) and running commands in the order they were created (C10); in simplex-chat, an event never lowering a ready connection (C3). The redelivered direct message (C4) and C9 go to separate pull requests. Rules R2, R5, R12.
- Date: 2026-11-28
- Place: decision page of the races
- Words: the choices "#2095" for C2, C6, C7, C8, C10; "chat PR of #2095" for C1, C3; "separate PR" for C4, C9

D35 (Q16). Commands that wait for space in a full send buffer are dropped when their callers time out; the callers' retries send them again. Rule R1.
- Date: 2026-11-27
- Place: conversation
- Words: "what's the point sending the command after timeout, if whoever needed the queue no longer needs it and the only action is to remove, and there will be retry anyway? Better drop them, and let retry handle it"

D25. A queue whose creation response never arrives, because the session ended or the app stopped, stays on the server, documented; a later change can make the client choose queue ids, as for short links.
- Date: 2026-11-27
- Place: conversation
- Words: "unavoidable, and compensating is more constly than ignoring. But we could switch to always deciding the ID, as we do for short contact address links later. Ok for now, just need documenting if it's not."

D26. Late responses are processed in every agreed case, NEW included, because retries cost more: they hold later commands of the queue, delay delivery and add traffic. Rule R8.
- Date: 2026-11-27
- Place: conversation
- Words: "the reason NOT to drop them is that retries have higher costs - both slowing down all commands to this queue, and blocking the message delivery, and traffic. If you don't understand why - ask. You are thinking very narrowly, there are wider benefits to process late responses in all cases we agreed, including NEW"

D27. A second join of one invitation waits, as on master. Rule R1.
- Date: 2026-11-27
- Place: conversation
- Words: "ok, not a problem, better than race."

D28. Synchronous calls get no command rows, because after D13 and D24 they are not needed. Replaces the rows of synchronous calls of D8.
- Date: 2026-11-27
- Place: conversation
- Words: "yes, of course they are not needed if we move these commands to async."

D30. Agent versions below 8 stay supported. Rule R11.
- Date: 2026-11-27
- Place: conversation
- Words: "yes, we can't do it. We must keep earlier versions."

D31. Frequent messages keep master's single read of their connection; rare messages whose decisions use state that steps under the connection lock change read the connection again after the lock and decide on that read, so that no such step changes it between that read and the message's last write. Rule R2.
- Date: 2026-11-27, 2026-11-28
- Place: conversation
- Words: "address change is rare, message is frequent. So the solution is to make address change wait while letting messages come through. Making messages do more work is a bad idea." … "Counter feels unelegant, and elegant solutions usually exist." … "if option 1 is sufficient, then it is of course the simplest and correct one" … "no, it was added to remove the window. Because we are lookign for a structural solution to solve the maximum number of problems, and not just narrow problem of locks"

## Design

D7. The change is the minimal one that solves every problem in scope, creates no new problem and keeps every guarantee. A corner case leads to a redesign, not to an added mechanism. A design with a known problem is not implemented. Rules R1 to R13.
- Date: 2026-11-25, 2026-11-26
- Place: conversation
- Words: "the point was to find _the minimal_ change that would: - solve all relevant problems - do not create any new problems and loses no guarantees" … "the goal is to reduce the total number of mechanisms. Corner cases call for rethinking the design from scratch not for adding mechanisms" … "no point implementing design with known problems." … "Then the aim is to find a minimal set of mechanisms, ideally 1, maybe 2, that would reason about these states and serialize or roll them back. Max would be one per entity."

D8. The design has three changes: connection locks never cover network requests; command records track concurrent processing; late responses are processed comprehensively. Its fourth change, command records for synchronous calls, is replaced by D28. Rules R2, R3, R8.
- Date: 2026-11-26
- Place: conversation
- Words: "so the primary changes in the design are: - split connection locks, so they never cover network requests - use command records to track concurrent processing - use command records for sync commands - process late responses comprehensively" … "ok, you must document the changes very attentively, and then verify it against the code, before it goes to analysis." … "ok, then command for sync command can be useful"

D9. A lock that, by design, only operations of the same kind take may be held across a request. Rules R1, R13.
- Date: 2026-11-26
- Place: conversation
- Words: "formal application of principle that clearly applied to contested locks only, not to locks that cannot be contested by design."

D10. Late responses to ACK and DEL are processed, as late SUB responses are, including deletions made outside command rows. Rule R8.
- Date: 2026-11-23, 2026-11-26
- Place: conversation
- Words: "we do not process late responses comprehensively - e.g. we process late SUB responses, but not late ACK and DEL responses" … "I think many defects can be fixed by a more comprehensive handling of late replies btw" … "also deletions can use it that happens outside of commands"

D11. Message delivery order and acknowledgement order are kept. Rules R3, R4.
- Date: 2026-11-23, 2026-11-26
- Place: conversation
- Words: "both double-ratchet and in-app presentation depend on ordering being preserved." … "breaking message delivery order breaks double ratchet, and breaking ack order would result in stuck delivery"

## Acknowledgements

D12. Acknowledgements stay asynchronous, through stored commands. The receipt is stored by the worker, after the server ACK as on master, and is skipped while ratchet synchronization is in progress. Rule R4.
- Date: 2026-11-25
- Place: decision page, option "In the background worker, just before the acknowledgement", whose consequences included the skip during ratchet synchronization; then conversation, on the order
- Words: "a"; then "we do async acks, right?" … "why can't they stay async?" … "why does it have to store receipt before sending it to server?" … "we need to solve known problem, database operation to create receipt is not a cost we know to be a problem"

## API and costs

D13. Synchronous agent functions that the chat does not use are removed, except those used inside asynchronous commands; at the least they are no longer exported. Tests are moved to the functions in use, after a coverage analysis. Rule R9.
- Date: 2026-11-26
- Place: conversation
- Words: "I propose we drop unused sync forms from code (unless they are used inside async commands). But at least stop exporting them. And amend the tests to test more what's used after coverage analysis."

D14. Every added store read and transaction is counted and its cost estimated. Rule R10.
- Date: 2026-11-26
- Place: conversation
- Words: "be careful with increasing reads and transactions, at least watch it for now, and estimate the extra costs"

## Protocol client

D15. A request whose caller stopped waiting is kept until its response arrives or its session ends. Rule R8.
- Date: 2026-11-24
- Place: conversation
- Words: "remove the periodic check"

D16. The thread that fills a response for its caller also writes the response's message to msgQ, before it fills the response variable; the requester writes nothing to msgQ. Sending fails at once when the client is disconnected, also after the send queue was full. Rule R1.
- Date: 2026-11-23, 2026-11-27
- Place: conversation
- Words: "write it to respnse var but do not write to msgQ from the command method, and instead have it written to msgQ in the same place that fills response var?" … "yes, push it" … "ifM (readTVar connected) (writeTBQueue sndQ t) (True <$ mapM_ failRequest rs) which creates the same pattern that can be now extracted from both, sendOrFail"; on writing msgQ before the response variable: "ok"

## Rotation

D17. This change fixes the crash window in message storage, in the code it rewrites. Rotation defects move to a separate rethink of queue rotation (D36). Rule R7.
- Date: 2026-11-25
- Place: decision page, option "Fix the three here, the others in later PRs"; conversation
- Words: "a"; "that might belong here, as it's the same code."

D36. Queue rotation behaves as on master. Its steps that wait for a server, its start and the abort take a lock of the connection that message processing does not take; each step checks again, after its request, the state master checks before it. Rotation defects are fixed in a separate rethink of queue rotation. Replaces D18 and D29. Rule R6.
- Date: 2026-11-27
- Place: conversation
- Words: "I honestly think we need a wider rething to queue rotation. Simply splitting lock - does it make rotation better or worse or same? was our motivation to fix it here simply because we touch this code or there was regression?" … "can we make them "not worse" cheaper?" … "ok, update the plan and analyse it again"

## Connection establishment

D19. The KEY handshake of connection establishment is removed; SMP client version 3, with sender-secured queues, is the minimum. Rotation with peers below agent version 8 keeps QKEY. Rule R11.
- Date: 2026-11-24
- Place: conversation
- Words: "I think we can drop old handshake - we no longer support clients that old - look at protocol versions (client and agent, and SMP - I don't think clients that old exist in the network)"

D20. A connection in the middle of the KEY handshake at the upgrade ends with a version error, and joining an invitation without a sender-secured queue is refused. Rule R11.
- Date: 2026-11-25
- Place: decision page, option "Fail them with a version error"
- Words: "a"

