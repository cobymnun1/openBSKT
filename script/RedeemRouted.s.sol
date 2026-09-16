// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "forge-std/Script.sol";
import "../src/OpenBSKT.sol";
import "../src/OpenBSKTExecutionAdapter.sol";

contract RedeemRouted is Script {
    uint256 private constant SHARES = 1 ether;
    uint256 private constant BIO_AMOUNT = 31740040697704191480;
    uint256 private constant TRAC_AMOUNT = 2612333317471337501;
    uint256 private constant TIG_AMOUNT = 1166534613719636903;
    address private constant ADAPTER = 0xb0cabA8b945B88481B951BD325730da6b872b2F3;
    address private constant BIO = 0x226A2FA2556C48245E57cd1cbA4C6c9e67077DD2;
    address private constant TRAC = 0xA81a52B4dda010896cDd386C7fBdc5CDc835ba23;
    address private constant TIG = 0x0C03Ce270B4826Ec62e7DD007f0B716068639F7B;

    function run() external {
        OpenBSKT basket = OpenBSKT(payable(vm.envAddress("BASKET_ADDRESS")));
        uint256 key = vm.envUint("DEPLOYER_PRIVATE_KEY");
        uint256 deadline = block.timestamp + 1 hours;
        OpenBSKT.Swap[] memory swaps = new OpenBSKT.Swap[](3);
        swaps[0] = _swap(BIO, BIO_AMOUNT, vm.envBytes("BIO_DATA"), vm.envUint("BIO_MIN"));
        swaps[1] = _swap(TRAC, TRAC_AMOUNT, vm.envBytes("TRAC_DATA"), vm.envUint("TRAC_MIN"));
        swaps[2] = _swap(TIG, TIG_AMOUNT, vm.envBytes("TIG_DATA"), vm.envUint("TIG_MIN"));

        (address[] memory tokens, uint256[] memory weights) = basket.getConstituents();
        bytes32 payload = keccak256(
            abi.encode(
                address(basket),
                block.chainid,
                keccak256("REDEEM_ETH"),
                basket.routeNonce(),
                SHARES,
                SHARES,
                keccak256(abi.encode(tokens, weights)),
                keccak256(abi.encode(swaps)),
                deadline
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", payload));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);

        vm.startBroadcast();
        basket.setRouter(ADAPTER, true);
        basket.redeemETH(SHARES, 0, deadline, swaps, abi.encodePacked(r, s, v));
        vm.stopBroadcast();
    }

    function _swap(
        address tokenIn,
        uint256 amountIn,
        bytes memory venueData,
        uint256 minOut
    ) private pure returns (OpenBSKT.Swap memory swap) {
        swap = OpenBSKT.Swap({
            router: ADAPTER,
            tokenIn: tokenIn,
            tokenOut: address(0),
            amountIn: amountIn,
            minOut: minOut,
            value: 0,
            data: abi.encodeCall(
                OpenBSKTExecutionAdapter.swap,
                (tokenIn, address(0), amountIn, minOut, venueData)
            )
        });
    }
}
