# SMP confirmation timeout recovery

## Problem

When sending an SMP confirmation a network timeout can lead to the following race condition:
- server receives the confirmation while the joining party fails to receive the server's response;
- joining party deletes the connection together with credentials sent in the confirmation for securing the queue;
- initiating party will receive the confirmation from the server and secure the queue;
- on subsequent attempt to join via the same invitation link initiating party will generate new credentials and fail authorization.

This renders the joining party permanently unable to join via that invitation link and complete the connection.

## Solution

A possible solution is to keep and try to reuse same credentials on subsequent attempts:
- joining party has to remember invitation link when saving the connection;
- if SMP confirmation fails due to network timeout joining party doesn't delete the connection and keeps the credentials;
- when joining, joining party checks whether such invitation link was already used for a connection, if yes:
  - joining party tries to send SMP confirmation with the same credentials;
  - if this SMP confirmation fails with authorization error (for example it can happen due to race condition explained above) joining party tries to send HELLO message;
  - if HELLO message fails with authorization error (it can happen if connection was deleted or secured with different credentials), the recovery is no longer possible and connection can be deleted.
