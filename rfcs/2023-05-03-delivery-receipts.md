# Delivery receipts

## Problems

User experience - users need to know that the messages are delivered to the recipient, as this confirms that the system is functioning.

The downside of communicating message delivery as it confirms that the recipient was online, and, unless there is a delay in confirming, can be used to track the location via the variation in network latency. So delivery receipts should be delayed with a randomized interval and should be opt in.

Another problem of message receipts is that they increase network traffic and server load. This could be avoided if delivery receipts are communicated as part of normal message delivery flow.

Some other existing and planned features implicitely confirm message delivery and, possibly, should depend on message delivery being enabled:
- agent message to resume delivery when quota was exceeded (implemented, [rfc](./2022-12-27-queue-quota.md))
- agent message to re-deliver skipped messages or to re-negotiate double ratchet.

## Solution

There are three layers where delivery receipts can be implemented:
- chat protocol. Pro: logic of when to deliver it is decoupled from the message flow, Con: extra traffic, can only work in duplex connections.
- agent client protocol. Pro: can be automated and combined with the protocol to re-deliver skipped messages. Con: extra traffic.
- SMP protocol. Pro: minimal extra traffic, Con: complicates server design as it would require pushing receipts when there is no next message.

The last approach seems the most promising for avoiding additional traffic:
- modify client ACK command to include whether delivery receipt should be provided to sender, and, possibly, any e2e encrypted data that should be included in the receipt (e.g., that the receiving client already saw this message in case we use "feedback" variant of roumor-mongering protocol for groups).
- server would manage delaying of the receipts, by randomizing the time after which the receipt will be available to the sender, and by combining the receipts when possible.
- modify response to SEND command to include any available delivery receipts.
- add a separate delivery receipt that will be pushed to the sender in the connection where the message was received by the server.
