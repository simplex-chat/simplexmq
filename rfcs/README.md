# SimpleX Network Protocol Specifications — Governance and Evolution (draft)

## Why this document exists

SimpleX Network protocol specifications must evolve as the network grows. This document defines how specifications change, who governs those changes, and how the history of changes is preserved.

### Lessons from the web: why ratcheted governance matters

The web's governance history demonstrates both the necessity of consortium governance and the dangers of getting the transition wrong.

[Tim Berners-Lee invented the web in 1991](https://home.cern/science/computing/birth-web/short-history-web). [Netscape took over in 1994](https://en.wikipedia.org/wiki/Netscape_Navigator), driving rapid innovation as a single company — SSL, cookies, JavaScript, and the features that made the web commercially viable. In 1994, [W3C was founded](https://www.w3.org/about/history/) as a consortium hosted across multiple independent institutions (MIT in the US, INRIA/ERCIM in Europe, Keio University in Japan, later Beihang University in China) to govern web standards.

The transition from company-led innovation to consortium governance was abrupt rather than gradual. Netscape's decline (accelerated by the [browser wars](https://en.wikipedia.org/wiki/Browser_wars) and [AOL acquisition](https://cybercultural.com/p/1999-the-fall-of-netscape-and-the-rise-of-mozilla/)) transferred control to a standards body that prioritized process over progress. The result was [a lost decade of web stagnation](https://eev.ee/blog/2020/02/01/old-css-new-css/): CSS 2.0 shipped in 1998; CSS 2.1 didn't reach Candidate Recommendation until 2004 and wasn't finalized until 2011. W3C pursued XHTML and rejected proposed enhancements to HTML, until frustrated engineers from Apple, Mozilla, and Opera formed [WHATWG in 2004](https://en.wikipedia.org/wiki/WHATWG) to build HTML5 outside W3C's process. The abrupt governance transition, without a mechanism to balance community guarantees against the imperative to continue evolving the product at pace, dramatically slowed web evolution at the time it was needed most.

Then in 2023, [W3C restructured from a multi-host consortium into a single 501(c)(3) nonprofit entity](https://www.w3.org/press-releases/2023/w3c-le-launched/) — W3C Inc, incorporated in the US. The previous structure distributed governance across four independent university hosts in different countries, making capture by any single entity structurally difficult. The new structure concentrates governance in a single legal entity with a board of directors. While presented as modernization, this effectively ended the decentralized consortium model that had protected web standards for nearly three decades.

### The governance double ratchet

SimpleX follows the same Netscape-to-consortium evolution path, but with two ratchets designed to prevent both failure modes — stagnation from premature governance transfer, and capture from governance centralization:

- **Licensing ratchet**: all contributed IP is licensed under AGPLv3 (software) and Creative Commons (documentation), perpetually and irrevocably. What is licensed cannot be unlicensed. If a Party transfers Licensed IP, the licensing obligations transfer with it.

- **Governance ratchet**: power can be given to the SimpleX Network Consortium, but never taken back. The Consortium Agreement requires unanimous approval of all Governing Parties for changes to the agreement itself, IP policy, and admission or removal of parties.

The ratcheted transition is not just a clever device — it is a historically proven imperative. It allows the company to continue driving rapid product innovation (as Netscape did for the web) while incrementally and irreversibly transferring governance to the consortium, without the abrupt handover that stalled web evolution or the centralization that later undermined it.

### Specification governance via the Consortium Agreement

The SimpleX Network Consortium Agreement (being deployed in 2026) establishes two levels of intellectual property governance: **Licensed IP** (all contributed protocol specifications, software, and documentation, licensed perpetually and irrevocably) and **Core IP** (the subset essential to the network, requiring consortium governance to change). The distinction between these levels and how they map to the RFC process is described in [Standard vs Core specifications](#standard-vs-core-specifications) below.

## Specification change process: protocol specifications and RFCs

Protocol knowledge lives in two places:

### `protocol/` — Consolidated specifications

Each file is a complete, self-contained description of a protocol as it exists today. Like consolidated legislation in the UK legal system: the full current law in one document, not a patchwork of amendments.

Consolidated specifications are maintained on every code change that affects protocol behavior. With LLMs, the cost of maintaining consolidated documents collapses — reworking prose to incorporate a new RFC is now inexpensive relative to the value of a single authoritative document per protocol.

Implementers read `protocol/`. They should never need to reconstruct current behavior from a base spec plus a chain of RFCs.

### `rfcs/` — Protocol evolution commits

Each RFC describes a single change to a protocol specification. RFCs are the atomic unit of protocol evolution — analogous to commits in version control, or amending acts in legislation.

An RFC is not part of the protocol specification. It becomes part of the specification only when embedded into the consolidated `protocol/` document. The RFC itself remains as a permanent historical record of what changed, when, and why.

## RFC lifecycle

```
                  ┌——> done/ ——> standard/
draft (root) ——>──┤
                  └——> rejected/
```

### Draft — `rfcs/*.md`

A proposal for a protocol change. Not yet implemented. Active proposals live in the `rfcs/` root directory.

Named by proposal date: `YYYY-MM-DD-topic.md`.

A draft may be rejected if the proposal is considered but not accepted for implementation.

### Done — `rfcs/done/`

Implemented in code. The protocol change described by this RFC exists in the codebase, but the RFC has not yet been verified against the actual implementation (code may have diverged from the proposal during implementation).

### Standard — `rfcs/standard/`

Verified against the actual implementation and synchronized with code. The RFC accurately describes what was implemented. This is a permanent historical record — standard RFCs are never modified or removed.

On promotion to standard, the RFC is:
1. Renamed from proposal date to standardization date: `YYYY-MM-DD-topic.md` (new date, same topic slug)
2. Updated with a document history header capturing the full lifecycle
3. Embedded into the corresponding `protocol/` consolidated specification

The `protocol/` document references embedded RFCs by name (e.g., "Private message routing added by RFC 2023-09-12-second-relays, standardized 2026-XX-XX"), similar to UK legislation citing the amending act for each clause.

Protocol version numbers make it clear which RFCs are included in which protocol revision — no separate tracking is needed.

### Rejected — `rfcs/rejected/`

Draft proposals that were considered but not accepted for implementation. Only drafts move to rejected — once an RFC is implemented (done/), it proceeds to standard/ after verification. Preserved for historical record of design decisions.

### Document history header

Every RFC in `standard/` carries a history header:

```
---
Proposed: YYYY-MM-DD
Implemented: YYYY-MM-DD
Standardized: YYYY-MM-DD
Protocol: simplex-messaging v9 (or whichever protocol this amends)
---
```

## Governance

SimpleX Network follows the Netscape-to-W3C evolution path, with ratcheted rather than abrupt transitions:

| Phase | Period | Governance | Development process |
|-------|--------|-----------|-------------------|
| Protocol invented | 2020 | Two people | Prototype developed |
| SimpleX Chat Ltd | 2022 | One company | Product-first: code leads, specs follow |
| SimpleX Network Consortium | 2026 | Agreement of SimpleX Chat Ltd and non-profit entities | Product-first for standard; standards-first for core |
| Decentralized governance | Future | TBD (DAO research ongoing) | Standards-first |

### Current: product-first development

SimpleX protocols currently follow a product-first development process: requirements drive code, code drives specification. RFCs are written as design proposals before implementation, but implementation details are figured out in code. Consolidated protocol specifications in `protocol/` are then amended to match the implementation.

This process is governed by SimpleX Chat Ltd as the IP Holding Party under the Consortium Agreement.

Any Specification Author (as defined in the Consortium Agreement) may propose RFCs. Acceptance and standardization decisions are made by SimpleX Chat Ltd during the current product-first phase.

### Standard vs Core specifications

The distinction between standard and core maps directly to the two levels of IP governance in the Consortium Agreement, and reflects the difference between product-first and standards-first development:

**Standard** — Licensed IP, not yet under consortium governance. Governed by the company.

All contributed protocol specifications are Licensed IP under the Consortium Agreement. Standard specifications follow product-first development: the company can evolve them with product needs, and they must be maintained on every code change that affects protocol behavior.

Standard specifications live in `rfcs/standard/` and `protocol/`.

**Core** — Governed IP, governed by the consortium.

A subset of standard specifications will be designated as Core IP under the Consortium Agreement. Core specifications will follow standards-first development: specification changes must be agreed via Governing Decision before code changes.

This is a legally binding commitment. Once Licensed IP is included in Core IP, the company that owns the code cannot unilaterally change it — even though they own the code, the Consortium Agreement requires a Governing Decision for any change to Core IP. This protects the fundamental properties of the network (privacy, security, decentralization) from unilateral modification by any single party.

The designation of specific specifications as Core IP is itself a Governing Decision requiring unanimous approval. The transition will happen incrementally as protocols stabilize — the governance ratchet ensures that each designation is irreversible.

The exact mechanism for distinguishing core from standard within the RFC and protocol folder structure is TBD — it will be decided as the first protocols are designated as Core IP.

### Future: standards-first development

As more protocols are designated as Core IP, development naturally transitions to a standards-first process for a growing portion of the protocol suite. The governance ratchet ensures this transition is gradual and irreversible — each protocol that becomes core gains the protection of consortium governance permanently, while remaining standard protocols continue to evolve at product pace.

## Current state

| Location | Contents | Count |
|----------|----------|-------|
| `protocol/` | Consolidated specs (SMP v9, Agent v5, XFTP v2, XRCP v1, Push v2, PQDR v1) | 6 specs + overview |
| `rfcs/` root | Active draft proposals | 19 |
| `rfcs/done/` | Implemented, not yet verified | 25 |
| `rfcs/standard/` | Verified against implementation | (to be populated) |
| `rfcs/rejected/` | Draft proposals not accepted | 7 |
