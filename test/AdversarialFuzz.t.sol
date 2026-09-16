// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "forge-std/Test.sol";
import "../src/OpenBSKT.sol";
import "../src/OpenBSKTManagerNFT.sol";

contract AdversarialToken {
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

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

contract AdversarialRouter {
    bool public fail;
    bool public reentryBlocked;

    function setFail(
        bool value
    ) external {
        fail = value;
    }

    function invoke(
        address target,
        bytes calldata callData
    ) external {
        (bool ok, bytes memory result) = target.call(callData);
        if (!ok) {
            assembly {
                revert(add(result, 32), mload(result))
            }
        }
    }

    function swapTokenForEth(
        address tokenIn,
        uint256 amountIn,
        uint256 amountOut,
        address recipient
    ) external {
        if (fail) revert("ROUTE_FAILED");
        AdversarialToken(tokenIn).transferFrom(msg.sender, address(this), amountIn);
        (bool ok,) = recipient.call{value: amountOut}("");
        require(ok);
    }

    function attemptReentry(
        address basket,
        bytes calldata innerCall
    ) internal {
        (bool ok,) = basket.call(innerCall);
        reentryBlocked = !ok;
    }

    function attemptReentryAndPay(
        address basket,
        bytes calldata innerCall,
        address tokenOut,
        uint256 amountOut
    ) external {
        attemptReentry(basket, innerCall);
        AdversarialToken(tokenOut).transfer(basket, amountOut);
    }

    receive() external payable {}
}

contract AdversarialFuzzTest is Test {
    uint256 private constant SIGNER_KEY = 0xA11CE;
    AdversarialToken private tokenA;
    AdversarialToken private tokenB;
    AdversarialToken private usdc;
    OpenBSKT private basket;
    OpenBSKTManagerNFT private managerNFT;
    AdversarialRouter private router;
    address private user = address(0xBEEF);
    address private signer;

    function setUp() public {
        signer = vm.addr(SIGNER_KEY);
        tokenA = new AdversarialToken();
        tokenB = new AdversarialToken();
        usdc = new AdversarialToken();
        router = new AdversarialRouter();

        managerNFT = new OpenBSKTManagerNFT("Manager", "MGR", address(this));
        uint256 managerTokenId = managerNFT.mint(address(this));
        address[] memory tokens = new address[](2);
        tokens[0] = address(tokenA);
        tokens[1] = address(tokenB);
        uint256[] memory weights = new uint256[](2);
        weights[0] = 6000;
        weights[1] = 4000;
        basket = new OpenBSKT(
            "Adversarial Basket",
            "ABSKT",
            "test://basket",
            tokens,
            weights,
            address(managerNFT),
            managerTokenId,
            signer,
            address(usdc)
        );
    }

    function testFuzzPartialRedeemKeepsFailedWeight(
        uint128 quotedOutput
    ) public {
        uint256 output = bound(quotedOutput, 1, 1000 ether);
        _seedBasket();
        router = new AdversarialRouter();
        basket.setRouter(address(router), true);
        vm.deal(address(router), output);

        OpenBSKT.Swap[] memory swaps = new OpenBSKT.Swap[](2);
        swaps[0] = OpenBSKT.Swap({
            router: address(router),
            tokenIn: address(tokenA),
            tokenOut: address(0),
            amountIn: 600 ether,
            minOut: 1,
            value: 0,
            data: abi.encodeCall(
                AdversarialRouter.swapTokenForEth, (address(tokenA), 600 ether, output, address(basket))
            )
        });
        swaps[1] = OpenBSKT.Swap({
            router: address(0),
            tokenIn: address(tokenB),
            tokenOut: address(0),
            amountIn: 400 ether,
            minOut: 1,
            value: 0,
            data: ""
        });

        uint256 shares = basket.balanceOf(user);
        bytes memory signature = _signQuote(keccak256("REDEEM_ETH"), shares, shares, swaps, block.timestamp + 1 days);
        vm.prank(user);
        (uint256 paid, uint256 burned) = basket.redeemETH(shares, 0, block.timestamp + 1 days, swaps, signature);

        assertEq(burned, 600 ether);
        assertEq(paid, output * 6000 / 10_000);
        assertEq(basket.balanceOf(user), 400 ether);
        assertEq(tokenB.balanceOf(address(basket)), 400 ether);
        assertEq(tokenA.balanceOf(address(basket)), 0);
    }

    function testFuzzFailedRouteDoesNotChangeReserves(
        uint128 amount
    ) public {
        uint256 input = bound(amount, 1, 1000 ether);
        _seedBasket();
        basket.setRouter(address(router), true);
        router.setFail(true);

        OpenBSKT.Swap memory swap = OpenBSKT.Swap({
            router: address(router),
            tokenIn: address(tokenA),
            tokenOut: address(tokenB),
            amountIn: input,
            minOut: 1,
            value: 0,
            data: abi.encodeCall(AdversarialRouter.swapTokenForEth, (address(tokenA), input, 1, address(basket)))
        });
        vm.expectRevert(abi.encodeWithSelector(OpenBSKT.RouteFailed.selector, 0));
        basket.managerSwap(swap);
        assertEq(tokenA.balanceOf(address(basket)), 600 ether);
        assertEq(tokenB.balanceOf(address(basket)), 400 ether);
    }

    function testUnapprovedRouterAndSameTokenAreRejected() public {
        OpenBSKT.Swap memory swap = OpenBSKT.Swap({
            router: address(router),
            tokenIn: address(tokenA),
            tokenOut: address(tokenB),
            amountIn: 1,
            minOut: 1,
            value: 0,
            data: ""
        });
        vm.expectRevert(abi.encodeWithSelector(OpenBSKT.RouteFailed.selector, 0));
        basket.managerSwap(swap);

        basket.setRouter(address(router), true);
        swap.tokenOut = address(tokenA);
        vm.expectRevert(abi.encodeWithSelector(OpenBSKT.RouteFailed.selector, 0));
        basket.managerSwap(swap);
    }

    function testReentrantRouterCannotReenterManagerSwap() public {
        _seedBasket();
        basket.setRouter(address(router), true);
        managerNFT.transferFrom(address(this), address(router), 0);
        tokenB.mint(address(router), 1);
        OpenBSKT.Swap memory inner = OpenBSKT.Swap({
            router: address(0),
            tokenIn: address(tokenA),
            tokenOut: address(tokenB),
            amountIn: 0,
            minOut: 0,
            value: 0,
            data: ""
        });
        bytes memory innerCall = abi.encodeCall(OpenBSKT.managerSwap, (inner));
        OpenBSKT.Swap memory outer = OpenBSKT.Swap({
            router: address(router),
            tokenIn: address(tokenA),
            tokenOut: address(tokenB),
            amountIn: 1,
            minOut: 1,
            value: 0,
            data: abi.encodeCall(
                AdversarialRouter.attemptReentryAndPay, (address(basket), innerCall, address(tokenB), 1)
            )
        });

        router.invoke(address(basket), abi.encodeCall(OpenBSKT.managerSwap, (outer)));
        assertTrue(router.reentryBlocked());
    }

    function _seedBasket() private {
        tokenA.mint(user, 600 ether);
        tokenB.mint(user, 400 ether);
        vm.startPrank(user);
        tokenA.approve(address(basket), type(uint256).max);
        tokenB.approve(address(basket), type(uint256).max);
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 600 ether;
        amounts[1] = 400 ether;
        basket.contribute(amounts, user, 1);
        vm.stopPrank();
    }

    function _signQuote(
        bytes32 operation,
        uint256 quotedShares,
        uint256 amount,
        OpenBSKT.Swap[] memory swaps,
        uint256 deadline
    ) private returns (bytes memory) {
        (address[] memory tokens, uint256[] memory weights) = basket.getConstituents();
        bytes32 payload = keccak256(
            abi.encode(
                address(basket),
                block.chainid,
                operation,
                basket.routeNonce(),
                quotedShares,
                amount,
                keccak256(abi.encode(tokens, weights)),
                keccak256(abi.encode(swaps)),
                deadline
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", payload));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER_KEY, digest);
        return abi.encodePacked(r, s, v);
    }
}
