# DSCB example and migration boundary

The DSCB configuration in `examples/dscb.json` is an example basket only. It
is deliberately not compiled into the generic factory and it does not grant
the new contracts control over the existing DSCB basket or its LP token.

The old deployment has a controller and a separate reserve/LP contract. A safe
migration must therefore be an explicit user action:

1. Fork-test every selected token, decimals value, transfer behavior, and
   route adapter against Base state.
2. Deploy a new basket and independently verify its constituent/weight events.
3. Let users redeem old DSCB shares through the old path or transfer them to a
   separately audited migration adapter.
4. The adapter can call the old redemption path, verify received assets by
   balance delta, and contribute those assets to the new basket. It must never
   assume the controller holds the reserves.
5. Keep the current sell UI pointed at the existing DSCB flow until those
   checks and a security review pass. Only then replace its sell target with
   the new basket's direct `redeemETH`/`redeemUSDC` paths.

No migration adapter is included in the generic core because its old-contract
ABI, permissions, and deployment address would make openBSKT non-generic.
