# Resolver: wording of an unregistered name

Merges with simplex-network/ens-contracts#51, the dispute period for sponsored registrations.

## Problem

After #51, the guardian or the admin can end a `.simplex` registration in its dispute period, and the registrar sets the name's expiry to 0. The resolver answers every name with expiry 0 with the message "this name has never been registered", and its README defines `unregistered` as never registered.

## Decisions

| # | Decision |
|---|---|
| 1 | `status` and `error` stay `unregistered` |
| 2 | message of a 404 `unregistered`: "this name is not registered" |
| 3 | price quotes of a name with expiry 0 unchanged |

## Changes

`scripts/resolver/service/snrc-resolve.py`:

- the message of decision 2
- the docstring of `read_oracle_prices`: a quote is safe for a name with expiry 0

`scripts/resolver/README.md`:

- the status table: `unregistered` covers an ended registration
- the zero-expiry paragraph
- the error example
- the premium paragraph

`scripts/resolver/service/test_snrc_resolve.py`:

- new: the message of a name with expiry 0 does not state that it was never registered
- two test names that equate expiry 0 with never registered
