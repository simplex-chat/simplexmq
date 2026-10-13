# names-web

Prototype page for buying a SimpleX name in the browser, without a wallet extension. It makes a wallet for the name, shows its redemption code, and prepares the two requests the store service sends to the chain: the commitment to commit, and the registration with the owner's signed `RegisterName` intent.

## Setup

```bash
cd names-web
npm install
npm run build
```

## Running tests

```bash
# The TypeScript output against the Haskell implementation (from repo root)
cabal test --test-option=--match="/Names Web/"

# The page in headless Chromium
cd names-web && npm run test:page

# Also register the page's name on a hardhat node running the contracts,
# from a compiled checkout of ens-contracts PR #35
ENS_CONTRACTS_DIR=../path/to/ens-contracts npm run test:page
```

## Development

```bash
npm run dev
```
