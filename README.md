# openBSKT

Generic, permissionless multi-asset basket contracts for Base-compatible EVM
chains. The core has no DSCB token list, API key, JWT, signer private key, or
venue address.

> **Experimental software — audit requested.** This repository has not received
> an independent professional audit and must not be treated as production-safe.

## What openBSKT is

openBSKT is an open basket-making protocol: anyone can deploy a basket with
their own constituents, weights, metadata, route signer, and manager. BIO, TRAC,
TIG, and the DSCB example are configuration data, not protocol assumptions.

The design is **ERC-7621-inspired** and follows the broad model of a
multi-asset basket token with proportional contribution/withdrawal and
manager-controlled composition. This repository does not claim formal ERC-7621
conformance or certification; integrators must verify the exact interface and
behavior they require.

## Contracts

- `OpenBSKTFactory` lets anyone create a basket with its own constituents,
  weights, metadata URI, route signer, and supplied `OpenBSKT` creation
  bytecode. Supplying creation bytecode as calldata keeps the factory below
  EIP-170's contract-size limit.
- `OpenBSKT` is the basket share token. It supports direct proportional
  contribution/withdrawal, ETH/USDC route wrappers, a pause switch, a
  timelocked composition change, and a signer nonce.
- `OpenBSKTManagerNFT` is a real ERC-721. Its holder controls only the
  associated basket's manager functions; it cannot withdraw reserves.
- `OpenBSKTExecutionAdapter` is a fixed-target adapter. Deploy one per approved
  0x or Aerodrome venue and allowlist that adapter in the basket. Route calldata
  is still supplied by the caller, but the adapter target is immutable and
  output is checked by balance delta.

The route signer is an off-chain operator selected by each basket manager. It
signs quote parameters; it does not custody user funds. The manager NFT holder
controls composition, pause state, router allowlisting, signer rotation, and
rebalancing for that basket.

## Security model and known limitations

- A route signer is trusted to price shares and authorize routes. A compromised
  signer can authorize bad pricing.
- Managers are trusted to choose routers and composition. The manager NFT is a
  transferable control key.
- Failed routes are intentionally non-atomic: successful routes settle, failed
  portions remain as constituent assets or cash, and redemption can burn only
  the successful-weight portion.
- The quote service is an example read-only HTTP wrapper. It does not sign
  transactions or custody funds. Production operators must run their own
  signer and protect API credentials.
- The included Base deployment is a throwaway test deployment, not a protocol
  endorsement. Fork tests and independent review are still required.

The route signer signs:

```text
basket, chain id, operation, nonce, quoted shares, input amount,
composition hash, keccak256(abi.encode(swaps)), deadline
```

Only the signer address is stored on-chain. Private keys and API credentials
stay in the operator's quote service environment.

## Partial failures

Deposit routes are isolated. A reverted route leaves its input in the basket's
ETH/USDC cash reserve and does not revert successful routes. The route signer
authorizes the share amount, so a self-hosted signer can price the cash reserve
consistently with its quote policy.

Redemption routes are also isolated. Failed or below-minimum routes leave the
corresponding constituent and residual claim in the basket. Successful output
is paid, and any retained ETH/USDC is tracked as cash. The residual share
amount uses the configured target-weight rule; this is intentionally not a NAV
oracle.

## Local commands

```sh
cd openBSKT
/home/coby/.foundry/bin/forge test
/home/coby/.foundry/bin/forge build
```

The Base fork smoke test uses real Base USDC and WETH without submitting
transactions:

```sh
BASE_RPC_URL=https://mainnet.base.org \
  /home/coby/.foundry/bin/forge test --match-contract BaseForkTest
```

The audit harnesses are separate from production contracts:

```sh
/home/coby/.foundry/bin/forge test --fuzz-runs 256
medusa fuzz --config medusa.json
PATH=/home/coby/.foundry/bin:$PATH halmos --function check_ --statistics
```

`test/AdversarialFuzz.t.sol` covers failed routes, retained failed-redemption
weights, unapproved/same-token routes, and a manager-owned reentrant router.

`test/MedusaHarness.sol` performs a complete constructor deployment of a
generic basket and exposes invariant-style `property_` functions. The
`medusa.json` target is that harness, so Medusa does not fuzz an unconfigured
production constructor. Foundry emits AST, metadata, storage layout, and
compiler build-info artifacts; these preserve source maps for source-aware
analyzers.

The quote service under `quote-service/` is read-only:

```sh
cd quote-service
npm install
npm run check
```

It only fetches 0x quote data and constructs validated route-plan values. It
does not sign transactions or hold user funds.

## Example configuration

`examples/dscb.json` contains a separate 18-token example based on the local
50k market-cap CSV, including TRAC and excluding ALVA. Every token has a 2%
floor and the remaining 64% is market-cap weighted. It is not imported by the
generic contracts. The icon and description are example metadata only.

Do not deploy or migrate funds until fork tests cover the selected tokens,
decimals, fee-on-transfer behavior, adapter calldata, signer rotation,
partial failures, and an independent security review.
