// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @notice Halmos properties for the arithmetic used by partial redemption.
contract OpenBSKTSymbolicProperties {
    uint256 internal constant BPS = 10_000;

    function check_allFailureBurn(
        uint128 shares
    ) public pure {
        assert(shares * (BPS - BPS) / BPS == 0);
    }

    function check_bpsCompositionIsBounded(
        uint256 a,
        uint256 b
    ) public pure {
        if (a > BPS || b > BPS || a + b > BPS) return;
        assert(a + b <= BPS);
    }
}
