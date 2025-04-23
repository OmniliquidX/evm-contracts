// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./AssetRegistry.sol";
import "./CollateralManager.sol";
import "./Oracle.sol";
import "./RiskManager.sol";

// Forward declaration of Market interface to avoid circular dependency
interface IMarket {
    function getPositionDetails(uint256 positionId) external view returns (
        address trader,
        string memory asset,
        uint128 amount,
        uint128 entryPrice,
        bool isLong,
        bool isOpen
    );
    
    function positionManager() external view returns (address);
    function getTotalPositions() external view returns (uint256);
    
    function openPositionInternal(
        address trader,
        string calldata asset,
        uint128 amount,
        uint128 leverage,
        bool isLong
    ) external returns (uint256);
    
    function increasePositionInternal(
        uint256 positionId,
        uint128 additionalAmount
    ) external;
    
    function decreasePositionInternal(
        uint256 positionId,
        uint128 decreaseAmount,
        address trader
    ) external;
    
    function getLiquidationPrice(uint256 positionId) external view returns (uint128);
}

/// @title Cross-Margin Account Manager for Omniliquid
/// @notice Manages portfolio-level margin across multiple positions
contract CrossMarginAccountManager {
    struct Account {
        bool isInitialized;
        uint256[] positionIds;
        mapping(string => uint256) assetExposure; // Net exposure by asset symbol
        mapping(string => int256) unrealizedPnL;  // Unrealized PnL by asset
        uint256 totalCollateral;
        uint256 totalRequiredMargin;
    }
    
    mapping(address => Account) public accounts;
    address public owner;
    
    CollateralManager public collateralManager;
    IMarket public market;
    Oracle public oracle;
    AssetRegistry public assetRegistry;
    RiskManager public riskManager;
    
    event AccountCreated(address indexed trader);
    event PositionAdded(address indexed trader, uint256 positionId);
    event PositionRemoved(address indexed trader, uint256 positionId);
    event MarginUpdated(address indexed trader, uint256 totalCollateral, uint256 requiredMargin, uint256 marginRatio);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    
    // Errors
    error Unauthorized();
    error AccountNotInitialized();
    error PositionAlreadyExists();
    error PositionNotFound();
    error MarginCallRequired();
    error InsufficientMargin();
    
    modifier onlyOwner() {
        if (msg.sender != owner) revert Unauthorized();
        _;
    }
    
    modifier onlyMarketOrPositionManager() {
        if (msg.sender != address(market) && 
            msg.sender != market.positionManager()) {
            revert Unauthorized();
        }
        _;
    }
    
    constructor(
        address _collateralManager,
        address _assetRegistry,
        address _oracle,
        address _riskManager
    ) {
        require(_collateralManager != address(0), "Invalid collateral manager");
        require(_assetRegistry != address(0), "Invalid asset registry");
        require(_oracle != address(0), "Invalid oracle");
        require(_riskManager != address(0), "Invalid risk manager");
        
        collateralManager = CollateralManager(_collateralManager);
        assetRegistry = AssetRegistry(_assetRegistry);
        oracle = Oracle(_oracle);
        riskManager = RiskManager(_riskManager);
        
        owner = msg.sender;
    }
    
    /// @notice Set market contract
    /// @param _market The market contract address
    function setMarket(address _market) external onlyOwner {
        require(_market != address(0), "Invalid market address");
        market = IMarket(_market);
    }
    
    /// @notice Transfers ownership of the contract to a new account
    /// @param newOwner The address of the new owner
    function transferOwnership(address newOwner) public onlyOwner {
        require(newOwner != address(0), "New owner cannot be zero address");
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }
    
    /// @notice Creates a new cross-margin account for a trader
    /// @param trader The address of the trader
    function createAccount(address trader) external {
        // Can be called by trader, market, or owner
        require(msg.sender == trader || 
                msg.sender == address(market) || 
                msg.sender == owner, 
                "Not authorized");
        
        require(!accounts[trader].isInitialized, "Account already exists");
        
        // Initialize the account
        accounts[trader].isInitialized = true;
        accounts[trader].totalCollateral = 0;
        accounts[trader].totalRequiredMargin = 0;
        
        emit AccountCreated(trader);
    }
    
    /// @notice Checks if a trader has an account
    /// @param trader The trader's address
    /// @return Whether the trader has an account
    function hasAccount(address trader) external view returns (bool) {
        return accounts[trader].isInitialized;
    }
    
    /// @notice Helper function to get position data
    /// @param positionId The position ID
    /// @return trader The trader address
    /// @return asset The asset symbol
    /// @return amount The position amount
    /// @return entryPrice The entry price
    /// @return isLong Whether the position is long
    /// @return isOpen Whether the position is open
    function getPositionData(uint256 positionId) private view returns (
        address trader,
        string memory asset,
        uint128 amount,
        uint128 entryPrice,
        bool isLong,
        bool isOpen
    ) {
        return market.getPositionDetails(positionId);
    }
    
    /// @notice Adds a position to the trader's cross-margin account
    /// @param trader The address of the trader
    /// @param positionId The ID of the position to add
    function addPosition(address trader, uint256 positionId) external onlyMarketOrPositionManager {
        if (!accounts[trader].isInitialized) revert AccountNotInitialized();
        
        // Check if position already exists in the account
        for (uint i = 0; i < accounts[trader].positionIds.length; i++) {
            if (accounts[trader].positionIds[i] == positionId) 
                revert PositionAlreadyExists();
        }
        
        // Get position details
        (
            address posTrader,
            string memory asset,
            uint128 amount,
            uint128 entryPrice,
            bool isLong,
            bool isOpen
        ) = getPositionData(positionId);
        
        // Verify the position belongs to the trader and is open
        require(posTrader == trader, "Position does not belong to trader");
        require(isOpen, "Position is not open");
        
        // Add position to the account
        accounts[trader].positionIds.push(positionId);
        
        // Update asset exposure
        if (isLong) {
            accounts[trader].assetExposure[asset] += uint256(amount);
        } else {
            accounts[trader].assetExposure[asset] -= uint256(amount);
        }
        
        // Update margin requirements
        updateMarginRequirements(trader);
        
        emit PositionAdded(trader, positionId);
    }
    
    /// @notice Removes a position from the trader's cross-margin account
    /// @param trader The address of the trader
    /// @param positionId The ID of the position to remove
    function removePosition(address trader, uint256 positionId) external onlyMarketOrPositionManager {
        if (!accounts[trader].isInitialized) revert AccountNotInitialized();
        
        // Find and remove the position
        bool found = false;
        uint256 posIndex;
        
        for (uint i = 0; i < accounts[trader].positionIds.length; i++) {
            if (accounts[trader].positionIds[i] == positionId) {
                found = true;
                posIndex = i;
                break;
            }
        }
        
        if (!found) revert PositionNotFound();
        
        // Get position details
        (
            address posTrader,
            string memory asset,
            uint128 amount,
            uint128 entryPrice,
            bool isLong,
            bool isOpen
        ) = getPositionData(positionId);
        
        // Update asset exposure
        if (isLong) {
            accounts[trader].assetExposure[asset] -= uint256(amount);
        } else {
            accounts[trader].assetExposure[asset] += uint256(amount);
        }
        
        // Remove position from array (replace with last element and pop)
        accounts[trader].positionIds[posIndex] = accounts[trader].positionIds[
            accounts[trader].positionIds.length - 1
        ];
        accounts[trader].positionIds.pop();
        
        // Update margin requirements
        updateMarginRequirements(trader);
        
        emit PositionRemoved(trader, positionId);
    }
    
    /// @notice Updates margin requirements for a trader's account
    /// @param trader The address of the trader
    function updateMarginRequirements(address trader) public {
        if (!accounts[trader].isInitialized) revert AccountNotInitialized();
        
        // Reset margin amounts
        accounts[trader].totalRequiredMargin = 0;
        
        // Get total collateral from CollateralManager
        accounts[trader].totalCollateral = collateralManager.getTotalCollateral(trader);
        
        // Calculate unrealized P&L for each asset
        string[] memory assets = assetRegistry.getAllAssets();
        for (uint i = 0; i < assets.length; i++) {
            // Skip assets with no exposure
            if (accounts[trader].assetExposure[assets[i]] == 0) {
                accounts[trader].unrealizedPnL[assets[i]] = 0;
                continue;
            }
            
            // Get current price
            AssetRegistry.Asset memory assetInfo = assetRegistry.getAsset(assets[i]);
            (uint128 currentPrice, ) = oracle.getPrice(assetInfo.feedKey);
            
            // Calculate margin requirement for this asset
            uint256 exposure = abs(int256(accounts[trader].assetExposure[assets[i]]));
            uint256 volatilityMultiplier = riskManager.getAssetVolatilityMultiplier(assets[i]);
            
            // Higher volatility assets require more margin
            uint256 assetMarginRequirement = (exposure * volatilityMultiplier) / 10;
            accounts[trader].totalRequiredMargin += assetMarginRequirement;
            
            // Calculate unrealized P&L - simplified, would need per-position calculation
            // for actual implementation
            accounts[trader].unrealizedPnL[assets[i]] = 0; // Placeholder
        }
        
        // Calculate margin ratio
        uint256 marginRatio;
        if (accounts[trader].totalRequiredMargin > 0) {
            marginRatio = (accounts[trader].totalCollateral * 100) / accounts[trader].totalRequiredMargin;
        } else {
            marginRatio = type(uint256).max; // Infinite if no margin required
        }
        
        emit MarginUpdated(
            trader, 
            accounts[trader].totalCollateral, 
            accounts[trader].totalRequiredMargin, 
            marginRatio
        );
    }
    
    /// @notice Checks if an account has sufficient margin
    /// @param trader The address of the trader
    /// @return Whether the account has sufficient margin
    function hasEnoughMargin(address trader) external view returns (bool) {
        if (!accounts[trader].isInitialized) return false;
        
        // If no margin required, always sufficient
        if (accounts[trader].totalRequiredMargin == 0) return true;
        
        // Calculate current margin ratio
        uint256 marginRatio = (accounts[trader].totalCollateral * 100) / accounts[trader].totalRequiredMargin;
        
        // Minimum required margin ratio is 120% (configurable in RiskManager)
        return marginRatio >= 120;
    }
    
    /// @notice Gets all position IDs for a trader
    /// @param trader The address of the trader
    /// @return An array of position IDs
    function getPositionIds(address trader) external view returns (uint256[] memory) {
        if (!accounts[trader].isInitialized) revert AccountNotInitialized();
        return accounts[trader].positionIds;
    }
    
    /// @notice Gets the asset exposure for a trader
    /// @param trader The address of the trader
    /// @param asset The asset symbol
    /// @return The net exposure for the asset
    function getAssetExposure(address trader, string calldata asset) external view returns (int256) {
        if (!accounts[trader].isInitialized) revert AccountNotInitialized();
        return int256(accounts[trader].assetExposure[asset]);
    }
    
    /// @notice Gets the unrealized P&L for a trader's asset
    /// @param trader The address of the trader
    /// @param asset The asset symbol
    /// @return The unrealized P&L for the asset
    function getUnrealizedPnL(address trader, string calldata asset) external view returns (int256) {
        if (!accounts[trader].isInitialized) revert AccountNotInitialized();
        return accounts[trader].unrealizedPnL[asset];
    }
    
    /// @notice Gets the total collateral for a trader
    /// @param trader The address of the trader
    /// @return The total collateral
    function getTotalCollateral(address trader) external view returns (uint256) {
        if (!accounts[trader].isInitialized) revert AccountNotInitialized();
        return accounts[trader].totalCollateral;
    }
    
    /// @notice Gets the total required margin for a trader
    /// @param trader The address of the trader
    /// @return The total required margin
    function getTotalRequiredMargin(address trader) external view returns (uint256) {
        if (!accounts[trader].isInitialized) revert AccountNotInitialized();
        return accounts[trader].totalRequiredMargin;
    }
    
    /// @notice Helper function to get absolute value of an int256
    /// @param x The input value
    /// @return The absolute value
    function abs(int256 x) internal pure returns (uint256) {
        return x >= 0 ? uint256(x) : uint256(-x);
    }
}