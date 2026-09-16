// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

interface IERC20 {
    function totalSupply() external view returns (uint256);
    function balanceOf(
        address account
    ) external view returns (uint256);
    function allowance(
        address owner,
        address spender
    ) external view returns (uint256);
    function approve(
        address spender,
        uint256 amount
    ) external returns (bool);
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

interface IManagerNFT {
    function ownerOf(
        uint256 tokenId
    ) external view returns (address);
}

/// @notice Generic ERC-7621-style multi-asset basket with a transferable manager NFT.
/// @dev The core has no basket-specific tokens, weights, metadata, or route keys.
contract OpenBSKT {
    uint256 public constant BPS = 10_000;
    uint256 public constant MANAGER_TOKEN_ID = 0;
    uint256 public constant COMPOSITION_DELAY = 1 days;

    struct Swap {
        address router;
        address tokenIn;
        address tokenOut;
        uint256 amountIn;
        uint256 minOut;
        uint256 value;
        bytes data;
    }

    struct Composition {
        address[] tokens;
        uint256[] weights;
        uint256 executeAfter;
    }

    string public name;
    string public symbol;
    uint8 public constant decimals = 18;
    string public metadataURI;
    address public immutable usdc;
    address public routeSigner;
    address public pendingRouteSigner;
    uint256 public routeNonce;
    bool public paused;
    uint256 public cashEth;
    uint256 public cashUsdc;
    mapping(address => bool) public routers;

    address[] private _tokens;
    mapping(address => uint256) public weight;
    mapping(address => bool) public isConstituent;
    mapping(address => uint256) private _balance;
    uint256 private _totalSupply;
    mapping(address => mapping(address => uint256)) private _allowance;

    address public immutable managerNFT;
    uint256 public immutable managerTokenId;
    Composition public pendingComposition;
    uint256 private _locked = 1;

    error ZeroAddress();
    error ZeroAmount();
    error InvalidComposition();
    error NotManager();
    error NotSigner();
    error NotPendingManager();
    error NotReady();
    error Expired();
    error Paused();
    error Reentrant();
    error LengthMismatch();
    error DuplicateToken();
    error InvalidRoute();
    error Overspend();
    error RouteFailed(uint256 index);
    error Slippage(uint256 index);
    error BadSignature();
    error TransferFailed();
    error ApprovalFailed();
    error InsufficientShares();
    error InvalidReceiver();
    error ReserveLocked();
    error UnequalContribution();

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
    event RouteSignerSet(address indexed signer);
    event PausedSet(bool paused);
    event CompositionProposed(address[] tokens, uint256[] weights, uint256 executeAfter);
    event CompositionChanged(address[] tokens, uint256[] weights);
    event SwapSkipped(uint256 indexed index, address indexed tokenIn, uint256 amountIn);
    event RouterSet(address indexed router, bool allowed);
    event CashReserveChanged(uint256 ethAmount, uint256 usdcAmount);
    event PartialRedeem(address indexed receiver, uint256 requestedShares, uint256 burnedShares);
    event Rebalanced(address indexed tokenIn, address indexed tokenOut, uint256 amountIn, uint256 amountOut);

    modifier nonReentrant() {
        if (_locked != 1) revert Reentrant();
        _locked = 2;
        _;
        _locked = 1;
    }

    modifier onlyManager() {
        if (msg.sender != IManagerNFT(managerNFT).ownerOf(managerTokenId)) revert NotManager();
        _;
    }

    constructor(
        string memory name_,
        string memory symbol_,
        string memory metadataURI_,
        address[] memory tokens_,
        uint256[] memory weights_,
        address managerNFT_,
        uint256 managerTokenId_,
        address routeSigner_,
        address usdc_
    ) {
        if (
            managerNFT_ == address(0) || routeSigner_ == address(0) || usdc_ == address(0)
                || IManagerNFT(managerNFT_).ownerOf(managerTokenId_) == address(0)
        ) revert ZeroAddress();
        name = name_;
        symbol = symbol_;
        metadataURI = metadataURI_;
        usdc = usdc_;
        managerNFT = managerNFT_;
        managerTokenId = managerTokenId_;
        routeSigner = routeSigner_;
        _setComposition(tokens_, weights_);
        emit RouteSignerSet(routeSigner_);
    }

    receive() external payable {}

    function totalSupply() external view returns (uint256) {
        return _totalSupply;
    }

    function balanceOf(
        address account
    ) external view returns (uint256) {
        return _balance[account];
    }

    function allowance(
        address owner,
        address spender
    ) external view returns (uint256) {
        return _allowance[owner][spender];
    }

    function manager() external view returns (address) {
        return IManagerNFT(managerNFT).ownerOf(managerTokenId);
    }

    function ownerOf(
        uint256 tokenId
    ) external view returns (address) {
        if (tokenId != MANAGER_TOKEN_ID) revert InvalidComposition();
        return IManagerNFT(managerNFT).ownerOf(managerTokenId);
    }

    function approve(
        address spender,
        uint256 amount
    ) external returns (bool) {
        _allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(
        address to,
        uint256 amount
    ) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) external returns (bool) {
        uint256 allowed = _allowance[from][msg.sender];
        if (allowed != type(uint256).max) {
            if (allowed < amount) revert InsufficientShares();
            unchecked {
                _allowance[from][msg.sender] = allowed - amount;
            }
        }
        _transfer(from, to, amount);
        return true;
    }

    function getConstituents() external view returns (address[] memory tokens, uint256[] memory weights) {
        tokens = _tokens;
        weights = new uint256[](tokens.length);
        for (uint256 i; i < tokens.length; ++i) {
            weights[i] = weight[tokens[i]];
        }
    }

    function proposeComposition(
        address[] calldata tokens,
        uint256[] calldata weights
    ) external onlyManager {
        _validateComposition(tokens, weights);
        delete pendingComposition.tokens;
        delete pendingComposition.weights;
        pendingComposition.tokens = tokens;
        pendingComposition.weights = weights;
        pendingComposition.executeAfter = block.timestamp + COMPOSITION_DELAY;
        emit CompositionProposed(tokens, weights, pendingComposition.executeAfter);
    }

    function executeComposition() external {
        Composition storage p = pendingComposition;
        if (p.executeAfter == 0 || block.timestamp < p.executeAfter) revert NotReady();
        for (uint256 i; i < _tokens.length; ++i) {
            if (!isConstituentIn(p.tokens, _tokens[i]) && _balanceOfToken(_tokens[i]) != 0) revert ReserveLocked();
        }
        _setComposition(p.tokens, p.weights);
        delete pendingComposition.tokens;
        delete pendingComposition.weights;
        pendingComposition.executeAfter = 0;
        emit CompositionChanged(_tokens, _weights());
    }

    function setRouteSigner(
        address signer
    ) external onlyManager {
        if (signer == address(0)) revert ZeroAddress();
        pendingRouteSigner = signer;
    }

    function acceptRouteSigner() external {
        if (msg.sender != pendingRouteSigner) revert NotSigner();
        routeSigner = msg.sender;
        pendingRouteSigner = address(0);
        unchecked {
            ++routeNonce;
        }
        emit RouteSignerSet(msg.sender);
    }

    function setPaused(
        bool value
    ) external onlyManager {
        paused = value;
        emit PausedSet(value);
    }

    function setRouter(
        address router,
        bool allowed
    ) external onlyManager {
        if (router == address(0)) revert ZeroAddress();
        routers[router] = allowed;
        emit RouterSet(router, allowed);
    }

    /// @notice Executes one manager-approved constituent-to-constituent rebalance.
    /// @dev Composition changes are timelocked separately; this function never mints shares.
    function managerSwap(
        Swap calldata swap
    ) external onlyManager nonReentrant returns (uint256 amountOut) {
        if (paused || !isConstituent[swap.tokenIn] || !isConstituent[swap.tokenOut]) revert InvalidRoute();
        (bool ok, uint256 received) = _trySwap(swap);
        if (!ok || received < swap.minOut) revert RouteFailed(0);
        emit Rebalanced(swap.tokenIn, swap.tokenOut, swap.amountIn, received);
        return received;
    }

    /// @notice Removes only untracked token dust while paused.
    function sweepDust(
        address token,
        address to,
        uint256 amount
    ) external onlyManager {
        if (!paused || to == address(0) || isConstituent[token]) revert ReserveLocked();
        if (token == address(0)) {
            uint256 freeEth = address(this).balance - cashEth;
            if (amount > freeEth) revert ReserveLocked();
            _sendEth(to, amount);
        } else {
            uint256 reserved = token == usdc ? cashUsdc : 0;
            uint256 balance = _balanceOfToken(token);
            if (amount > balance - reserved) revert ReserveLocked();
            _safeTransfer(token, to, amount);
        }
    }

    function depositETH(
        uint256 quotedShares,
        uint256 minShares,
        uint256 deadline,
        Swap[] calldata swaps,
        bytes calldata signature
    ) external payable nonReentrant returns (uint256 shares) {
        if (paused) revert Paused();
        if (msg.value == 0) revert ZeroAmount();
        if (block.timestamp > deadline) revert Expired();
        if (swaps.length != _tokens.length) revert LengthMismatch();
        _verifyQuote(keccak256("DEPOSIT_ETH"), quotedShares, msg.value, swaps, deadline, signature);
        uint256 beforeEth = address(this).balance - msg.value;
        for (uint256 i; i < swaps.length; ++i) {
            if (swaps[i].tokenIn != address(0) || swaps[i].tokenOut != _tokens[i]) revert InvalidRoute();
            (bool ok, uint256 received) = _trySwap(swaps[i]);
            if (!ok || received < swaps[i].minOut) emit SwapSkipped(i, address(0), swaps[i].amountIn);
        }
        cashEth += address(this).balance - beforeEth;
        emit CashReserveChanged(cashEth, cashUsdc);
        if (quotedShares < minShares || quotedShares == 0) revert Slippage(type(uint256).max);
        _mint(msg.sender, quotedShares);
        return quotedShares;
    }

    function depositUSDC(
        uint256 amount,
        uint256 quotedShares,
        uint256 minShares,
        uint256 deadline,
        Swap[] calldata swaps,
        bytes calldata signature
    ) external nonReentrant returns (uint256 shares) {
        if (paused) revert Paused();
        if (amount == 0) revert ZeroAmount();
        if (block.timestamp > deadline) revert Expired();
        if (swaps.length != _tokens.length) revert LengthMismatch();
        _verifyQuote(keccak256("DEPOSIT_USDC"), quotedShares, amount, swaps, deadline, signature);
        uint256 before = _balanceOfToken(usdc);
        _safeTransferFrom(usdc, msg.sender, address(this), amount);
        for (uint256 i; i < swaps.length; ++i) {
            if (swaps[i].tokenIn != usdc || swaps[i].tokenOut != _tokens[i]) revert InvalidRoute();
            (bool ok, uint256 received) = _trySwap(swaps[i]);
            if (!ok || received < swaps[i].minOut) emit SwapSkipped(i, usdc, swaps[i].amountIn);
        }
        uint256 afterBalance = _balanceOfToken(usdc);
        if (!isConstituent[usdc] && afterBalance > before) cashUsdc += afterBalance - before;
        emit CashReserveChanged(cashEth, cashUsdc);
        if (quotedShares < minShares || quotedShares == 0) revert Slippage(type(uint256).max);
        _mint(msg.sender, quotedShares);
        return quotedShares;
    }

    function redeemETH(
        uint256 shares,
        uint256 minEthOut,
        uint256 deadline,
        Swap[] calldata swaps,
        bytes calldata signature
    ) external nonReentrant returns (uint256 paid, uint256 burned) {
        return _redeem(shares, minEthOut, deadline, swaps, signature, true);
    }

    function redeemUSDC(
        uint256 shares,
        uint256 minUsdcOut,
        uint256 deadline,
        Swap[] calldata swaps,
        bytes calldata signature
    ) external nonReentrant returns (uint256 paid, uint256 burned) {
        return _redeem(shares, minUsdcOut, deadline, swaps, signature, false);
    }

    /// @notice Mints shares against constituent amounts already held by the caller.
    /// @dev Generic route wrappers can use this after successful swaps.
    function contribute(
        uint256[] calldata amounts,
        address receiver,
        uint256 minShares
    ) external nonReentrant returns (uint256 shares) {
        if (paused) revert Paused();
        if (receiver == address(0)) revert InvalidReceiver();
        if (amounts.length != _tokens.length) revert LengthMismatch();
        uint256[] memory received = new uint256[](amounts.length);
        uint256[] memory reservesBefore = new uint256[](amounts.length);
        for (uint256 i; i < amounts.length; ++i) {
            if (amounts[i] == 0) continue;
            reservesBefore[i] = _balanceOfToken(_tokens[i]);
            _safeTransferFrom(_tokens[i], msg.sender, address(this), amounts[i]);
            uint256 afterBalance = _balanceOfToken(_tokens[i]);
            if (afterBalance < reservesBefore[i]) revert TransferFailed();
            received[i] = afterBalance - reservesBefore[i];
        }
        shares = _sharesForDeposit(received, reservesBefore);
        if (shares < minShares || shares == 0) revert Slippage(type(uint256).max);
        _mint(receiver, shares);
    }

    /// @notice Burns shares and returns proportional underlying tokens.
    function withdraw(
        uint256 shares,
        address receiver,
        uint256[] calldata minAmounts
    ) external nonReentrant returns (uint256[] memory amounts) {
        if (receiver == address(0)) revert InvalidReceiver();
        if (shares == 0 || _balance[msg.sender] < shares) revert InsufficientShares();
        if (minAmounts.length != _tokens.length) revert LengthMismatch();
        uint256 supply = _totalSupply;
        amounts = new uint256[](_tokens.length);
        _burn(msg.sender, shares);
        for (uint256 i; i < _tokens.length; ++i) {
            amounts[i] = _balanceOfToken(_tokens[i]) * shares / supply;
            if (amounts[i] < minAmounts[i]) revert Slippage(i);
            if (amounts[i] != 0) {
                uint256 before = _balanceOfTokenFor(_tokens[i], receiver);
                _safeTransfer(_tokens[i], receiver, amounts[i]);
                if (_balanceOfTokenFor(_tokens[i], receiver) - before < minAmounts[i]) revert Slippage(i);
            }
        }
        if (cashEth != 0) {
            uint256 ethOut = cashEth * shares / supply;
            cashEth -= ethOut;
            _sendEth(receiver, ethOut);
        }
        if (!isConstituent[usdc] && cashUsdc != 0) {
            uint256 usdcOut = cashUsdc * shares / supply;
            cashUsdc -= usdcOut;
            _safeTransfer(usdc, receiver, usdcOut);
        }
        emit CashReserveChanged(cashEth, cashUsdc);
    }

    function _sharesForDeposit(
        uint256[] memory amounts,
        uint256[] memory reservesBefore
    ) internal view returns (uint256 shares) {
        for (uint256 i; i < amounts.length; ++i) {
            if (amounts[i] == 0) revert ZeroAmount();
        }
        if (_totalSupply == 0) {
            for (uint256 i; i < amounts.length; ++i) {
                shares += _scale18(_tokens[i], amounts[i]);
            }
            return shares;
        }
        shares = type(uint256).max;
        uint256 maximum;
        for (uint256 i; i < amounts.length; ++i) {
            uint256 reserve = reservesBefore[i];
            if (reserve == 0) revert ReserveLocked();
            uint256 candidate = _scale18(_tokens[i], amounts[i]) * _totalSupply / _scale18(_tokens[i], reserve);
            if (candidate < shares) shares = candidate;
            if (candidate > maximum) maximum = candidate;
        }
        if (maximum > shares + 1) revert UnequalContribution();
        if (shares == type(uint256).max) shares = 0;
    }

    function _redeem(
        uint256 shares,
        uint256 minOut,
        uint256 deadline,
        Swap[] calldata swaps,
        bytes calldata signature,
        bool toEth
    ) internal returns (uint256 paid, uint256 burned) {
        if (paused) revert Paused();
        if (shares == 0 || _balance[msg.sender] < shares) revert InsufficientShares();
        if (block.timestamp > deadline) revert Expired();
        if (swaps.length != _tokens.length) revert LengthMismatch();
        _verifyQuote(
            toEth ? keccak256("REDEEM_ETH") : keccak256("REDEEM_USDC"), shares, shares, swaps, deadline, signature
        );

        uint256 supply = _totalSupply;
        uint256[] memory output = new uint256[](swaps.length);
        uint256 failedBps;
        for (uint256 i; i < swaps.length; ++i) {
            if (swaps[i].tokenIn != _tokens[i]) revert InvalidRoute();
            if (swaps[i].tokenOut != (toEth ? address(0) : usdc)) revert InvalidRoute();
            (bool ok, uint256 received) = swaps[i].router == address(0) ? (false, uint256(0)) : _trySwap(swaps[i]);
            if (!ok || received < swaps[i].minOut) {
                failedBps += weight[_tokens[i]];
                if (received != 0) {
                    if (toEth) cashEth += received;
                    else if (!isConstituent[usdc]) cashUsdc += received;
                }
                emit SwapSkipped(i, _tokens[i], swaps[i].amountIn);
            } else {
                output[i] = received;
            }
        }

        burned = shares * (BPS - failedBps) / BPS;
        if (burned == 0) {
            emit PartialRedeem(msg.sender, shares, 0);
            return (0, 0);
        }
        _burn(msg.sender, burned);

        if (toEth) {
            uint256 cash = cashEth * burned / supply;
            cashEth -= cash;
            paid = cash;
        } else if (!isConstituent[usdc]) {
            uint256 cash = cashUsdc * burned / supply;
            cashUsdc -= cash;
            paid = cash;
        }
        for (uint256 i; i < output.length; ++i) {
            uint256 amount = output[i] * burned / shares;
            paid += amount;
            if (toEth) cashEth += output[i] - amount;
            else if (!isConstituent[usdc]) cashUsdc += output[i] - amount;
        }
        if (paid < minOut) revert Slippage(type(uint256).max);
        if (toEth) _sendEth(msg.sender, paid);
        else _safeTransfer(usdc, msg.sender, paid);
        emit CashReserveChanged(cashEth, cashUsdc);
        if (burned != shares) emit PartialRedeem(msg.sender, shares, burned);
    }

    function _verifyQuote(
        bytes32 operation,
        uint256 quotedShares,
        uint256 amount,
        Swap[] calldata swaps,
        uint256 deadline,
        bytes calldata signature
    ) internal {
        bytes32 payload = keccak256(
            abi.encode(
                address(this),
                block.chainid,
                operation,
                routeNonce,
                quotedShares,
                amount,
                keccak256(abi.encode(_tokens, _weights())),
                keccak256(abi.encode(swaps)),
                deadline
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", payload));
        if (_recover(digest, signature) != routeSigner) revert BadSignature();
        unchecked {
            ++routeNonce;
        }
    }

    function _trySwap(
        Swap calldata swap
    ) internal returns (bool, uint256) {
        if (!routers[swap.router] || swap.tokenIn == swap.tokenOut) return (false, 0);
        if (swap.tokenIn == address(0)) {
            if (swap.value != swap.amountIn) return (false, 0);
        } else if (swap.value != 0) {
            return (false, 0);
        }
        uint256 beforeIn = swap.tokenIn == address(0) ? address(this).balance : _balanceOfToken(swap.tokenIn);
        uint256 beforeOut = swap.tokenOut == address(0) ? address(this).balance : _balanceOfToken(swap.tokenOut);
        if (swap.tokenIn != address(0)) _forceApprove(swap.tokenIn, swap.router, swap.amountIn);
        (bool ok,) = swap.router.call{value: swap.value}(swap.data);
        if (swap.tokenIn != address(0)) _forceApprove(swap.tokenIn, swap.router, 0);
        if (!ok) return (false, 0);
        uint256 afterIn = swap.tokenIn == address(0) ? address(this).balance : _balanceOfToken(swap.tokenIn);
        uint256 afterOut = swap.tokenOut == address(0) ? address(this).balance : _balanceOfToken(swap.tokenOut);
        if (beforeIn < afterIn || beforeIn - afterIn > swap.amountIn) revert Overspend();
        if (afterOut < beforeOut) revert Overspend();
        uint256 spent = beforeIn - afterIn;
        uint256 received = afterOut - beforeOut;
        if (spent != 0 && received == 0) revert RouteFailed(0);
        return (true, received);
    }

    function _forceApprove(
        address token,
        address spender,
        uint256 amount
    ) internal {
        (bool ok, bytes memory data) = token.call(abi.encodeWithSelector(IERC20.approve.selector, spender, 0));
        if (!ok || (data.length != 0 && !abi.decode(data, (bool)))) revert ApprovalFailed();
        if (amount == 0) return;
        (ok, data) = token.call(abi.encodeWithSelector(IERC20.approve.selector, spender, amount));
        if (!ok || (data.length != 0 && !abi.decode(data, (bool)))) revert ApprovalFailed();
    }

    function _recover(
        bytes32 digest,
        bytes calldata signature
    ) internal pure returns (address signer) {
        if (signature.length != 65) revert BadSignature();
        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly {
            r := calldataload(signature.offset)
            s := calldataload(add(signature.offset, 32))
            v := byte(0, calldataload(add(signature.offset, 64)))
        }
        if (v < 27) v += 27;
        signer = ecrecover(digest, v, r, s);
    }

    function _setComposition(
        address[] memory tokens,
        uint256[] memory weights
    ) internal {
        _validateComposition(tokens, weights);
        for (uint256 i; i < _tokens.length; ++i) {
            isConstituent[_tokens[i]] = false;
        }
        delete _tokens;
        for (uint256 i; i < tokens.length; ++i) {
            _tokens.push(tokens[i]);
            weight[tokens[i]] = weights[i];
            isConstituent[tokens[i]] = true;
        }
    }

    function _validateComposition(
        address[] memory tokens,
        uint256[] memory weights
    ) internal pure {
        if (tokens.length == 0 || tokens.length != weights.length) revert InvalidComposition();
        uint256 total;
        for (uint256 i; i < tokens.length; ++i) {
            if (tokens[i] == address(0) || weights[i] == 0) revert InvalidComposition();
            total += weights[i];
            for (uint256 j; j < i; ++j) {
                if (tokens[j] == tokens[i]) revert DuplicateToken();
            }
        }
        if (total != BPS) revert InvalidComposition();
    }

    function isConstituentIn(
        address[] storage tokens,
        address token
    ) internal view returns (bool) {
        for (uint256 i; i < tokens.length; ++i) {
            if (tokens[i] == token) return true;
        }
        return false;
    }

    function _weights() internal view returns (uint256[] memory result) {
        result = new uint256[](_tokens.length);
        for (uint256 i; i < _tokens.length; ++i) {
            result[i] = weight[_tokens[i]];
        }
    }

    function _transfer(
        address from,
        address to,
        uint256 amount
    ) internal {
        if (to == address(0) || _balance[from] < amount) revert TransferFailed();
        unchecked {
            _balance[from] -= amount;
            _balance[to] += amount;
        }
        emit Transfer(from, to, amount);
    }

    function _mint(
        address to,
        uint256 amount
    ) internal {
        _totalSupply += amount;
        _balance[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    function _burn(
        address from,
        uint256 amount
    ) internal {
        if (_balance[from] < amount) revert InsufficientShares();
        unchecked {
            _balance[from] -= amount;
            _totalSupply -= amount;
        }
        emit Transfer(from, address(0), amount);
    }

    function _balanceOfToken(
        address token
    ) internal view returns (uint256 value) {
        (bool ok, bytes memory data) =
            token.staticcall(abi.encodeWithSelector(IERC20.balanceOf.selector, address(this)));
        if (!ok || data.length < 32) revert TransferFailed();
        value = abi.decode(data, (uint256));
    }

    function _balanceOfTokenFor(
        address token,
        address account
    ) internal view returns (uint256 value) {
        (bool ok, bytes memory data) = token.staticcall(abi.encodeWithSelector(IERC20.balanceOf.selector, account));
        if (!ok || data.length < 32) revert TransferFailed();
        value = abi.decode(data, (uint256));
    }

    function _scale18(
        address token,
        uint256 amount
    ) internal view returns (uint256) {
        (bool ok, bytes memory data) = token.staticcall(abi.encodeWithSignature("decimals()"));
        if (!ok || data.length < 32) revert TransferFailed();
        uint256 tokenDecimals = abi.decode(data, (uint256));
        if (tokenDecimals > 18) return amount / (10 ** (tokenDecimals - 18));
        return amount * (10 ** (18 - tokenDecimals));
    }

    function _sendEth(
        address to,
        uint256 amount
    ) internal {
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert TransferFailed();
    }

    function _safeTransfer(
        address token,
        address to,
        uint256 amount
    ) internal {
        (bool ok, bytes memory data) = token.call(abi.encodeWithSelector(IERC20.transfer.selector, to, amount));
        if (!ok || (data.length != 0 && !abi.decode(data, (bool)))) revert TransferFailed();
    }

    function _safeTransferFrom(
        address token,
        address from,
        address to,
        uint256 amount
    ) internal {
        (bool ok, bytes memory data) =
            token.call(abi.encodeWithSelector(IERC20.transferFrom.selector, from, to, amount));
        if (!ok || (data.length != 0 && !abi.decode(data, (bool)))) revert TransferFailed();
    }
}
