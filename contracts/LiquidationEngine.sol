// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
pragma experimental ABIEncoderV2;

import "./Market.sol";
import "./CollateralManager.sol";
import "./AssetRegistry.sol";
import "./Oracle.sol";
import "./SecurityModule.sol";

interface InsuranceFund {
    function addFundsFromLiquidation() external payable;
}

/// @title Liquidation Engine for Omniliquid
/// @notice Manages position liquidations with partial liquidation support
contract LiquidationEngine {
    // Core dependencies
    Market public market;
    CollateralManager public collateralManager;
    AssetRegistry public assetRegistry;
    Oracle public oracle;
    SecurityModule public securityModule;
    address payable public insuranceFund;
    address public owner;
    
    // Liquidation thresholds
    uint256 public liquidationThreshold = 80; // 80% (of initial margin)
    uint256 public partialLiquidationThreshold = 90; // 90% (of initial margin)
    uint256 public partialLiquidationPercent = 50;  // Liquidate 50% of position
    
    // Liquidation fees
    uint256 public liquidationPenalty = 5;    // 5% penalty to liquidated positions
    uint256 public liquidatorReward = 3;      // 3% reward to liquidators
    
    // Liquidation gas compensation 
    uint256 public gasCompensation = 0.01 ether; // Compensation for liquidator's gas costs
    
    // Liquidation cooldown to prevent flash liquidations
    mapping(uint256 => uint256) public liquidationCooldown; // positionId => timestamp
    uint256 public cooldownPeriod = 10 minutes;
    
    // Whitelist of liquidators for private liquidations
    bool public useWhitelistedLiquidators;
    mapping(address => bool) public whitelistedLiquidators;
    
    // Events
    event PositionLiquidated(
        uint256 indexed positionId, 
        address indexed trader, 
        address indexed liquidator, 
        uint128 positionSize, 
        uint128 liquidationPrice,
        bool isPartial,
        uint256 penalty
    );
    event ThresholdUpdated(string thresholdType, uint256 newThreshold);
    event PartialLiquidationUpdated(uint256 newThreshold, uint256 newPercent);
    event PenaltyUpdated(uint256 newPenalty);
    event RewardUpdated(uint256 newReward);
    event GasCompensationUpdated(uint256 newCompensation);
    event CooldownPeriodUpdated(uint256 newPeriod);
    event WhitelistedLiquidatorAdded(address indexed liquidator);
    event WhitelistedLiquidatorRemoved(address indexed liquidator);
    event WhitelistModeUpdated(bool useWhitelist);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    
    // Errors
    error Unauthorized();
    error PositionCannotBeLiquidated();
    error CooldownActive();
    error NotWhitelistedLiquidator();
    error InvalidParameter();
    error TransferFailed();

    // Modifiers
    modifier onlyOwner() {
        if (msg.sender != owner) revert Unauthorized();
        _;
    }
    
    modifier whenNotPaused() {
        require(!securityModule.paused(), "System is paused");
        _;
    }
    
    modifier onlyLiquidator() {
        if (useWhitelistedLiquidators && !whitelistedLiquidators[msg.sender] &&
            !securityModule.liquidators(msg.sender) && msg.sender != owner) {
            revert NotWhitelistedLiquidator();
        }
        _;
    }

    constructor(
        address _market,
        address _collateralManager,
        address _assetRegistry,
        address _oracle,
        address _securityModule,
        address payable _insuranceFund
    ) {
        require(_market != address(0), "Invalid market address");
        require(_collateralManager != address(0), "Invalid collateral manager address");
        require(_assetRegistry != address(0), "Invalid asset registry address");
        require(_oracle != address(0), "Invalid oracle address");
        require(_securityModule != address(0), "Invalid security module address");
        require(_insuranceFund != address(0), "Invalid insurance fund address");
        
        market = Market(_market);
        collateralManager = CollateralManager(_collateralManager);
        assetRegistry = AssetRegistry(_assetRegistry);
        oracle = Oracle(_oracle);
        securityModule = SecurityModule(_securityModule);
        insuranceFund = _insuranceFund;
        owner = msg.sender;
    }
    
    /// @notice Transfers ownership of the contract to a new account
    /// @param newOwner The address of the new owner
    function transferOwnership(address newOwner) public onlyOwner {
        if (newOwner == address(0)) revert InvalidParameter();
        
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }

    /// @notice Updates the liquidation threshold
    /// @param newThreshold The new liquidation threshold (in percentage)
    function setLiquidationThreshold(uint256 newThreshold) external onlyOwner {
        if (newThreshold == 0 || newThreshold >= 100) revert InvalidParameter();
        if (newThreshold >= partialLiquidationThreshold) revert InvalidParameter();
        
        liquidationThreshold = newThreshold;
        emit ThresholdUpdated("liquidation", newThreshold);
    }
    
    /// @notice Updates the partial liquidation threshold and percentage
    /// @param newThreshold The new partial liquidation threshold (in percentage)
    /// @param newPercent The new partial liquidation percentage
    function setPartialLiquidation(uint256 newThreshold, uint256 newPercent) external onlyOwner {
        if (newThreshold <= liquidationThreshold || newThreshold >= 100) revert InvalidParameter();
        if (newPercent == 0 || newPercent >= 100) revert InvalidParameter();
        
        partialLiquidationThreshold = newThreshold;
        partialLiquidationPercent = newPercent;
        
        emit PartialLiquidationUpdated(newThreshold, newPercent);
    }
    
    /// @notice Updates the liquidation penalty
    /// @param newPenalty The new liquidation penalty (in percentage)
    function setLiquidationPenalty(uint256 newPenalty) external onlyOwner {
        if (newPenalty >= 20) revert InvalidParameter(); // Max 20%
        
        liquidationPenalty = newPenalty;
        emit PenaltyUpdated(newPenalty);
    }
    
    /// @notice Updates the liquidator reward
    /// @param newReward The new liquidator reward (in percentage)
    function setLiquidatorReward(uint256 newReward) external onlyOwner {
        if (newReward >= liquidationPenalty) revert InvalidParameter();
        
        liquidatorReward = newReward;
        emit RewardUpdated(newReward);
    }
    
    /// @notice Updates the gas compensation amount
    /// @param newCompensation The new gas compensation amount
    function setGasCompensation(uint256 newCompensation) external onlyOwner {
        gasCompensation = newCompensation;
        emit GasCompensationUpdated(newCompensation);
    }
    
    /// @notice Updates the cooldown period
    /// @param newPeriod The new cooldown period
    function setCooldownPeriod(uint256 newPeriod) external onlyOwner {
        cooldownPeriod = newPeriod;
        emit CooldownPeriodUpdated(newPeriod);
    }
    
    /// @notice Adds a whitelisted liquidator
    /// @param liquidator The liquidator address to add
    function addWhitelistedLiquidator(address liquidator) external onlyOwner {
        if (liquidator == address(0)) revert InvalidParameter();
        
        whitelistedLiquidators[liquidator] = true;
        emit WhitelistedLiquidatorAdded(liquidator);
    }
    
    /// @notice Removes a whitelisted liquidator
    /// @param liquidator The liquidator address to remove
    function removeWhitelistedLiquidator(address liquidator) external onlyOwner {
        whitelistedLiquidators[liquidator] = false;
        emit WhitelistedLiquidatorRemoved(liquidator);
    }
    
    /// @notice Toggles the whitelist mode
    /// @param useWhitelist Whether to use whitelisted liquidators only
    function setUseWhitelistedLiquidators(bool useWhitelist) external onlyOwner {
        useWhitelistedLiquidators = useWhitelist;
        emit WhitelistModeUpdated(useWhitelist);
    }

    /// @notice Checks if a position can be liquidated
    /// @param positionId The ID of the position to check
    /// @return shouldLiquidate True if the position can be liquidated
    /// @return isPartialLiq True if the position should be partially liquidated
    /// @return currentPrice Current price of the asset
    function canLiquidate(uint256 positionId) public view returns (
        bool shouldLiquidate,
        bool isPartialLiq,
        uint128 currentPrice
    ) {
        // Get position data from Market contract
        (
            address trader,
            string memory asset,
            uint128 amount,
            uint128 entryPrice,
            bool isLong,
            bool isOpen
        ) = getPositionData(positionId);
        
        // Position must be open to be liquidated
        if (!isOpen) {
            return (false, false, 0);
        }
        
        // Check cooldown period
        if (block.timestamp < liquidationCooldown[positionId] + cooldownPeriod) {
            return (false, false, 0);
        }
        
        // Get current price from oracle
        AssetRegistry.Asset memory assetDetails = assetRegistry.getAsset(asset);
        (currentPrice, ) = oracle.getPrice(assetDetails.feedKey);
        
        // Calculate current margin percentage
        uint256 currentMargin = calculateCurrentMargin(positionId);
        uint256 initialMargin = uint256(amount);
        uint256 marginPercentage = currentMargin * 100 / initialMargin;
        
        // Determine if liquidation is needed and what type
        if (marginPercentage < liquidationThreshold) {
            return (true, false, currentPrice); // Full liquidation
        } else if (marginPercentage < partialLiquidationThreshold) {
            return (true, true, currentPrice); // Partial liquidation
        }
        
        return (false, false, currentPrice); // No liquidation needed
    }

    /// @notice Helper to get position data
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
    (trader, asset, amount, entryPrice, isLong, isOpen) = market.getPositionDetails(positionId);
}
    /// @notice Liquidates a position that is below the required margin
    /// @param positionId The ID of the position to liquidate
    function liquidatePosition(uint256 positionId) external whenNotPaused onlyLiquidator {
        (bool shouldLiquidate, bool isPartial, uint128 price) = canLiquidate(positionId);
        if (!shouldLiquidate) revert PositionCannotBeLiquidated();
        
        // Get position details
        (
            address trader,
            string memory asset,
            uint128 amount,
            uint128 entryPrice,
            bool isLong,
            bool isOpen
        ) = getPositionData(positionId);
        
        // Set cooldown timestamp to prevent flash liquidations
        liquidationCooldown[positionId] = block.timestamp;
        
        if (isPartial) {
            // Partial liquidation
            uint128 liquidationAmount = uint128(uint256(amount) * partialLiquidationPercent / 100);
            
            // Call partial liquidation on market
            market.decreasePositionInternal(positionId, liquidationAmount, trader);
            
            // Calculate and distribute liquidation penalty and reward
            uint256 penaltyAmount = uint256(liquidationAmount) * liquidationPenalty / 100;
            uint256 rewardAmount = uint256(liquidationAmount) * liquidatorReward / 100;
            
            // Transfer reward to liquidator
            collateralManager.rewardLiquidator(msg.sender, rewardAmount);
            
            // Add gas compensation
            collateralManager.rewardLiquidator(msg.sender, gasCompensation);
            
            // The remaining penalty goes to the insurance fund
            uint256 insuranceAmount = penaltyAmount - rewardAmount;
            InsuranceFund(insuranceFund).addFundsFromLiquidation{value: insuranceAmount}();
            
            emit PositionLiquidated(
                positionId,
                trader,
                msg.sender,
                liquidationAmount,
                price,
                true,
                penaltyAmount
            );
        } else {
            // Full liquidation
            market.forceLiquidate(positionId, msg.sender);
            
            // Calculate and distribute liquidation penalty and reward
            uint256 penaltyAmount = uint256(amount) * liquidationPenalty / 100;
            uint256 rewardAmount = uint256(amount) * liquidatorReward / 100;
            
            // Transfer reward to liquidator
            collateralManager.rewardLiquidator(msg.sender, rewardAmount);
            
            // Add gas compensation
            collateralManager.rewardLiquidator(msg.sender, gasCompensation);
            
            // The remaining penalty goes to the insurance fund
            uint256 insuranceAmount = penaltyAmount - rewardAmount;
            InsuranceFund(insuranceFund).addFundsFromLiquidation{value: insuranceAmount}();
            
            emit PositionLiquidated(
                positionId,
                trader,
                msg.sender,
                amount,
                price,
                false,
                penaltyAmount
            );
        }
    }
    
    /// @notice Calculates the current margin for a position
    /// @param positionId The ID of the position
    /// @return The current margin
    function calculateCurrentMargin(uint256 positionId) public view returns (uint256) {
        // Get position details
        (
            address trader,
            string memory asset,
            uint128 amount,
            uint128 entryPrice,
            bool isLong,
            bool isOpen
        ) = getPositionData(positionId);
        
        if (!isOpen) return 0;
        
        // Get current price
        AssetRegistry.Asset memory assetDetails = assetRegistry.getAsset(asset);
        (uint128 currentPrice, ) = oracle.getPrice(assetDetails.feedKey);
        
        // Calculate PnL
        int256 pnl;
        
        if (isLong) {
            // Long position: profit if price up, loss if price down
            if (currentPrice > entryPrice) {
                pnl = int256(uint256(amount) * uint256(currentPrice - entryPrice) / uint256(entryPrice));
            } else {
                pnl = -int256(uint256(amount) * uint256(entryPrice - currentPrice) / uint256(entryPrice));
            }
        } else {
            // Short position: profit if price down, loss if price up
            if (currentPrice < entryPrice) {
                pnl = int256(uint256(amount) * uint256(entryPrice - currentPrice) / uint256(entryPrice));
            } else {
                pnl = -int256(uint256(amount) * uint256(currentPrice - entryPrice) / uint256(entryPrice));
            }
        }
        
        // Calculate current margin (initial margin + PnL)
        if (pnl >= 0) {
            return uint256(amount) + uint256(pnl);
        } else {
            int256 remainingMargin = int256(uint256(amount)) + pnl;
            return remainingMargin > 0 ? uint256(remainingMargin) : 0;
        }
    }
    
    /// @notice Gets the liquidation price for a position
    /// @param positionId The ID of the position
    /// @return The liquidation price
    function getLiquidationPrice(uint256 positionId) external view returns (uint128) {
        // Get position details
        (
            address trader,
            string memory asset,
            uint128 amount,
            uint128 entryPrice,
            bool isLong,
            bool isOpen
        ) = getPositionData(positionId);
        
        if (!isOpen) return 0;
        
        // Calculate the price at which margin would equal liquidation threshold
        uint256 maxLossPercentage = 100 - liquidationThreshold;
        
        if (isLong) {
            // For long positions, liquidation happens when price drops
            uint256 maxLossAmount = uint256(entryPrice) * maxLossPercentage / 100;
            return uint128(entryPrice > maxLossAmount ? entryPrice - maxLossAmount : 0);
        } else {
            // For short positions, liquidation happens when price rises
            uint256 maxLossAmount = uint256(entryPrice) * maxLossPercentage / 100;
            return uint128(entryPrice + maxLossAmount);
        }
    }
    
    /// @notice Gets positions that can be liquidated
    /// @param asset The asset to check
    /// @param startId The position ID to start from
    /// @param limit The maximum number of positions to check
    /// @return positionIds Array of liquidable position IDs
    function getLiquidablePositions(
        string calldata asset,
        uint256 startId,
        uint256 limit
    ) external view returns (uint256[] memory) {
        // This is a helper function for liquidation bots
        uint256 positionCount = market.getTotalPositions();
        uint256[] memory results = new uint256[](limit);
        uint256 resultCount = 0;
        
        for (uint256 i = startId; i < positionCount && resultCount < limit; i++) {
            // Get position
            (
                address trader,
                string memory posAsset,
                uint128 amount,
                uint128 entryPrice,
                bool isLong,
                bool isOpen
            ) = getPositionData(i);
            
            // Skip if not the requested asset or not open
            if (!isOpen || keccak256(bytes(posAsset)) != keccak256(bytes(asset))) {
                continue;
            }
            
            // Check if can be liquidated
            (bool shouldLiquidate, , ) = canLiquidate(i);
            
            if (shouldLiquidate) {
                results[resultCount] = i;
                resultCount++;
            }
        }
        
        // Create correctly sized array for results
        uint256[] memory liquidablePositions = new uint256[](resultCount);
        for (uint256 i = 0; i < resultCount; i++) {
            liquidablePositions[i] = results[i];
        }
        
        return liquidablePositions;
    }
}