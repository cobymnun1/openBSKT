// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "forge-std/Script.sol";
import "../src/OpenBSKT.sol";
import "../src/OpenBSKTFactory.sol";

contract CreateThrowaway is Script {
    function run() external returns (address basket) {
        OpenBSKTFactory factory = OpenBSKTFactory(vm.envAddress("FACTORY_ADDRESS"));
        address signer = vm.envAddress("ROUTE_SIGNER");
        address[] memory tokens = new address[](3);
        tokens[0] = 0x226A2FA2556C48245E57cd1cbA4C6c9e67077DD2;
        tokens[1] = 0xA81a52B4dda010896cDd386C7fBdc5CDc835ba23;
        tokens[2] = 0x0C03Ce270B4826Ec62e7DD007f0B716068639F7B;
        uint256[] memory weights = new uint256[](3);
        weights[0] = 3334;
        weights[1] = 3333;
        weights[2] = 3333;

        vm.startBroadcast();
        basket = factory.createBasket(
            "Throwaway BIO TRAC TIG",
            "BTIG",
            "base-test://bio-trac-tig",
            tokens,
            weights,
            signer,
            type(OpenBSKT).creationCode
        );
        vm.stopBroadcast();
    }
}
