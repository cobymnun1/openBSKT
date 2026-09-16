# UI integration gate

The current basket UI must not be pointed at an un-deployed or un-fork-tested
openBSKT address. Once a basket is deployed and verified, the sell control
should:

1. load the basket address and `getConstituents()` from configuration;
2. fetch one route plan per constituent from the self-hosted quote service;
3. request the route signer signature;
4. call `redeemETH` or `redeemUSDC` with a user-selected minimum output and
   deadline;
5. display `PartialRedeem` and `SwapSkipped` events instead of treating a
   partial redemption as a transaction failure.

The existing relay-dependent sell target should remain unchanged until the
DSCB migration checklist passes. This repository intentionally contains no
placeholder address that could cause the UI to send funds to the wrong
contract.
