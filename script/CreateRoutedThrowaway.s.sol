// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "forge-std/Script.sol";
import "../src/OpenBSKT.sol";
import "../src/OpenBSKTFactory.sol";
import "../src/OpenBSKTExecutionAdapter.sol";

contract CreateRoutedThrowaway is Script {
    uint256 private constant AMOUNT_PER_ROUTE = 333_333_333_333_333;
    uint256 private constant TOTAL_ETH = AMOUNT_PER_ROUTE * 3;
    uint256 private constant QUOTED_SHARES = 1 ether;
    address private constant ADAPTER = 0x3Cb877E9F4a2319f3ff56245A0515B35C34A859a;
    address private constant BIO = 0x226A2FA2556C48245E57cd1cbA4C6c9e67077DD2;
    address private constant TRAC = 0xA81a52B4dda010896cDd386C7fBdc5CDc835ba23;
    address private constant TIG = 0x0C03Ce270B4826Ec62e7DD007f0B716068639F7B;

    function run() external returns (address basket) {
        OpenBSKTFactory factory = OpenBSKTFactory(vm.envAddress("FACTORY_ADDRESS"));
        uint256 key = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address[] memory tokens = new address[](3);
        tokens[0] = BIO;
        tokens[1] = TRAC;
        tokens[2] = TIG;
        uint256[] memory weights = new uint256[](3);
        weights[0] = 3334;
        weights[1] = 3333;
        weights[2] = 3333;
        uint256 deadline = block.timestamp + 1 hours;

        OpenBSKT.Swap[] memory swaps = new OpenBSKT.Swap[](3);
        swaps[0] = _swap(BIO, vm.envBytes("BIO_DATA"), vm.envUint("BIO_MIN"));
        swaps[1] = _swap(TRAC, vm.envBytes("TRAC_DATA"), vm.envUint("TRAC_MIN"));
        swaps[2] = _swap(TIG, vm.envBytes("TIG_DATA"), vm.envUint("TIG_MIN"));

        vm.startBroadcast();
        basket = factory.createBasket(
            "Routed BIO TRAC TIG",
            "RBTIG",
            "base-test://routed-bio-trac-tig",
            tokens,
            weights,
            vm.addr(key),
            type(OpenBSKT).creationCode
        );
        OpenBSKT(payable(basket)).setRouter(ADAPTER, true);
        bytes32 payload = keccak256(
            abi.encode(
                basket,
                block.chainid,
                keccak256("DEPOSIT_ETH"),
                OpenBSKT(payable(basket)).routeNonce(),
                QUOTED_SHARES,
                TOTAL_ETH,
                keccak256(abi.encode(tokens, weights)),
                keccak256(abi.encode(swaps)),
                deadline
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", payload));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        OpenBSKT(payable(basket)).depositETH{value: TOTAL_ETH}(
            QUOTED_SHARES, QUOTED_SHARES, deadline, swaps, abi.encodePacked(r, s, v)
        );
        vm.stopBroadcast();
    }

    function _swap(
        address tokenOut,
        bytes memory venueData,
        uint256 minOut
    ) private pure returns (OpenBSKT.Swap memory swap) {
        swap = OpenBSKT.Swap({
            router: ADAPTER,
            tokenIn: address(0),
            tokenOut: tokenOut,
            amountIn: AMOUNT_PER_ROUTE,
            minOut: minOut,
            value: AMOUNT_PER_ROUTE,
            data: abi.encodeCall(
                OpenBSKTExecutionAdapter.swap, (address(0), tokenOut, AMOUNT_PER_ROUTE, minOut, venueData)
            )
        });
    }
}
