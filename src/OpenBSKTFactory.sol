// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "./OpenBSKTManagerNFT.sol";

/// @notice Permissionless factory for generic openBSKT baskets.
contract OpenBSKTFactory {
    address public immutable usdc;
    uint256 public basketCount;
    mapping(uint256 => address) public basketAt;

    error ZeroAddress();
    error EmptyMetadata();
    error EmptyCreationCode();
    error BasketDeploymentFailed();

    event BasketCreated(
        uint256 indexed basketId,
        address indexed basket,
        address indexed manager,
        address routeSigner,
        string name,
        string symbol
    );

    constructor(
        address usdc_
    ) {
        if (usdc_ == address(0)) revert ZeroAddress();
        usdc = usdc_;
    }

    function createBasket(
        string calldata name,
        string calldata symbol,
        string calldata metadataURI,
        address[] calldata tokens,
        uint256[] calldata weights,
        address routeSigner,
        bytes calldata basketCreationCode
    ) external returns (address basket) {
        if (bytes(name).length == 0 || bytes(symbol).length == 0) revert EmptyMetadata();
        if (basketCreationCode.length == 0) revert EmptyCreationCode();
        OpenBSKTManagerNFT managerNFT =
            new OpenBSKTManagerNFT(string.concat(name, " Manager"), string.concat(symbol, "-M"), address(this));
        uint256 managerTokenId = managerNFT.mint(msg.sender);
        bytes memory initCode = abi.encodePacked(
            basketCreationCode,
            abi.encode(
                name, symbol, metadataURI, tokens, weights, address(managerNFT), managerTokenId, routeSigner, usdc
            )
        );
        assembly {
            basket := create(0, add(initCode, 0x20), mload(initCode))
        }
        if (basket == address(0)) revert BasketDeploymentFailed();
        uint256 id = basketCount++;
        basketAt[id] = basket;
        emit BasketCreated(id, basket, msg.sender, routeSigner, name, symbol);
    }
}
