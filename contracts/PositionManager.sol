// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
pragma experimental ABIEncoderV2;

import "./Market.sol";
import "./CollateralManager.sol";
import "./AssetRegistry.sol";
import "./Oracle.sol";
import "./FeeManager.sol";
import "./RiskManager.sol";

/// @title Position Manager for Omniliquid
/// @notice Manages position lifecycle: opening, modifying, and closing positions
contract PositionManager {
    // Core contracts
    Market public market;
    CollateralManager public collateralManager;
    AssetRegistry public assetRegistry;
    Oracle public oracle;
    FeeManager public feeManager;
    RiskManager public riskManager;
    address public owner;
    
    // Position limits
    uint256 public maxLeverage = 20; // 20x max leverage
    uint256 public minPositionSize = 10**16; // 0.01 ETH minimum
    uint256 public absoluteMaxPositionSize = 1000 ether; // Hard cap on position size
    
    // Stop loss and take profit tracking
    struct PositionOrder {
        uint128 triggerPrice;
        bool isStopLoss;      // true = stop loss, false = take profit
        bool isActive;
    }
    
    // Mapping from positionId to its orders
    mapping(uint256 => PositionOrder[]) public positionOrders;
    
    // Events
    event PositionIncreased(uint256 indexed positionId, uint128 additionalAmount);
    event PositionDecreased(uint256 indexed positionId, uint128 decreasedAmount);
    event StopLossAdded(uint256 indexed positionId, uint128 triggerPrice);
    event TakeProfitAdded(uint256 indexed positionId, uint128 triggerPrice);
    event OrderCancelled(uint256 indexed positionId, uint256 indexed orderId);
    event OrderTriggered(uint256 indexed positionId, uint256 indexed orderId, bool isStopLoss);
    event LeverageChanged(uint256 maxLeverage);
    event MinPositionSizeChanged(uint256 minPositionSize);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    modifier onlyOwner() {
        require(msg.sender == owner, "Not authorized");
        _;
    }

    constructor(
        address _market,
        address _collateralManager,
        address _assetRegistry,
        address _oracle,
        address _feeManager,
        address _riskManager
    ) {
        require(_market != address(0), "Invalid market address");
        require(_collateralManager != address(0), "Invalid collateral manager address");
        require(_assetRegistry != address(0), "Invalid asset registry address");
        require(_oracle != address(0), "Invalid oracle address");
        require(_feeManager != address(0), "Invalid fee manager address");
        require(_riskManager != address(0), "Invalid risk manager address");
        
        market = Market(_market);
        collateralManager = CollateralManager(_collateralManager);
        assetRegistry = AssetRegistry(_assetRegistry);
        oracle = Oracle(_oracle);
        feeManager = FeeManager(payable(_feeManager));
        riskManager = RiskManager(_riskManager);
        owner = msg.sender;
    }
    
    /// @notice Transfers ownership of the contract to a new account
    /// @param newOwner The address of the new owner
    function transferOwnership(address newOwner) public onlyOwner {
        require(newOwner != address(0), "New owner cannot be the zero address");
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }
    
    /// @notice Sets the maximum leverage allowed
    /// @param _maxLeverage The new maximum leverage multiplier
    function setMaxLeverage(uint256 _maxLeverage) external onlyOwner {
        require(_maxLeverage > 0 && _maxLeverage <= 100, "Invalid leverage");
        maxLeverage = _maxLeverage;
        emit LeverageChanged(_maxLeverage);
    }
    
    /// @notice Sets the minimum position size
    /// @param _minPositionSize The new minimum position size in wei
    function setMinPositionSize(uint256 _minPositionSize) external onlyOwner {
        require(_minPositionSize > 0, "Invalid min position size");
        minPositionSize = _minPositionSize;
        emit MinPositionSizeChanged(_minPositionSize);
    }
    
    /// @notice Opens a leveraged position
    /// @param asset The asset symbol to trade
    /// @param collateralAmount The amount of collateral to use
    /// @param leverage The leverage multiplier (e.g., 5 for 5x)
    /// @param isLong Whether this is a long (true) or short (false) position
    /// @return The ID of the newly opened position
    function openLeveragedPosition(
        string calldata asset,
        uint128 collateralAmount,
        uint256 leverage,
        bool isLong
    ) external returns (uint256) {
        // Validate parameters
        require(collateralAmount >= minPositionSize, "Position size too small");
        require(leverage > 0 && leverage <= maxLeverage, "Invalid leverage");
        
        // Calculate position size with leverage
        uint128 positionSize = uint128(uint256(collateralAmount) * leverage);
        
        // Add size limit check
        require(positionSize <= absoluteMaxPositionSize, "Position too large");
        
        // Check against global open interest limits via RiskManager
        require(riskManager.isPositionSizeValid(asset, positionSize), "Size exceeds limits");
        
        // Check if leverage is valid for this specific asset
        require(riskManager.isLeverageValid(asset, leverage), "Leverage not allowed for asset");
        
        // Lock collateral
        collateralManager.lockCollateral(msg.sender, collateralAmount);
        
        // Calculate and collect fees
        uint256 fee = feeManager.calculateFee(collateralAmount, "taker", msg.sender);
        feeManager.collectFee(fee, "taker", msg.sender);
        
        // Open position through the market contract
        uint256 positionId = market.openPositionInternal(
            msg.sender,
            asset,
            positionSize,
            uint128(leverage),
            isLong
        );
        
        return positionId;
    }
    
    /// @notice Increases the size of an existing position
    /// @param positionId The ID of the position to increase
    /// @param additionalCollateral The additional collateral amount
    /// @param leverage The leverage to apply to the additional amount
    function increasePosition(
        uint256 positionId,
        uint128 additionalCollateral,
        uint256 leverage
    ) external {
        // Get position details from market
        address trader;
        string memory asset;
        uint128 amount;
        uint128 entryPrice;
        bool isLong;
        bool isOpen;
        
        // Get position data
        (trader, asset, amount, entryPrice, isLong, isOpen) = market.getPositionDetails(positionId);
        
        require(trader == msg.sender, "Not position owner");
        require(isOpen, "Position not open");
        require(leverage > 0 && leverage <= maxLeverage, "Invalid leverage");
        
        // Calculate additional position size
        uint128 additionalAmount = uint128(uint256(additionalCollateral) * leverage);
        
        // Verify against position size limits
        require(amount + additionalAmount <= absoluteMaxPositionSize, "Position too large");
        
        // Check against global open interest limits via RiskManager
        require(riskManager.isPositionSizeValid(asset, additionalAmount), "Size exceeds limits");
        
        // Lock additional collateral
        collateralManager.lockCollateral(msg.sender, additionalCollateral);
        
        // Calculate and collect fees
        uint256 fee = feeManager.calculateFee(additionalCollateral, "taker", msg.sender);
        feeManager.collectFee(fee, "taker", msg.sender);
        
        // Increase position through the market contract
        market.increasePositionInternal(positionId, additionalAmount);
        
        emit PositionIncreased(positionId, additionalAmount);
    }
    
    /// @notice Decreases the size of an existing position
    /// @param positionId The ID of the position to decrease
    /// @param decreasePercent The percentage to decrease (1-100)
    function decreasePosition(
        uint256 positionId,
        uint8 decreasePercent
    ) external {
        require(decreasePercent > 0 && decreasePercent < 100, "Invalid decrease percentage");
        
        // Get position details from market
        address trader;
        string memory asset;
        uint128 amount;
        uint128 entryPrice;
        bool isLong;
        bool isOpen;
        
        // Get position data
        (trader, asset, amount, entryPrice, isLong, isOpen) = market.getPositionDetails(positionId);(positionId);
        
        require(trader == msg.sender, "Not position owner");
        require(isOpen, "Position not open");
        
        // Calculate amount to decrease
        uint128 decreaseAmount = uint128(uint256(amount) * decreasePercent / 100);
        require(decreaseAmount > 0, "Decrease amount too small");
        
        // Calculate collateral to unlock (accounting for leverage)
        AssetRegistry.Asset memory assetDetails = assetRegistry.getAsset(asset);
        (uint128 currentPrice, ) = oracle.getPrice(assetDetails.feedKey);
        
        // Calculate and collect fees
        uint256 decreaseValue = uint256(decreaseAmount) * uint256(currentPrice) / 1e8; // Assuming 8 decimal price
        uint256 fee = feeManager.calculateFee(decreaseValue, "taker", msg.sender);
        feeManager.collectFee(fee, "taker", msg.sender);
        
        // Decrease position through the market contract
        market.decreasePositionInternal(positionId, decreaseAmount, msg.sender);
        
        emit PositionDecreased(positionId, decreaseAmount);
    }
    
    /// @notice Adds a stop loss to a position
    /// @param positionId The ID of the position
    /// @param stopLossPrice The price at which to trigger the stop loss
    /// @return orderId The ID of the stop loss order
    function addStopLoss(uint256 positionId, uint128 stopLossPrice) external returns (uint256) {
        // Get position details from market
        address trader;
        string memory asset;
        uint128 amount;
        uint128 entryPrice;
        bool isLong;
        bool isOpen;
        
        // Get position data
        (trader, asset, amount, entryPrice, isLong, isOpen) = market.getPositionDetails(positionId);
        
        require(trader == msg.sender, "Not position owner");
        require(isOpen, "Position not open");
        
        // Verify stop loss price is valid
        if (isLong) {
            // For long positions, stop loss must be below entry price
            require(stopLossPrice < entryPrice, "Invalid stop price for long");
        } else {
            // For short positions, stop loss must be above entry price
            require(stopLossPrice > entryPrice, "Invalid stop price for short");
        }
        
        // Check current price to ensure stop loss isn't immediately triggered
        AssetRegistry.Asset memory assetDetails = assetRegistry.getAsset(asset);
        (uint128 currentPrice, ) = oracle.getPrice(assetDetails.feedKey);
        
        if (isLong) {
            require(stopLossPrice < currentPrice, "Stop loss would trigger immediately");
        } else {
            require(stopLossPrice > currentPrice, "Stop loss would trigger immediately");
        }
        
        // Add the stop loss to position orders
        positionOrders[positionId].push(PositionOrder({
            triggerPrice: stopLossPrice,
            isStopLoss: true,
            isActive: true
        }));
        
        uint256 orderId = positionOrders[positionId].length - 1;
        
        emit StopLossAdded(positionId, stopLossPrice);
        
        return orderId;
    }
    
    /// @notice Adds a take profit to a position
    /// @param positionId The ID of the position
    /// @param takeProfitPrice The price at which to trigger the take profit
    /// @return orderId The ID of the take profit order
    function addTakeProfit(uint256 positionId, uint128 takeProfitPrice) external returns (uint256) {
        // Get position details from market
        address trader;
        string memory asset;
        uint128 amount;
        uint128 entryPrice;
        bool isLong;
        bool isOpen;
        
        // Get position data
        (trader, asset, amount, entryPrice, isLong, isOpen) = market.getPositionDetails(positionId);
        
        require(trader == msg.sender, "Not position owner");
        require(isOpen, "Position not open");
        
        // Verify take profit price is valid
        if (isLong) {
            // For long positions, take profit must be above entry price
            require(takeProfitPrice > entryPrice, "Invalid take profit for long");
        } else {
            // For short positions, take profit must be below entry price
            require(takeProfitPrice < entryPrice, "Invalid take profit for short");
        }
        
        // Check current price to ensure take profit isn't immediately triggered
        AssetRegistry.Asset memory assetDetails = assetRegistry.getAsset(asset);
        (uint128 currentPrice, ) = oracle.getPrice(assetDetails.feedKey);
        
        if (isLong) {
            require(takeProfitPrice > currentPrice, "Take profit would trigger immediately");
        } else {
            require(takeProfitPrice < currentPrice, "Take profit would trigger immediately");
        }
        
        // Add the take profit to position orders
        positionOrders[positionId].push(PositionOrder({
            triggerPrice: takeProfitPrice,
            isStopLoss: false,
            isActive: true
        }));
        
        uint256 orderId = positionOrders[positionId].length - 1;
        
        emit TakeProfitAdded(positionId, takeProfitPrice);
        
        return orderId;
    }
    
    /// @notice Cancels a stop loss or take profit order
    /// @param positionId The ID of the position
    /// @param orderId The ID of the order to cancel
    function cancelOrder(uint256 positionId, uint256 orderId) external {
        // Get position details from market
        address trader;
        string memory asset;
        uint128 amount;
        uint128 entryPrice;
        bool isLong;
        bool isOpen;
        
        // Get position data
        (trader, asset, amount, entryPrice, isLong, isOpen) = market.getPositionDetails(positionId);(positionId);
        
        require(trader == msg.sender, "Not position owner");
        require(orderId < positionOrders[positionId].length, "Invalid order ID");
        require(positionOrders[positionId][orderId].isActive, "Order not active");
        
        // Cancel the order
        positionOrders[positionId][orderId].isActive = false;
        
        emit OrderCancelled(positionId, orderId);
    }
    
    /// @notice Checks and executes triggered orders (to be called by price oracles or keepers)
    /// @param positionId The ID of the position to check
    /// @param currentPrice The current price of the asset
    /// @return triggered Whether any orders were triggered
    function checkAndExecuteOrders(uint256 positionId, uint128 currentPrice) external returns (bool) {
        require(msg.sender == owner || msg.sender == address(oracle), "Not authorized");
        
        // Get position details from market
        address trader;
        string memory asset;
        uint128 amount;
        uint128 entryPrice;
        bool isLong;
        bool isOpen;
        
        // Get position data
        (trader, asset, amount, entryPrice, isLong, isOpen) = market.getPositionDetails(positionId);(positionId);
        
        if (!isOpen) return false;
        
        bool triggered = false;
        PositionOrder[] storage orders = positionOrders[positionId];
        
        for (uint256 i = 0; i < orders.length; i++) {
            PositionOrder storage order = orders[i];
            
            if (!order.isActive) continue;
            
            bool shouldTrigger = false;
            
            if (order.isStopLoss) {
                // Stop loss logic
                if (isLong) {
                    // Long position: trigger if price falls below stop loss
                    shouldTrigger = currentPrice <= order.triggerPrice;
                } else {
                    // Short position: trigger if price rises above stop loss
                    shouldTrigger = currentPrice >= order.triggerPrice;
                }
            } else {
                // Take profit logic
                if (isLong) {
                    // Long position: trigger if price rises above take profit
                    shouldTrigger = currentPrice >= order.triggerPrice;
                } else {
                    // Short position: trigger if price falls below take profit
                    shouldTrigger = currentPrice <= order.triggerPrice;
                }
            }
            
            if (shouldTrigger) {
                // Mark as inactive before executing to prevent reentrancy
                order.isActive = false;
                
                // Close the position - this will handle collateral, PnL, etc.
                if (order.isStopLoss) {
                    // For stop loss, we close the position or reduce by 100%
                    market.decreasePositionInternal(positionId, amount, trader);
                } else {
                    // For take profit, we close the position or reduce by 100%
                    market.decreasePositionInternal(positionId, amount, trader);
                }
                
                emit OrderTriggered(positionId, i, order.isStopLoss);
                triggered = true;
            }
        }
        
        return triggered;
    }
    
    /// @notice Gets all active orders for a position
    /// @param positionId The ID of the position
    /// @return orderIds Array of order IDs
    /// @return triggerPrices Array of trigger prices
    /// @return isStopLoss Array of flags indicating if orders are stop losses
    function getActiveOrders(uint256 positionId) external view returns (
        uint256[] memory orderIds,
        uint128[] memory triggerPrices,
        bool[] memory isStopLoss
    ) {
        PositionOrder[] storage orders = positionOrders[positionId];
        
        // Count active orders
        uint256 activeCount = 0;
        for (uint256 i = 0; i < orders.length; i++) {
            if (orders[i].isActive) {
                activeCount++;
            }
        }
        
        // Initialize arrays
        orderIds = new uint256[](activeCount);
        triggerPrices = new uint128[](activeCount);
        isStopLoss = new bool[](activeCount);
        
        // Fill arrays
        uint256 index = 0;
        for (uint256 i = 0; i < orders.length; i++) {
            if (orders[i].isActive) {
                orderIds[index] = i;
                triggerPrices[index] = orders[i].triggerPrice;
                isStopLoss[index] = orders[i].isStopLoss;
                index++;
            }
        }
        
        return (orderIds, triggerPrices, isStopLoss);
    }
    
    /// @notice Gets the liquidation price for a position
    /// @param positionId The ID of the position
    /// @return liquidationPrice The price at which the position would be liquidated
    function getLiquidationPrice(uint256 positionId) external view returns (uint128) {
        return market.getLiquidationPrice(positionId);
    }
}