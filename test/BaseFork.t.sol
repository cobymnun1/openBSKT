// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "forge-std/Test.sol";
import "../src/OpenBSKT.sol";
import "../src/OpenBSKTManagerNFT.sol";

interface IERC20MetadataFork {
    function decimals() external view returns (uint8);
    function balanceOf(
        address account
    ) external view returns (uint256);
    function approve(
        address spender,
        uint256 amount
    ) external returns (bool);
}

/// @notice Opt-in smoke tests against real Base token contracts.
/// @dev Run with BASE_RPC_URL=<Base RPC> and --match-contract BaseForkTest.
contract BaseForkTest is Test {
    address private constant BASE_USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address private constant BASE_WETH = 0x4200000000000000000000000000000000000006;
    address private user = address(0xBEEF);

    function testForkRealBaseTokensContributeAndWithdraw() public {
        string memory rpc = vm.envOr("BASE_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc);
        assertEq(block.chainid, 8453);
        assertEq(IERC20MetadataFork(BASE_USDC).decimals(), 6);
        assertEq(IERC20MetadataFork(BASE_WETH).decimals(), 18);

        OpenBSKTManagerNFT managerNFT = new OpenBSKTManagerNFT("Fork Manager", "FM", address(this));
        uint256 managerTokenId = managerNFT.mint(address(this));
        address[] memory tokens = new address[](2);
        tokens[0] = BASE_WETH;
        tokens[1] = BASE_USDC;
        uint256[] memory weights = new uint256[](2);
        weights[0] = 5000;
        weights[1] = 5000;
        OpenBSKT basket = new OpenBSKT(
            "Fork Basket",
            "FB",
            "test://base-fork",
            tokens,
            weights,
            address(managerNFT),
            managerTokenId,
            address(this),
            BASE_USDC
        );

        deal(BASE_WETH, user, 1 ether);
        deal(BASE_USDC, user, 1_000_000);
        uint256 wethBefore = IERC20MetadataFork(BASE_WETH).balanceOf(user);
        uint256 usdcBefore = IERC20MetadataFork(BASE_USDC).balanceOf(user);

        vm.startPrank(user);
        IERC20MetadataFork(BASE_WETH).approve(address(basket), type(uint256).max);
        IERC20MetadataFork(BASE_USDC).approve(address(basket), type(uint256).max);
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 1 ether;
        amounts[1] = 1_000_000;
        uint256 shares = basket.contribute(amounts, user, 1);
        basket.withdraw(shares, user, new uint256[](2));
        vm.stopPrank();

        assertEq(IERC20MetadataFork(BASE_WETH).balanceOf(user), wethBefore);
        assertEq(IERC20MetadataFork(BASE_USDC).balanceOf(user), usdcBefore);
        assertEq(basket.totalSupply(), 0);
    }
}
