# Self-hosting a basket signer

The signer is an ordinary EOA controlled by the basket manager. It signs only
quote metadata and route hashes; it never receives user funds and its private
key is never sent to the contract.

1. Deploy `OpenBSKTFactory` with the chain's USDC address.
2. Call `createBasket` with the `OpenBSKT` creation bytecode, desired token
   list, 10,000-bps weights, metadata URI, and signer address. The creation
   bytecode is supplied as calldata so the factory stays below EIP-170's
   contract-size limit.
3. Deploy one `OpenBSKTZeroExAdapter` or `OpenBSKTAerodromeAdapter` per venue.
4. The manager NFT holder allowlists those adapter addresses with `setRouter`.
5. Run the read-only quote service with the venue API key in an environment
   variable.
6. Sign the route hash using the current `routeNonce`. Rotate by offering a
   new signer and having it call `acceptRouteSigner`.

The signer must reject expired quotes, use exact token amounts, and bind the
chain ID, basket address, operation, nonce, route hash, receiver-independent
input amount, and quoted shares. A compromised signer can misprice issuance,
so users should choose a signer operator they trust or run their own.

No quote-service private key, API key, JWT, or router credential belongs in
factory or basket constructor arguments.
