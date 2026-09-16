// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "forge-std/Test.sol";
import "../src/OpenBSKTExecutionAdapter.sol";

contract AdapterToken {
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
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract MockVenue {
    function swap(
        address tokenOut,
        address recipient,
        uint256 amountOut
    ) external payable {
        if (tokenOut == address(0)) {
            (bool ok,) = recipient.call{value: amountOut}("");
            require(ok);
        } else {
            require(AdapterToken(tokenOut).transfer(recipient, amountOut));
        }
    }

    receive() external payable {}
}

contract ReentrantVenue {
    OpenBSKTExecutionAdapter public adapter;
    bool public reentryBlocked;

    function setAdapter(
        OpenBSKTExecutionAdapter adapter_
    ) external {
        adapter = adapter_;
    }

    function reenterAndPay(
        bytes calldata innerCall,
        address output,
        uint256 amountOut
    ) external {
        (bool ok,) = address(adapter).call(innerCall);
        reentryBlocked = !ok;
        AdapterToken(output).transfer(address(adapter), amountOut);
    }
}

contract AdapterTest is Test {
    AdapterToken input = new AdapterToken();
    AdapterToken output = new AdapterToken();
    MockVenue venue = new MockVenue();
    OpenBSKTExecutionAdapter adapter;
    address user = address(0x123);

    function setUp() public {
        adapter = new OpenBSKTExecutionAdapter(address(venue));
        input.mint(user, 100 ether);
        output.mint(address(venue), 95 ether);
        vm.deal(address(venue), 100 ether);
    }

    function testFixedVenueAndBalanceDelta() public {
        vm.startPrank(user);
        input.approve(address(adapter), 100 ether);
        bytes memory data = abi.encodeCall(MockVenue.swap, (address(output), address(adapter), 95 ether));
        uint256 received = adapter.swap(address(input), address(output), 100 ether, 95 ether, data);
        assertEq(received, 95 ether);
        assertEq(output.balanceOf(user), 95 ether);
        assertEq(output.balanceOf(address(adapter)), 0);
        vm.stopPrank();
    }

    function testAdapterBlocksVenueReentry() public {
        ReentrantVenue reentrantVenue = new ReentrantVenue();
        OpenBSKTExecutionAdapter guardedAdapter = new OpenBSKTExecutionAdapter(address(reentrantVenue));
        reentrantVenue.setAdapter(guardedAdapter);
        input.mint(user, 1 ether);
        output.mint(address(reentrantVenue), 1 ether);

        bytes memory innerCall =
            abi.encodeCall(OpenBSKTExecutionAdapter.swap, (address(input), address(output), 1, 1, bytes("")));
        bytes memory outerData = abi.encodeCall(ReentrantVenue.reenterAndPay, (innerCall, address(output), 1));

        vm.startPrank(user);
        input.approve(address(guardedAdapter), 1 ether);
        uint256 received = guardedAdapter.swap(address(input), address(output), 1 ether, 1, outerData);
        assertEq(received, 1);
        assertTrue(reentrantVenue.reentryBlocked());
        assertEq(output.balanceOf(user), 1);
        vm.stopPrank();
    }
}
