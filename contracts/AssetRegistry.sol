// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
pragma experimental ABIEncoderV2;

/// @title Asset Registry for Omniliquid
/// @notice Manages the registration and details of supported assets.
contract AssetRegistry {
    struct Asset {
        string symbol;
        string feedKey;    // DIA oracle key, e.g., "BTC/USD"
        uint8 decimals;
        bool isRegistered;
    }

    mapping(bytes32 => Asset) private assets;
    bytes32[] private assetList;
    address public owner;

    event AssetRegistered(string symbol, string feedKey, uint8 decimals);
    event AssetUpdated(string symbol, string feedKey, uint8 decimals);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    modifier onlyOwner() {
        require(msg.sender == owner, "Not authorized");
        _;
    }

    constructor() {
        owner = msg.sender;
    }

    /// @notice Transfers ownership of the contract to a new account
    /// @param newOwner The address of the new owner
    function transferOwnership(address newOwner) public onlyOwner {
        require(newOwner != address(0), "New owner cannot be the zero address");
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }

    /// @notice Registers a new asset.
    /// @param symbol The asset symbol.
    /// @param feedKey The corresponding DIA oracle feed key.
    /// @param decimals The asset's decimal precision.
    function registerAsset(
        string calldata symbol,
        string calldata feedKey,
        uint8 decimals
    ) external onlyOwner {
        bytes32 key = keccak256(abi.encodePacked(symbol));
        require(!assets[key].isRegistered, "Asset already registered");
        assets[key] = Asset(symbol, feedKey, decimals, true);
        assetList.push(key);
        emit AssetRegistered(symbol, feedKey, decimals);
    }

    /// @notice Updates an existing asset's details.
    /// @param symbol The asset symbol.
    /// @param feedKey The updated DIA oracle feed key.
    /// @param decimals The updated asset's decimal precision.
    function updateAsset(
        string calldata symbol,
        string calldata feedKey,
        uint8 decimals
    ) external onlyOwner {
        bytes32 key = keccak256(abi.encodePacked(symbol));
        require(assets[key].isRegistered, "Asset not registered");
        assets[key] = Asset(symbol, feedKey, decimals, true);
        emit AssetUpdated(symbol, feedKey, decimals);
    }

    /// @notice Retrieves asset details by symbol.
    /// @param symbol The asset symbol.
    /// @return The asset details.
    function getAsset(string calldata symbol) external view returns (Asset memory) {
        bytes32 key = keccak256(abi.encodePacked(symbol));
        require(assets[key].isRegistered, "Asset not registered");
        return assets[key];
    }

    /// @notice Returns the list of registered asset symbols.
    /// @return An array of asset symbols.
    function getAllAssets() external view returns (string[] memory) {
        string[] memory symbols = new string[](assetList.length);
        for (uint256 i = 0; i < assetList.length; i++) {
            symbols[i] = assets[assetList[i]].symbol;
        }
        return symbols;
    }
}