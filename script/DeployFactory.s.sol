// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "forge-std/Script.sol";
import "../src/OpenBSKTFactory.sol";

contract DeployFactory is Script {
    function run() external returns (OpenBSKTFactory factory) {
        address usdc = vm.envAddress("USDC_ADDRESS");
        vm.startBroadcast();
        factory = new OpenBSKTFactory(usdc);
        vm.stopBroadcast();
    }
}
