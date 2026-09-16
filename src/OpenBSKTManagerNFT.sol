// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

interface IERC721Receiver {
    function onERC721Received(
        address operator,
        address from,
        uint256 tokenId,
        bytes calldata data
    ) external returns (bytes4);
}

/// @notice One transferable ERC-721 manager token per openBSKT basket.
contract OpenBSKTManagerNFT {
    string public name;
    string public symbol;
    address public immutable factory;
    uint256 public totalSupply;
    mapping(uint256 => address) private _owner;
    mapping(address => uint256) private _ownedCount;
    mapping(uint256 => address) public getApproved;
    mapping(address => mapping(address => bool)) public isApprovedForAll;

    error NotFactory();
    error NotOwner();
    error InvalidToken();
    error ZeroAddress();
    error UnsafeRecipient();

    event Transfer(address indexed from, address indexed to, uint256 indexed tokenId);
    event Approval(address indexed owner, address indexed approved, uint256 indexed tokenId);
    event ApprovalForAll(address indexed owner, address indexed operator, bool approved);

    constructor(
        string memory name_,
        string memory symbol_,
        address factory_
    ) {
        if (factory_ == address(0)) revert ZeroAddress();
        name = name_;
        symbol = symbol_;
        factory = factory_;
    }

    function ownerOf(
        uint256 tokenId
    ) public view returns (address owner) {
        owner = _owner[tokenId];
        if (owner == address(0)) revert InvalidToken();
    }

    function balanceOf(
        address owner
    ) external view returns (uint256) {
        if (owner == address(0)) revert ZeroAddress();
        return _ownedCount[owner];
    }

    function supportsInterface(
        bytes4 interfaceId
    ) external pure returns (bool) {
        return interfaceId == 0x01ffc9a7 || interfaceId == 0x80ac58cd;
    }

    function mint(
        address to
    ) external returns (uint256 tokenId) {
        if (msg.sender != factory) revert NotFactory();
        if (to == address(0)) revert ZeroAddress();
        tokenId = totalSupply++;
        _owner[tokenId] = to;
        _ownedCount[to]++;
        emit Transfer(address(0), to, tokenId);
    }

    function approve(
        address to,
        uint256 tokenId
    ) external {
        address owner = ownerOf(tokenId);
        if (msg.sender != owner && !isApprovedForAll[owner][msg.sender]) revert NotOwner();
        getApproved[tokenId] = to;
        emit Approval(owner, to, tokenId);
    }

    function setApprovalForAll(
        address operator,
        bool approved
    ) external {
        isApprovedForAll[msg.sender][operator] = approved;
        emit ApprovalForAll(msg.sender, operator, approved);
    }

    function transferFrom(
        address from,
        address to,
        uint256 tokenId
    ) public {
        address owner = ownerOf(tokenId);
        if (owner != from) revert NotOwner();
        if (to == address(0)) revert ZeroAddress();
        if (msg.sender != owner && msg.sender != getApproved[tokenId] && !isApprovedForAll[owner][msg.sender]) {
            revert NotOwner();
        }
        _owner[tokenId] = to;
        _ownedCount[from]--;
        _ownedCount[to]++;
        delete getApproved[tokenId];
        emit Transfer(from, to, tokenId);
    }

    function safeTransferFrom(
        address from,
        address to,
        uint256 tokenId
    ) external {
        safeTransferFrom(from, to, tokenId, "");
    }

    function safeTransferFrom(
        address from,
        address to,
        uint256 tokenId,
        bytes memory data
    ) public {
        transferFrom(from, to, tokenId);
        if (to.code.length != 0) {
            try IERC721Receiver(to).onERC721Received(msg.sender, from, tokenId, data) returns (bytes4 value) {
                if (value != IERC721Receiver.onERC721Received.selector) revert UnsafeRecipient();
            } catch {
                revert UnsafeRecipient();
            }
        }
    }
}
