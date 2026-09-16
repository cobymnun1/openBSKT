// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "forge-std/Script.sol";
import "../src/OpenBSKT.sol";

contract FundThrowaway is Script {
    uint256 private constant DEPOSIT = 0.001 ether;

    function run() external {
        OpenBSKT basket = OpenBSKT(payable(vm.envAddress("BASKET_ADDRESS")));
        uint256 key = vm.envUint("DEPLOYER_PRIVATE_KEY");
        uint256 quotedShares = DEPOSIT;
        uint256 deadline = block.timestamp + 1 hours;

        OpenBSKT.Swap[] memory swaps = new OpenBSKT.Swap[](3);
        (address[] memory tokens,) = basket.getConstituents();
        for (uint256 i; i < swaps.length; ++i) {
            swaps[i] = OpenBSKT.Swap({
                router: address(0), tokenIn: address(0), tokenOut: tokens[i], amountIn: 0, minOut: 0, value: 0, data: ""
            });
        }

        bytes32 payload = keccak256(
            abi.encode(
                address(basket),
                block.chainid,
                keccak256("DEPOSIT_ETH"),
                basket.routeNonce(),
                quotedShares,
                DEPOSIT,
                keccak256(abi.encode(tokens, _weights(swaps.length))),
                keccak256(abi.encode(swaps)),
                deadline
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", payload));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);

        vm.startBroadcast();
        basket.depositETH{value: DEPOSIT}(quotedShares, quotedShares, deadline, swaps, abi.encodePacked(r, s, v));
        vm.stopBroadcast();
    }

    function _weights(
        uint256 length
    ) private pure returns (uint256[] memory weights) {
        weights = new uint256[](length);
        weights[0] = 3334;
        weights[1] = 3333;
        weights[2] = 3333;
    }
}
