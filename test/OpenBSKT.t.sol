// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "forge-std/Test.sol";
import "../src/OpenBSKT.sol";
import "../src/OpenBSKTFactory.sol";

contract MockToken {
    string public name;
    string public symbol;
    uint8 public decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(
        string memory name_,
        string memory symbol_
    ) {
        name = name_;
        symbol = symbol_;
    }

    function totalSupply() external pure returns (uint256) {
        return type(uint256).max;
    }

    function mint(
        address to,
        uint256 amount
    ) external {
        balanceOf[to] += amount;
    }

    function approve(
        address spender,
        uint256 amount
    ) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(
        address to,
        uint256 amount
    ) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract OpenBSKTTest is Test {
    MockToken a = new MockToken("A", "A");
    MockToken b = new MockToken("B", "B");
    MockToken usdc = new MockToken("USD Coin", "USDC");
    address manager = address(0x11);
    address signer = address(0x22);
    address user = address(0x33);
    OpenBSKT basket;
    OpenBSKTManagerNFT managerNFT;

    function setUp() public {
        address[] memory tokens = new address[](2);
        tokens[0] = address(a);
        tokens[1] = address(b);
        uint256[] memory weights = new uint256[](2);
        weights[0] = 6000;
        weights[1] = 4000;
        managerNFT = new OpenBSKTManagerNFT("Open Basket Manager", "OBSKT-M", address(this));
        uint256 managerTokenId = managerNFT.mint(manager);
        basket = new OpenBSKT(
            "Open Basket",
            "OBSKT",
            "ipfs://metadata",
            tokens,
            weights,
            address(managerNFT),
            managerTokenId,
            signer,
            address(usdc)
        );
        a.mint(user, 600 ether);
        b.mint(user, 400 ether);
    }

    function testContributeAndWithdraw() public {
        vm.startPrank(user);
        a.approve(address(basket), type(uint256).max);
        b.approve(address(basket), type(uint256).max);
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 600 ether;
        amounts[1] = 400 ether;
        uint256 shares = basket.contribute(amounts, user, 1000 ether);
        assertEq(shares, 1000 ether);
        assertEq(basket.balanceOf(user), 1000 ether);

        uint256[] memory mins = new uint256[](2);
        mins[0] = 599 ether;
        mins[1] = 399 ether;
        basket.withdraw(1000 ether, user, mins);
        assertEq(basket.balanceOf(user), 0);
        vm.stopPrank();
    }

    function testManagerNftTransferControlsComposition() public {
        assertEq(managerNFT.balanceOf(manager), 1);
        assertEq(managerNFT.balanceOf(user), 0);
        vm.prank(manager);
        managerNFT.transferFrom(manager, user, 0);
        assertEq(managerNFT.balanceOf(manager), 0);
        assertEq(managerNFT.balanceOf(user), 1);
        address[] memory tokens = new address[](2);
        tokens[0] = address(a);
        tokens[1] = address(b);
        uint256[] memory weights = new uint256[](2);
        weights[0] = 5000;
        weights[1] = 5000;
        vm.prank(user);
        basket.proposeComposition(tokens, weights);
        vm.warp(block.timestamp + 1 days);
        basket.executeComposition();
        (, uint256[] memory liveWeights) = basket.getConstituents();
        assertEq(liveWeights[0], 5000);
        assertEq(basket.manager(), user);
    }

    function testFactoryCreatesCallerOwnedBasket() public {
        OpenBSKTFactory factory = new OpenBSKTFactory(address(usdc));
        address[] memory tokens = new address[](2);
        tokens[0] = address(a);
        tokens[1] = address(b);
        uint256[] memory weights = new uint256[](2);
        weights[0] = 5000;
        weights[1] = 5000;
        vm.prank(user);
        address created = factory.createBasket(
            "User Basket", "USER", "ipfs://user", tokens, weights, signer, type(OpenBSKT).creationCode
        );
        assertEq(OpenBSKT(payable(created)).manager(), user);
        assertEq(factory.basketAt(0), created);
    }

    function testFundedTokenCannotBeRemovedByCompositionUpdate() public {
        vm.startPrank(user);
        a.approve(address(basket), type(uint256).max);
        b.approve(address(basket), type(uint256).max);
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 600 ether;
        amounts[1] = 400 ether;
        basket.contribute(amounts, user, 1);
        vm.stopPrank();

        address[] memory tokens = new address[](1);
        tokens[0] = address(a);
        uint256[] memory weights = new uint256[](1);
        weights[0] = 10_000;
        vm.prank(manager);
        basket.proposeComposition(tokens, weights);
        vm.warp(block.timestamp + 1 days);
        vm.expectRevert(OpenBSKT.ReserveLocked.selector);
        basket.executeComposition();
    }

    function testFuzzInitialDepositRoundTrip(
        uint128 amountA,
        uint128 amountB
    ) public {
        amountA = uint128(bound(amountA, 1, 1_000_000 ether));
        amountB = uint128(bound(amountB, 1, 1_000_000 ether));
        a.mint(user, amountA);
        b.mint(user, amountB);
        uint256 beforeA = a.balanceOf(user);
        uint256 beforeB = b.balanceOf(user);
        vm.startPrank(user);
        a.approve(address(basket), type(uint256).max);
        b.approve(address(basket), type(uint256).max);
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = amountA;
        amounts[1] = amountB;
        uint256 shares = basket.contribute(amounts, user, 1);
        uint256[] memory mins = new uint256[](2);
        basket.withdraw(shares, user, mins);
        assertEq(a.balanceOf(user), beforeA);
        assertEq(b.balanceOf(user), beforeB);
        vm.stopPrank();
    }
}
