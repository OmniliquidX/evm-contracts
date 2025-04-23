// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./AssetRegistry.sol";
import "./EnhancedOrderbook.sol";
import "./CollateralManager.sol";
import "./Oracle.sol";
import "./SecurityModule.sol";

// Forward declarations to avoid circular dependencies
interface ICrossMarginAccountManager {
    function hasAccount(address trader) external view returns (bool);
    function createAccount(address trader) external;
    function addPosition(address trader, uint256 positionId) external;
    function removePosition(address trader, uint256 positionId) external;
}

interface IFundingRateManager {
    function getCumulativeFundingRate(string calldata asset) external view returns (int256);
    function getCurrentFundingRate(string calldata asset) external view returns (int256);
    function updateFundingPaymentPointer(address trader, string calldata asset) external;
    function updateMarketSize(string calldata asset, uint256 longSize, uint256 shortSize) external;
    function getTimeUntilNextFunding(string calldata asset) external view returns (uint256);
    function updateFundingRate(string calldata asset) external returns (int256);
}

interface IEventEmitter {
    function emitPositionEvent(
        uint256 positionId,
        address trader,
        string calldata asset,
        uint128 size,
        uint128 price,
        bool isLong,
        uint256 leverage
    ) external;
    
    function emitTradeEvent(
        string calldata asset,
        address trader,
        uint128 amount,
        uint128 price,
        bool isLong,
        uint256 fee
    ) external;
}

interface ILiquidationEngine {
    function getLiquidationPrice(uint256 positionId) external view returns (uint128);
}

