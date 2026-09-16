// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

interface IAdapterERC20 {
    function approve(
        address spender,
        uint256 amount
    ) external returns (bool);
    function balanceOf(
        address account
    ) external view returns (uint256);
    function transfer(
        address to,
        uint256 amount
    ) external returns (bool);
    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) external returns (bool);
}

/// @notice Fixed-target execution adapter for a quote generated off-chain.
/// @dev Deploy one instance per approved venue. It never accepts an arbitrary target.
contract OpenBSKTExecutionAdapter {
    address public immutable venue;
    uint256 private _locked = 1;

    error BadVenue();
    error BadInput();
    error BadOutput();
    error Reentrant();
    error TransferFailed();
    error ApprovalFailed();

    modifier nonReentrant() {
        if (_locked != 1) revert Reentrant();
        _locked = 2;
        _;
        _locked = 1;
    }

    constructor(
        address venue_
    ) {
        if (venue_ == address(0)) revert BadVenue();
        venue = venue_;
    }

    receive() external payable {}

    function swap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minOut,
        bytes calldata venueData
    ) external payable nonReentrant returns (uint256 amountOut) {
        if (amountIn == 0 || minOut == 0 || tokenIn == tokenOut) revert BadInput();
        uint256 beforeOut = tokenOut == address(0)
            ? address(this).balance - msg.value
            : IAdapterERC20(tokenOut).balanceOf(address(this));

        if (tokenIn == address(0)) {
            if (msg.value != amountIn) revert BadInput();
        } else {
            if (msg.value != 0) revert BadInput();
            _safeTransferFrom(tokenIn, msg.sender, address(this), amountIn);
            _approve(tokenIn, venue, amountIn);
        }
        (bool ok,) = venue.call{value: msg.value}(venueData);
        if (tokenIn != address(0)) _approve(tokenIn, venue, 0);
        if (!ok) revert BadOutput();

        uint256 afterOut =
            tokenOut == address(0) ? address(this).balance : IAdapterERC20(tokenOut).balanceOf(address(this));
        if (afterOut < beforeOut || afterOut - beforeOut < minOut) revert BadOutput();
        amountOut = afterOut - beforeOut;
        if (tokenOut == address(0)) _sendEth(msg.sender, amountOut);
        else _safeTransfer(tokenOut, msg.sender, amountOut);
    }

    function _approve(
        address token,
        address spender,
        uint256 amount
    ) internal {
        spender = _approvalSpender();
        (bool ok, bytes memory data) =
            token.call(abi.encodeWithSelector(IAdapterERC20.approve.selector, spender, amount));
        if (!ok || (data.length != 0 && !abi.decode(data, (bool)))) revert ApprovalFailed();
    }

    function _approvalSpender() internal view virtual returns (address) {
        return venue;
    }

    function _safeTransferFrom(
        address token,
        address from,
        address to,
        uint256 amount
    ) internal {
        (bool ok, bytes memory data) =
            token.call(abi.encodeWithSelector(IAdapterERC20.transferFrom.selector, from, to, amount));
        if (!ok || (data.length != 0 && !abi.decode(data, (bool)))) revert TransferFailed();
    }

    function _safeTransfer(
        address token,
        address to,
        uint256 amount
    ) internal {
        (bool ok, bytes memory data) = token.call(abi.encodeWithSelector(IAdapterERC20.transfer.selector, to, amount));
        if (!ok || (data.length != 0 && !abi.decode(data, (bool)))) revert TransferFailed();
    }

    function _sendEth(
        address to,
        uint256 amount
    ) internal {
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert TransferFailed();
    }
}

contract OpenBSKTZeroExAdapter is OpenBSKTExecutionAdapter {
    constructor(
        address zeroExRouter
    ) OpenBSKTExecutionAdapter(zeroExRouter) {}
}

contract OpenBSKTAerodromeAdapter is OpenBSKTExecutionAdapter {
    constructor(
        address aerodromeRouter
    ) OpenBSKTExecutionAdapter(aerodromeRouter) {}
}

contract OpenBSKTZeroExPermit2Adapter is OpenBSKTExecutionAdapter {
    address public immutable allowanceTarget;

    constructor(
        address zeroExRouter,
        address allowanceTarget_
    ) OpenBSKTExecutionAdapter(zeroExRouter) {
        if (allowanceTarget_ == address(0)) revert BadVenue();
        allowanceTarget = allowanceTarget_;
    }

    function _approvalSpender() internal view override returns (address) {
        return allowanceTarget;
    }
}
