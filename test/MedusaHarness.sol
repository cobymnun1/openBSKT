// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "../src/OpenBSKT.sol";
import "../src/OpenBSKTManagerNFT.sol";

contract MedusaToken {
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

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

/// @notice Constructor-complete Medusa target with executable properties.
contract MedusaOpenBSKTHarness {
    OpenBSKT public basket;
    OpenBSKTManagerNFT public managerNFT;
    MedusaToken public tokenA;
    MedusaToken public tokenB;
    MedusaToken public usdc;

    constructor() {
        tokenA = new MedusaToken();
        tokenB = new MedusaToken();
        usdc = new MedusaToken();

        managerNFT = new OpenBSKTManagerNFT("Medusa Manager", "MM", address(this));
        uint256 managerTokenId = managerNFT.mint(address(this));

        address[] memory tokens = new address[](2);
        tokens[0] = address(tokenA);
        tokens[1] = address(tokenB);
        uint256[] memory weights = new uint256[](2);
        weights[0] = 6000;
        weights[1] = 4000;

        basket = new OpenBSKT(
            "Medusa Basket",
            "MB",
            "medusa://basket",
            tokens,
            weights,
            address(managerNFT),
            managerTokenId,
            address(this),
            address(usdc)
        );
    }

    function fuzzRoundTrip(
        uint128 seed
    ) external {
        uint256 amount = uint256(seed) % 1 ether + 1;
        uint256 amountA = amount * 6000 / 10_000;
        uint256 amountB = amount - amountA;

        tokenA.mint(address(this), amountA);
        tokenB.mint(address(this), amountB);
        tokenA.approve(address(basket), amountA);
        tokenB.approve(address(basket), amountB);

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = amountA;
        amounts[1] = amountB;
        uint256 shares = basket.contribute(amounts, address(this), 1);

        uint256[] memory minimums = new uint256[](2);
        basket.withdraw(shares, address(this), minimums);
    }

    function property_compositionSumsToBps() public view returns (bool) {
        (, uint256[] memory weights) = basket.getConstituents();
        uint256 sum;
        for (uint256 i; i < weights.length; ++i) {
            sum += weights[i];
        }
        return sum == 10_000;
    }

    function property_managerNFTControlsBasket() public view returns (bool) {
        return basket.manager() == address(this) && managerNFT.ownerOf(0) == address(this);
    }

    function property_cashReserveCannotExceedBalance() public view returns (bool) {
        return basket.cashEth() <= address(basket).balance && basket.cashUsdc() <= usdcBalance();
    }

    function usdcBalance() public view returns (uint256) {
        return usdc.balanceOf(address(basket));
    }
}