/// @title Market Contract for Omniliquid
/// @notice Facilitates spot and perpetual trading with enhanced risk controls
contract Market {
    enum MarketType { Spot, Perpetual }
    enum MarketStatus { Active, Restricted, Paused }

 struct Position {
    address trader;
    string asset;
    uint128 amount;
    uint128 entryPrice;
    uint128 leverage;
    int256 fundingIndex;
    bool isLong;
    bool isOpen;
    uint256 openTimestamp;
    uint256 lastUpdateTimestamp;
}
    
    struct MarketInfo {
        MarketType marketType;
        MarketStatus status;
        uint256 maxLeverage;
        uint256 maxPositionSize;
        uint256 takerFee;
        uint256 makerFee;
        uint256 minOrderSize;
        uint256 openInterestLong;
        uint256 openInterestShort;
        uint256 totalVolume;
        uint256 lastDailyVolumeReset;
        uint256 dailyVolume;
    }

    // Core dependencies
    AssetRegistry public assetRegistry;
    EnhancedOrderBook public orderBook;
    CollateralManager public collateralManager;
    Oracle public oracle;
    SecurityModule public securityModule;
    ICrossMarginAccountManager public crossMarginAccount;
    IFundingRateManager public fundingRateManager;
    ILiquidationEngine public liquidationEngine;
    IEventEmitter public eventEmitter;
    address public owner;
    address public positionManager;
    
    // Positions
    Position[] public positions;
    mapping(address => uint256[]) public userPositions;
    mapping(string => MarketInfo) public marketInfo;
    mapping(string => bool) public marketEnabled;
    
    // Additional market data
    mapping(string => uint256) public maxSkew;     // Maximum allowed skew (imbalance) per asset
    mapping(string => mapping(address => int256)) public userNetPosition; // User's net position by asset
    mapping(address => uint256) public userTradeCount;
    
    // Funding payments tracking
    mapping(string => mapping(address => int256)) public accumulatedFundingPayments;
    
    // Events
    event PositionOpened(
        uint256 indexed positionId, 
        address indexed trader, 
        string indexed asset, 
        uint128 amount, 
        uint128 entryPrice, 
        uint128 leverage,
        bool isLong
    );
    event PositionClosed(
        uint256 indexed positionId, 
        address indexed trader, 
        string indexed asset,
        uint128 exitPrice, 
        int256 pnl,
        uint256 fee
    );
    event PositionIncreased(
        uint256 indexed positionId,
        uint128 additionalAmount,
        uint128 newAmount,
        uint128 newEntryPrice
    );
    event PositionDecreased(
        uint256 indexed positionId,
        uint128 decreaseAmount,
        uint128 remainingAmount,
        uint128 exitPrice,
        int256 pnl,
        uint256 fee
    );
    event FundingPaid(
        string indexed asset,
        address indexed trader,
        int256 amount,
        int256 fundingRate
    );
    event MarketAdded(
        string indexed asset,
        MarketType marketType,
        uint256 maxLeverage,
        uint256 maxPositionSize
    );
    event MarketUpdated(
        string indexed asset,
        MarketStatus status,
        uint256 maxLeverage,
        uint256 maxPositionSize
    );
    event MarketSkewUpdated(
        string indexed asset,
        uint256 maxSkew
    );
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    
    // Errors
    error Unauthorized();
    error MarketDisabled();
    error StalePrice();
    error InvalidParameter();
    error MaxSkewExceeded();
    error MaxLeverageExceeded();
    error MaxPositionSizeExceeded();
    error InvalidPositionId();
    error NotPositionOwner();
    error PositionNotOpen();
    error MinOrderSizeNotMet();
    error DailyVolumeCapReached();
    
    // Modifiers
    modifier onlyOwner() {
        if (msg.sender != owner) revert Unauthorized();
        _;
    }
    
    modifier onlyPositionManager() {
        if (msg.sender != positionManager && msg.sender != owner) revert Unauthorized();
        _;
    }
    
    modifier onlyLiquidationEngine() {
        if (msg.sender != address(liquidationEngine) && msg.sender != owner) revert Unauthorized();
        _;
    }
    
    modifier marketActive(string memory asset) {
        if (!marketEnabled[asset]) revert MarketDisabled();
        if (marketInfo[asset].status != MarketStatus.Active) revert MarketDisabled();
        if (securityModule.paused()) revert MarketDisabled();
        if (securityModule.isAssetPaused(asset)) revert MarketDisabled();
        _;
    }

    constructor(
        address _assetRegistry,
        address _orderBook,
        address _oracle,
        address _securityModule,
        address _collateralManager,
        address _crossMarginAccount,
        address _fundingRateManager,
        address _eventEmitter
    ) {
        require(_assetRegistry != address(0), "Invalid asset registry");
        require(_orderBook != address(0), "Invalid order book");
        require(_oracle != address(0), "Invalid oracle");
        require(_securityModule != address(0), "Invalid security module");
        require(_collateralManager != address(0), "Invalid collateral manager");
        require(_crossMarginAccount != address(0), "Invalid cross-margin account");
        require(_fundingRateManager != address(0), "Invalid funding rate manager");
        require(_eventEmitter != address(0), "Invalid event emitter");
        
        assetRegistry = AssetRegistry(_assetRegistry);
        orderBook = EnhancedOrderBook(_orderBook);
        oracle = Oracle(_oracle);
        securityModule = SecurityModule(_securityModule);
        collateralManager = CollateralManager(_collateralManager);
        crossMarginAccount = ICrossMarginAccountManager(_crossMarginAccount);
        fundingRateManager = IFundingRateManager(_fundingRateManager);
        eventEmitter = IEventEmitter(_eventEmitter);
        owner = msg.sender;
    }
    
    /// @notice Transfers ownership of the contract to a new account
    /// @param newOwner The address of the new owner
    function transferOwnership(address newOwner) public onlyOwner {
        if (newOwner == address(0)) revert InvalidParameter();
        
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }

    function getPositionDetails(uint256 positionId) external view returns (
    address trader,
    string memory asset,
    uint128 amount,
    uint128 entryPrice,
    bool isLong,
    bool isOpen
) {
    Position storage position = positions[positionId];
    return (
        position.trader,
        position.asset,
        position.amount,
        position.entryPrice,
        position.isLong,
        position.isOpen
    );
}
    
    /// @notice Sets the position manager address
    /// @param _positionManager The position manager address
    function setPositionManager(address _positionManager) external onlyOwner {
        if (_positionManager == address(0)) revert InvalidParameter();
        
        positionManager = _positionManager;
    }
    
    /// @notice Sets the liquidation engine address
    /// @param _liquidationEngine The liquidation engine address
    function setLiquidationEngine(address _liquidationEngine) external onlyOwner {
        if (_liquidationEngine == address(0)) revert InvalidParameter();
        
        liquidationEngine = ILiquidationEngine(_liquidationEngine);
    }
    
    /// @notice Adds a new market
    /// @param asset The asset symbol
    /// @param marketType The market type (Spot or Perpetual)
    /// @param maxLeverage Maximum allowed leverage
    /// @param maxPositionSize Maximum allowed position size
    /// @param takerFee Taker fee in basis points
    /// @param makerFee Maker fee in basis points
    /// @param minOrderSize Minimum order size
    function addMarket(
        string calldata asset,
        MarketType marketType,
        uint256 maxLeverage,
        uint256 maxPositionSize,
        uint256 takerFee,
        uint256 makerFee,
        uint256 minOrderSize
    ) external onlyOwner {
        // Verify asset is registered
        try assetRegistry.getAsset(asset) returns (AssetRegistry.Asset memory) {
            // Asset exists
        } catch {
            revert InvalidParameter();
        }
        
        marketInfo[asset] = MarketInfo({
            marketType: marketType,
            status: MarketStatus.Active,
            maxLeverage: maxLeverage,
            maxPositionSize: maxPositionSize,
            takerFee: takerFee,
            makerFee: makerFee,
            minOrderSize: minOrderSize,
            openInterestLong: 0,
            openInterestShort: 0,
            totalVolume: 0,
            lastDailyVolumeReset: block.timestamp,
            dailyVolume: 0
        });
        
        marketEnabled[asset] = true;
        
        emit MarketAdded(asset, marketType, maxLeverage, maxPositionSize);
    }
    
    /// @notice Updates an existing market
    /// @param asset The asset symbol
    /// @param status The market status
    /// @param maxLeverage Maximum allowed leverage
    /// @param maxPositionSize Maximum allowed position size
    function updateMarket(
        string calldata asset,
        MarketStatus status,
        uint256 maxLeverage,
        uint256 maxPositionSize
    ) external onlyOwner {
        if (!marketEnabled[asset]) revert MarketDisabled();
        
        marketInfo[asset].status = status;
        marketInfo[asset].maxLeverage = maxLeverage;
        marketInfo[asset].maxPositionSize = maxPositionSize;
        
        emit MarketUpdated(asset, status, maxLeverage, maxPositionSize);
    }
    
    /// @notice Sets maximum skew (imbalance) for an asset
    /// @param asset The asset symbol
    /// @param newMaxSkew New maximum skew value
    function setMaxSkew(string calldata asset, uint256 newMaxSkew) external onlyOwner {
        maxSkew[asset] = newMaxSkew;
        
        emit MarketSkewUpdated(asset, newMaxSkew);
    }

    /// @notice Opens a new position in the market.
    /// @param asset The asset symbol.
    /// @param amount The amount to trade.
    /// @param leverage The leverage to use (1x for spot).
    /// @param isLong True for long position, false for short.
    function openPosition(
        string calldata asset,
        uint128 amount,
        uint128 leverage,
        bool isLong
    ) external marketActive(asset) {
        if (amount == 0) revert InvalidParameter();
        if (amount < marketInfo[asset].minOrderSize) revert MinOrderSizeNotMet();
        
        MarketInfo storage market = marketInfo[asset];
        
        // Check leverage limits
        if (leverage > market.maxLeverage) revert MaxLeverageExceeded();
        if (market.marketType == MarketType.Spot && leverage != 1) revert InvalidParameter();
        
        // Check position size limits
        uint128 positionSize = amount * leverage;
        if (uint256(positionSize) > market.maxPositionSize) revert MaxPositionSizeExceeded();
        
        // Get current price
        AssetRegistry.Asset memory assetDetails = assetRegistry.getAsset(asset);
        (uint128 price, uint128 timestamp) = oracle.getPrice(assetDetails.feedKey);
        
        // Check price freshness
        if (block.timestamp - timestamp > 1 hours) revert StalePrice();
        
        // Check skew limits for perps
        if (market.marketType == MarketType.Perpetual) {
            // Calculate new open interest
            uint256 newLongOI = market.openInterestLong;
            uint256 newShortOI = market.openInterestShort;
            
            if (isLong) {
                newLongOI += positionSize;
            } else {
                newShortOI += positionSize;
            }
            
            // Check if skew limit is exceeded
            if (maxSkew[asset] > 0) {
                uint256 totalOI = newLongOI + newShortOI;
                if (totalOI > 0) {
                    uint256 longPercent = (newLongOI * 100) / totalOI;
                    uint256 shortPercent = (newShortOI * 100) / totalOI;
                    uint256 skewPercent = longPercent > shortPercent ? 
                                          longPercent - shortPercent : 
                                          shortPercent - longPercent;
                    
                    if (skewPercent > maxSkew[asset]) revert MaxSkewExceeded();
                }
            }
        }
        
        // Calculate required collateral
        uint128 requiredCollateral = amount;
        
        // Lock collateral
        collateralManager.lockCollateral(msg.sender, requiredCollateral);
        
        // Create position
        uint256 positionId = positions.length;
        positions.push(Position({
            trader: msg.sender,
            asset: asset,
            amount: positionSize,
            entryPrice: price,
            leverage: leverage,
            fundingIndex: market.marketType == MarketType.Perpetual ? 
                         fundingRateManager.getCumulativeFundingRate(asset) : int256(0),
            isLong: isLong,
            isOpen: true,
            openTimestamp: block.timestamp,
            lastUpdateTimestamp: block.timestamp
        }));
        
        // Add to user positions
        userPositions[msg.sender].push(positionId);
        
        // Update user net position
        if (isLong) {
            userNetPosition[asset][msg.sender] += int256(uint256(positionSize));
        } else {
            userNetPosition[asset][msg.sender] -= int256(uint256(positionSize));
        }
        
        // Update open interest
        if (isLong) {
            market.openInterestLong += positionSize;
        } else {
            market.openInterestShort += positionSize;
        }
        
        // Update market volume
        uint256 notionalValue = uint256(amount) * uint256(leverage) * uint256(price) / 1e8;
        updateVolumeStats(asset, notionalValue);
        
        // Update user trade count
        userTradeCount[msg.sender]++;
        
        // Create cross-margin account if needed
        if (!crossMarginAccount.hasAccount(msg.sender)) {
            crossMarginAccount.createAccount(msg.sender);
        }
        
        // Add position to cross-margin account
        crossMarginAccount.addPosition(msg.sender, positionId);
        
        // Update funding rate manager with new market sizes
        if (market.marketType == MarketType.Perpetual) {
            fundingRateManager.updateMarketSize(asset, market.openInterestLong, market.openInterestShort);
        }
        
        // Emit events
        emit PositionOpened(
            positionId,
            msg.sender,
            asset,
            positionSize,
            price,
            leverage,
            isLong
        );
        
        // Emit to event emitter
        eventEmitter.emitPositionEvent(
            positionId,
            msg.sender,
            asset,
            positionSize,
            price,
            isLong,
            uint256(leverage)
        );
    }

    /// @notice Closes an existing position.
    /// @param positionId The ID of the position to close.
    function closePosition(uint256 positionId) external {
        if (positionId >= positions.length) revert InvalidPositionId();
        
        Position storage position = positions[positionId];
        
        if (position.trader != msg.sender) revert NotPositionOwner();
        if (!position.isOpen) revert PositionNotOpen();
        
        // Check if market is active
        if (!marketEnabled[position.asset]) revert MarketDisabled();
        
        // Get current price
        AssetRegistry.Asset memory assetDetails = assetRegistry.getAsset(position.asset);
        (uint128 price, uint128 timestamp) = oracle.getPrice(assetDetails.feedKey);
        
        // Check price freshness
        if (block.timestamp - timestamp > 1 hours) revert StalePrice();
        
        // Calculate PnL and settle funding
        (int256 pnl, int256 fundingPayment) = calculatePnL(position, price);
        
        // Process funding payments for perpetual markets
        if (marketInfo[position.asset].marketType == MarketType.Perpetual) {
            accumulatedFundingPayments[position.asset][position.trader] += fundingPayment;
            
            // Update funding payment pointer
            fundingRateManager.updateFundingPaymentPointer(position.trader, position.asset);
            
            // Emit funding payment event
            emit FundingPaid(
                position.asset,
                position.trader,
                fundingPayment,
                fundingRateManager.getCurrentFundingRate(position.asset)
            );
        }
        
        // Update position status
        position.isOpen = false;
        
        // Remove from cross-margin account
        crossMarginAccount.removePosition(position.trader, positionId);
        
        // Update user net position
        if (position.isLong) {
            userNetPosition[position.asset][position.trader] -= int256(uint256(position.amount));
        } else {
            userNetPosition[position.asset][position.trader] += int256(uint256(position.amount));
        }
        
        // Update open interest
        MarketInfo storage market = marketInfo[position.asset];
        if (position.isLong) {
            market.openInterestLong -= position.amount;
        } else {
            market.openInterestShort -= position.amount;
        }
        
        // Calculate fee based on notional value
        uint256 notionalValue = uint256(position.amount) * uint256(price) / 1e8;
        uint256 fee = (notionalValue * market.takerFee) / 10000;
        
        // Update market volume
        updateVolumeStats(position.asset, notionalValue);
        
        // Unlock collateral plus PnL minus fee
        int256 totalSettlement = pnl + fundingPayment - int256(fee);
        collateralManager.unlockCollateral(
            position.trader, 
            position.amount / position.leverage,
            totalSettlement
        );
        
        // Update funding rate manager with new market sizes
        if (market.marketType == MarketType.Perpetual) {
            fundingRateManager.updateMarketSize(position.asset, market.openInterestLong, market.openInterestShort);
        }
        
        // Emit events
        emit PositionClosed(positionId, position.trader, position.asset, price, pnl, fee);
        
        // Emit to event emitter
        eventEmitter.emitTradeEvent(
            position.asset,
            position.trader,
            position.amount,
            price,
            false, // Not relevant for close
            fee
        );
    }
    
    /// @notice Calculates the profit and loss of a position.
    /// @param position The position details.
    /// @param currentPrice The current price of the asset.
    /// @return pnl The profit or loss amount.
    /// @return fundingPayment The funding payment amount.
    function calculatePnL(
        Position memory position, 
        uint128 currentPrice
    ) public view returns (int256 pnl, int256 fundingPayment) {
        // Initialize funding payment to 0
        fundingPayment = 0;
        
        // For perpetual markets, calculate funding payment
        if (marketInfo[position.asset].marketType == MarketType.Perpetual) {
            int256 currentFundingIndex = fundingRateManager.getCumulativeFundingRate(position.asset);
            int256 fundingDelta = currentFundingIndex - position.fundingIndex;
            
            // Long positions pay positive funding rates, short positions receive
            if (position.isLong) {
                fundingPayment = -((fundingDelta * int256(uint256(position.amount))) / 1e18);
            } else {
                fundingPayment = (fundingDelta * int256(uint256(position.amount))) / 1e18;
            }
        }
        
        // Calculate PnL
        if (position.isLong) {
            // Long position: profit if price up, loss if price down
            if (currentPrice > position.entryPrice) {
                // Profit
                pnl = int256(uint256(position.amount) * uint256(currentPrice - position.entryPrice) / uint256(position.entryPrice));
            } else {
                // Loss
                pnl = -int256(uint256(position.amount) * uint256(position.entryPrice - currentPrice) / uint256(position.entryPrice));
            }
        } else {
            // Short position: profit if price down, loss if price up
            if (currentPrice < position.entryPrice) {
                // Profit
                pnl = int256(uint256(position.amount) * uint256(position.entryPrice - currentPrice) / uint256(position.entryPrice));
            } else {
                // Loss
                pnl = -int256(uint256(position.amount) * uint256(currentPrice - position.entryPrice) / uint256(position.entryPrice));
            }
        }
        
        return (pnl, fundingPayment);
    }
    
    /// @notice Updates volume statistics
    /// @param asset The asset symbol
    /// @param notionalValue The notional value to add
    function updateVolumeStats(string memory asset, uint256 notionalValue) internal {
        MarketInfo storage market = marketInfo[asset];
        
        // Reset daily volume if it's a new day
        if (block.timestamp >= market.lastDailyVolumeReset + 1 days) {
            market.dailyVolume = 0;
            market.lastDailyVolumeReset = block.timestamp;
        }
        
        // Update volume statistics
        market.totalVolume += notionalValue;
        market.dailyVolume += notionalValue;
    }
    
    /// @notice Opens a position initiated by the PositionManager
    /// @param trader The address of the trader
    /// @param asset The asset symbol
    /// @param amount The position amount
    /// @param leverage The leverage to use
    /// @param isLong True for long position, false for short
    /// @return The ID of the newly opened position
    function openPositionInternal(
        address trader,
        string calldata asset,
        uint128 amount,
        uint128 leverage,
        bool isLong
    ) external onlyPositionManager returns (uint256) {
        if (!marketEnabled[asset]) revert MarketDisabled();
        if (marketInfo[asset].status != MarketStatus.Active) revert MarketDisabled();
        if (securityModule.paused()) revert MarketDisabled();
        if (securityModule.isAssetPaused(asset)) revert MarketDisabled();
        
        // Get price
        AssetRegistry.Asset memory assetDetails = assetRegistry.getAsset(asset);
        (uint128 price, uint128 timestamp) = oracle.getPrice(assetDetails.feedKey);
        
        // Check price freshness
        if (block.timestamp - timestamp > 1 hours) revert StalePrice();
        
        // Create position
        uint256 positionId = positions.length;
        positions.push(Position({
            trader: trader,
            asset: asset,
            amount: amount,
            entryPrice: price,
            leverage: leverage,
            fundingIndex: marketInfo[asset].marketType == MarketType.Perpetual ? 
                         fundingRateManager.getCumulativeFundingRate(asset) : int256(0),
            isLong: isLong,
            isOpen: true,
            openTimestamp: block.timestamp,
            lastUpdateTimestamp: block.timestamp
        }));
        
        // Add to user positions
        userPositions[trader].push(positionId);
        
        // Update user net position
        if (isLong) {
            userNetPosition[asset][trader] += int256(uint256(amount));
            marketInfo[asset].openInterestLong += amount;
        } else {
            userNetPosition[asset][trader] -= int256(uint256(amount));
            marketInfo[asset].openInterestShort += amount;
        }
        
        // Update volume statistics
        uint256 notionalValue = uint256(amount) * uint256(price) / 1e8;
        updateVolumeStats(asset, notionalValue);
        
        // Update user trade count
        userTradeCount[trader]++;
        
        // Create cross-margin account if needed
        if (!crossMarginAccount.hasAccount(trader)) {
            crossMarginAccount.createAccount(trader);
        }
        
        // Add position to cross-margin account
        crossMarginAccount.addPosition(trader, positionId);
        
        // Update funding rate manager with new market sizes
        if (marketInfo[asset].marketType == MarketType.Perpetual) {
            fundingRateManager.updateMarketSize(
                asset, 
                marketInfo[asset].openInterestLong, 
                marketInfo[asset].openInterestShort
            );
        }
        
        // Emit events
        emit PositionOpened(
            positionId,
            trader,
            asset,
            amount,
            price,
            leverage,
            isLong
        );
        
        // Emit to event emitter
        eventEmitter.emitPositionEvent(
            positionId,
            trader,
            asset,
            amount,
            price,
            isLong,
            uint256(leverage)
        );
        
        return positionId;
    }
    
    /// @notice Increases the size of a position
    /// @param positionId The ID of the position to increase
    /// @param additionalAmount The additional position amount
    function increasePositionInternal(
        uint256 positionId,
        uint128 additionalAmount
    ) external onlyPositionManager {
        if (positionId >= positions.length) revert InvalidPositionId();
        
        Position storage position = positions[positionId];
        if (!position.isOpen) revert PositionNotOpen();
        
        // Check if market is active
        if (!marketEnabled[position.asset]) revert MarketDisabled();
        if (marketInfo[position.asset].status != MarketStatus.Active) revert MarketDisabled();
        
        // Get current price
        AssetRegistry.Asset memory assetDetails = assetRegistry.getAsset(position.asset);
        (uint128 price, uint128 timestamp) = oracle.getPrice(assetDetails.feedKey);
        
        // Check price freshness
        if (block.timestamp - timestamp > 1 hours) revert StalePrice();
        
        // Calculate a new weighted average entry price
        uint256 totalValue = uint256(position.amount) * uint256(position.entryPrice) + 
                              uint256(additionalAmount) * uint256(price);
        uint128 newEntryPrice = uint128(totalValue / (uint256(position.amount) + uint256(additionalAmount)));
        
        // Update position
        uint128 oldAmount = position.amount;
        position.amount += additionalAmount;
        position.entryPrice = newEntryPrice;
        position.lastUpdateTimestamp = block.timestamp;
        
        // For perpetual markets, update funding index
        if (marketInfo[position.asset].marketType == MarketType.Perpetual) {
            // Settle funding for the existing position
            int256 currentFundingIndex = fundingRateManager.getCumulativeFundingRate(position.asset);
            int256 fundingDelta = currentFundingIndex - position.fundingIndex;
            
            // Calculate funding payment
            int256 fundingPayment = 0;
            if (position.isLong) {
                fundingPayment = -((fundingDelta * int256(uint256(oldAmount))) / 1e18);
            } else {
                fundingPayment = (fundingDelta * int256(uint256(oldAmount))) / 1e18;
            }
            
            // Record funding payment
            accumulatedFundingPayments[position.asset][position.trader] += fundingPayment;
            
            // Update funding index
            position.fundingIndex = currentFundingIndex;
            
            // Emit funding payment event
            emit FundingPaid(
                position.asset,
                position.trader,
                fundingPayment,
                fundingRateManager.getCurrentFundingRate(position.asset)
            );
        }
        
        // Update user net position
        if (position.isLong) {
            userNetPosition[position.asset][position.trader] += int256(uint256(additionalAmount));
            marketInfo[position.asset].openInterestLong += additionalAmount;
        } else {
            userNetPosition[position.asset][position.trader] -= int256(uint256(additionalAmount));
            marketInfo[position.asset].openInterestShort += additionalAmount;
        }
        
        // Update market volume
        uint256 notionalValue = uint256(additionalAmount) * uint256(price) / 1e8;
        updateVolumeStats(position.asset, notionalValue);
        
        // Update funding rate manager with new market sizes
        if (marketInfo[position.asset].marketType == MarketType.Perpetual) {
            fundingRateManager.updateMarketSize(
                position.asset, 
                marketInfo[position.asset].openInterestLong, 
                marketInfo[position.asset].openInterestShort
            );
        }
        
        // Emit events
        emit PositionIncreased(positionId, additionalAmount, position.amount, newEntryPrice);
    }
    
    /// @notice Decreases the size of a position
    /// @param positionId The ID of the position to decrease
    /// @param decreaseAmount The amount to decrease by
    /// @param trader The address of the trader
    function decreasePositionInternal(
        uint256 positionId,
        uint128 decreaseAmount,
        address trader
    ) external onlyPositionManager {
        if (positionId >= positions.length) revert InvalidPositionId();
        
        Position storage position = positions[positionId];
        if (position.trader != trader) revert NotPositionOwner();
        if (!position.isOpen) revert PositionNotOpen();
        if (decreaseAmount > position.amount) revert InvalidParameter();
        
        // Check if market is active
        if (!marketEnabled[position.asset]) revert MarketDisabled();
        
        // Get current price
        AssetRegistry.Asset memory assetDetails = assetRegistry.getAsset(position.asset);
        (uint128 price, uint128 timestamp) = oracle.getPrice(assetDetails.feedKey);
        
        // Check price freshness
        if (block.timestamp - timestamp > 1 hours) revert StalePrice();
        
        // Calculate PnL and funding payment for the decreased portion
        (int256 fullPnl, int256 fullFundingPayment) = calculatePnL(position, price);
        
        // Calculate portion ratio
        uint256 portionRatio = (uint256(decreaseAmount) * 1e18) / uint256(position.amount);
        
        // Calculate PnL and funding for the decreased portion
        int256 portionPnl = (fullPnl * int256(portionRatio)) / 1e18;
        int256 portionFundingPayment = (fullFundingPayment * int256(portionRatio)) / 1e18;
        
        // For perpetual markets, update funding index
        if (marketInfo[position.asset].marketType == MarketType.Perpetual) {
            // Record funding payment
            accumulatedFundingPayments[position.asset][position.trader] += portionFundingPayment;
            
            // Update funding index for remaining position
            position.fundingIndex = fundingRateManager.getCumulativeFundingRate(position.asset);
            
            // Emit funding payment event
            emit FundingPaid(
                position.asset,
                position.trader,
                portionFundingPayment,
                fundingRateManager.getCurrentFundingRate(position.asset)
            );
        }
        
        // Update user net position
        if (position.isLong) {
            userNetPosition[position.asset][position.trader] -= int256(uint256(decreaseAmount));
            marketInfo[position.asset].openInterestLong -= decreaseAmount;
        } else {
            userNetPosition[position.asset][position.trader] += int256(uint256(decreaseAmount));
            marketInfo[position.asset].openInterestShort -= decreaseAmount;
        }
        
        // Calculate fee
        uint256 notionalValue = uint256(decreaseAmount) * uint256(price) / 1e8;
        uint256 fee = (notionalValue * marketInfo[position.asset].takerFee) / 10000;
        
        // Update market volume
        updateVolumeStats(position.asset, notionalValue);
        
        // Update position amount
        position.amount -= decreaseAmount;
        position.lastUpdateTimestamp = block.timestamp;
        
        // Close position if amount becomes zero
        if (position.amount == 0) {
            position.isOpen = false;
            
            // Remove from cross-margin account
            crossMarginAccount.removePosition(position.trader, positionId);
        }
        
        // Update funding rate manager with new market sizes
        if (marketInfo[position.asset].marketType == MarketType.Perpetual) {
            fundingRateManager.updateMarketSize(
                position.asset, 
                marketInfo[position.asset].openInterestLong, 
                marketInfo[position.asset].openInterestShort
            );
        }
        
        // Return collateral + PnL - fee for the decreased portion
        int256 totalSettlement = portionPnl + portionFundingPayment - int256(fee);
        collateralManager.unlockCollateral(
            trader, 
            decreaseAmount / position.leverage,
            totalSettlement
        );
        
        // Emit events
        emit PositionDecreased(positionId, decreaseAmount, position.amount, price, portionPnl, fee);
    }
    
    /// @notice Force liquidates a position
    /// @param positionId The ID of the position to liquidate
    /// @param liquidator The address of the liquidator
    function forceLiquidate(
        uint256 positionId,
        address liquidator
    ) external onlyLiquidationEngine {
        if (positionId >= positions.length) revert InvalidPositionId();
        
        Position storage position = positions[positionId];
        if (!position.isOpen) revert PositionNotOpen();
        
        // Get current price
        AssetRegistry.Asset memory assetDetails = assetRegistry.getAsset(position.asset);
        (uint128 price, uint128 timestamp) = oracle.getPrice(assetDetails.feedKey);
        
        // Check price freshness
        if (block.timestamp - timestamp > 1 hours) revert StalePrice();
        
        // Calculate PnL and funding
        (int256 pnl, int256 fundingPayment) = calculatePnL(position, price);
        
        // For perpetual markets, update funding
        if (marketInfo[position.asset].marketType == MarketType.Perpetual) {
            // Record funding payment
            accumulatedFundingPayments[position.asset][position.trader] += fundingPayment;
            
            // Emit funding payment event
            emit FundingPaid(
                position.asset,
                position.trader,
                fundingPayment,
                fundingRateManager.getCurrentFundingRate(position.asset)
            );
        }
        
        // Update user net position
        if (position.isLong) {
            userNetPosition[position.asset][position.trader] -= int256(uint256(position.amount));
            marketInfo[position.asset].openInterestLong -= position.amount;
        } else {
            userNetPosition[position.asset][position.trader] += int256(uint256(position.amount));
            marketInfo[position.asset].openInterestShort -= position.amount;
        }
        
        // Mark position as closed
        position.isOpen = false;
        
        // Remove from cross-margin account
        crossMarginAccount.removePosition(position.trader, positionId);
        
        // Update funding rate manager with new market sizes
        if (marketInfo[position.asset].marketType == MarketType.Perpetual) {
            fundingRateManager.updateMarketSize(
                position.asset, 
                marketInfo[position.asset].openInterestLong, 
                marketInfo[position.asset].openInterestShort
            );
        }
        
        // No need to unlock collateral here, it's handled by LiquidationEngine
        
        // Emit events
        emit PositionClosed(positionId, position.trader, position.asset, price, pnl, 0);
    }
    
    /// @notice Gets the total number of positions
    /// @return The number of positions
    function getTotalPositions() external view returns (uint256) {
        return positions.length;
    }
    
    /// @notice Gets all positions for a trader
    /// @param trader The trader's address
    /// @return An array of position IDs
    function getPositionsForTrader(address trader) external view returns (uint256[] memory) {
        return userPositions[trader];
    }
    
    /// @notice Gets all open positions for a trader
    /// @param trader The trader's address
    /// @return An array of open position IDs
    function getOpenPositionsForTrader(address trader) external view returns (uint256[] memory) {
        uint256[] memory allPositions = userPositions[trader];
        uint256 openCount = 0;
        
        // Count open positions
        for (uint256 i = 0; i < allPositions.length; i++) {
            if (positions[allPositions[i]].isOpen) {
                openCount++;
            }
        }
        
        // Create result array
        uint256[] memory openPositions = new uint256[](openCount);
        uint256 index = 0;
        
        // Fill result array
        for (uint256 i = 0; i < allPositions.length; i++) {
            if (positions[allPositions[i]].isOpen) {
                openPositions[index] = allPositions[i];
                index++;
            }
        }
        
        return openPositions;
    }
    
    /// @notice Gets positions for a trader by asset
    /// @param trader The trader's address
    /// @param asset The asset symbol
    /// @return An array of position IDs
    function getPositionsForTraderByAsset(address trader, string calldata asset) external view returns (uint256[] memory) {
        uint256[] memory allPositions = userPositions[trader];
        uint256 matchCount = 0;
        
        // Count matching positions
        for (uint256 i = 0; i < allPositions.length; i++) {
            if (keccak256(bytes(positions[allPositions[i]].asset)) == keccak256(bytes(asset))) {
                matchCount++;
            }
        }
        
        // Create result array
        uint256[] memory matchingPositions = new uint256[](matchCount);
        uint256 index = 0;
        
        // Fill result array
        for (uint256 i = 0; i < allPositions.length; i++) {
            if (keccak256(bytes(positions[allPositions[i]].asset)) == keccak256(bytes(asset))) {
                matchingPositions[index] = allPositions[i];
                index++;
            }
        }
        
        return matchingPositions;
    }
    
    /// @notice Gets the total open interest for an asset
    /// @param asset The asset symbol
    /// @return longOI The long open interest
    /// @return shortOI The short open interest
    function getOpenInterest(string calldata asset) external view returns (uint256 longOI, uint256 shortOI) {
        return (marketInfo[asset].openInterestLong, marketInfo[asset].openInterestShort);
    }
    
    /// @notice Gets the user's net position for an asset
    /// @param trader The trader's address
    /// @param asset The asset symbol
    /// @return The net position (positive for net long, negative for net short)
    function getUserNetPosition(address trader, string calldata asset) external view returns (int256) {
        return userNetPosition[asset][trader];
    }
    
    /// @notice Gets the accumulated funding payments for a user
    /// @param trader The trader's address
    /// @param asset The asset symbol
    /// @return The accumulated funding payments
    function getAccumulatedFundingPayments(address trader, string calldata asset) external view returns (int256) {
        return accumulatedFundingPayments[asset][trader];
    }
    
    /// @notice Gets the market info for an asset
    /// @param asset The asset symbol
    /// @return The market info
    function getMarketInfo(string calldata asset) external view returns (MarketInfo memory) {
        return marketInfo[asset];
    }
    
    /// @notice Gets the volume statistics for an asset
    /// @param asset The asset symbol
    /// @return totalVolume The total volume
    /// @return dailyVolume The daily volume
    function getVolumeStats(string calldata asset) external view returns (uint256 totalVolume, uint256 dailyVolume) {
        MarketInfo storage market = marketInfo[asset];
        
        // Handle day rollover if needed
        if (block.timestamp >= market.lastDailyVolumeReset + 1 days) {
            return (market.totalVolume, 0);
        } else {
            return (market.totalVolume, market.dailyVolume);
        }
    }
    
    /// @notice Settles funding payments for a trader
    /// @param trader The trader's address
    /// @param asset The asset symbol
    /// @return The settled funding payment amount
    function settleFundingPayments(address trader, string calldata asset) external onlyPositionManager returns (int256) {
        int256 payment = accumulatedFundingPayments[asset][trader];
        
        // Reset accumulated payments
        accumulatedFundingPayments[asset][trader] = 0;
        
        return payment;
    }
    
    /// @notice Processes funding rate updates for all perpetual assets
    /// @param assets The array of asset symbols to update
    function processFundingRates(string[] calldata assets) external {
        for (uint256 i = 0; i < assets.length; i++) {
            // Skip if market not enabled or not perpetual
            if (!marketEnabled[assets[i]] || marketInfo[assets[i]].marketType != MarketType.Perpetual) {
                continue;
            }
            
            // Try to update funding rate
            try fundingRateManager.updateFundingRate(assets[i]) returns (int256 rate) {
                // Successfully updated
            } catch {
                // Ignore errors and continue with next asset
            }
        }
    }
    
    /// @notice Gets the liquidation price for a position
    /// @param positionId The position ID
    /// @return The liquidation price
    function getLiquidationPrice(uint256 positionId) external view returns (uint128) {
        return liquidationEngine.getLiquidationPrice(positionId);
    }
    
    /// @notice Gets the time until next funding for an asset
    /// @param asset The asset symbol
    /// @return Time in seconds until next funding
    function getTimeUntilNextFunding(string calldata asset) external view returns (uint256) {
        return fundingRateManager.getTimeUntilNextFunding(asset);
    }
}