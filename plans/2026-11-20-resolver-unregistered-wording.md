# Resolver: wording of an unregistered name

To be merged together with simplex-network/ens-contracts#51, the dispute period for sponsored registrations.

## Problem

After #51, the guardian or the admin can end a `.simplex` registration in its dispute period, and the registrar sets the name's expiry to 0; no renewal is accepted before the dispute period ends. The v1 route answers every name with expiry 0 with the message "this name has never been registered". The resolver's README describes `unregistered` as never registered and `registered` as held until `expires`, and the protocol describes a registered name as held until `expires`.

## Decisions

| # | Decision |
|---|---|
| 1 | `status` and `error` stay `unregistered` |
| 2 | message of a v1 404 `unregistered`: "this name is not registered" |
| 3 | price quotes of a name with expiry 0 unchanged |

## Changes

`scripts/resolver/service/snrc-resolve.py`:

- the message of decision 2
- the docstring of `read_oracle_prices`: a quote is safe for a name with expiry 0

`scripts/resolver/README.md`:

- `expires` and `registered`: unless the registration is ended in its dispute period
- `unregistered`: also an ended registration
- the zero-expiry paragraph, with the dispute period defined
- the error example
- the label of a hashed query: recorded labels stay recorded
- what a hashed query hides
- the premium paragraph

`protocol/simplex-messaging.md`:

- a hashed query of a name never registered
- the dispute period, after the registration types

`scripts/resolver/service/test_snrc_resolve.py`:

- new, in `ErrorCodeTests`: a name with expiry 0 answers 404 with "this name is not registered"
- three test names that equate expiry 0 with never registered
