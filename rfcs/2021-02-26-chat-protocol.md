# Chat protocol commands

This is a very rough draft of what commands / primitives are needed for chat protocol.

## Messages sent in Agent message envelope

- client message
  - message type
    - content message
      - text
      - file
        - audio
        - image
        - video
        - ...
        - other
      - link
      - form
      - widget (we may think about a different name) - any interactive application
    - derived messages
      - reply
      - forwarded
    - message update
    - message deletion
  - delivery type
    - async (via SMP) - default
    - sync (via WebRTC)
  - message content

- profile update
- group update
- invitations
  - to connect to me
  - group invitation
  - contact invitation
- message receipts
  - client app receipt
  - user receipt

## Chat server commands and messages/notification

- profile
  - create
  - update
  - get
  - list profiles
  - activate
  - delete
- contacts
  - add (generates invitation to profile)
  - accept (accepts invitation)
  - list contacts
  - update contact display name
  - update contact handle (local name)
  - get details
  - delete
- groups
  - create
  - invite contact to group
  - get one-time invitation to group
  - create open invitation to join group
  - list
  - delete
