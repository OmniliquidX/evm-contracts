// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
pragma experimental ABIEncoderV2;

import "./AssetRegistry.sol";
import "./Oracle.sol";
import "./SecurityModule.sol";

/// @title Funding Rate Manager for Omniliquid
/// @notice Manages funding rates with improved EMA calculation and robust rate limiting
contract FundingRateManager {
    struct FundingState {
        int256 cumulativeFundingRate;    // Accumulated funding rate (scaled by 1e18)
        int256 lastFundingRate;          // Last calculated funding rate (scaled by 1e18)
        uint256 lastUpdateTimestamp;     // Last update timestamp
        uint256 longSize;                // Total size of long positions
        uint256 shortSize;               // Total size of short positions
        int256[] recentRates;            // Recent funding rates for EMA calculation
    }
    
    // Config parameters
    uint256 public fundingInterval = 8 hours;
    uint256 public maxFundingRate = 0.0025e18;  // 0.25% max rate per interval
    int256 public interestRate = 0.0001e18;    // 0.01% interest rate per interval
    uint256 public fundingEMAPeriods = 8;      // EMA over 8 funding intervals
    
    // Dampening factor to reduce funding rate volatility
    uint256 public dampeningFactor = 75;       // 75% of new rate, 25% of old rate (scaled by 100)
    
    // Rate change limits to prevent sudden spikes
    uint256 public maxRateChangePercent = 30;  // Max 30% change in funding rate (scaled by 100)
    
    // Skew impact factor
    uint256 public skewImpactFactor = 100;     // Scale factor for market skew (100 = normal impact)
    
    // Clamp extreme funding rates over time
    bool public enableFundingRateClamping = true;
    uint256 public fundingRateClampThreshold = 5; // 5 consecutive periods of max rate
    mapping(bytes32 => uint256) private consecutiveMaxRatePeriods;
    
    // Funding states by asset
    mapping(bytes32 => FundingState) private fundingStates;

    // Helper function to convert string to bytes32
    function _toBytes32(string memory asset) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(asset));
    }
    
    // Timestamps of funding payments
    mapping(string => uint256[]) private fundingTimestamps;
    
    // User-specific funding payment tracking
    mapping(address => mapping(string => uint256)) public lastFundingPaymentPointer;
    
    // Global funding rate stats
    mapping(string => int256) public averageDailyFundingRate; // 24-hour average
    uint256 public historicalRateWindow = 30; // Keep 30 historical rates
    
    // Dependencies
    AssetRegistry public assetRegistry;
    Oracle public oracle;
    SecurityModule public securityModule;
    address public owner;
    
    // Events
    event FundingRateUpdated(string asset, int256 fundingRate, uint256 timestamp);
    event FundingParamsUpdated(uint256 interval, uint256 maxRate, int256 interestRate);
    event FundingEMAPeriodsUpdated(uint256 oldPeriods, uint256 newPeriods);
    event DampeningFactorUpdated(uint256 oldFactor, uint256 newFactor);
    event MaxRateChangePercentUpdated(uint256 oldPercent, uint256 newPercent);
    event SkewImpactFactorUpdated(uint256 oldFactor, uint256 newFactor);
    event FundingRateClampingUpdated(bool enabled, uint256 threshold);
    event MarketSizeChanged(string asset, uint256 longSize, uint256 shortSize);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    
    // Errors
    error Unauthorized();
    error InvalidParameter();
    error NotYetFundingTime();
    error SystemPaused();
    
    // Modifiers
    modifier onlyOwner() {
        if (msg.sender != owner) revert Unauthorized();
        _;
    }
    
    modifier onlyOperator() {
        if (!SecurityModule(securityModule).operators(msg.sender) && msg.sender != owner) 
            revert Unauthorized();
        _;
    }
    
    modifier whenNotPaused() {
        if (SecurityModule(securityModule).paused()) revert SystemPaused();
        _;
    }
    
    constructor (
        address _assetRegistry,
        address _oracle,
        address _securityModule
    ) {
        require(_assetRegistry != address(0), "Invalid asset registry");
        require(_oracle != address(0), "Invalid oracle");
        require(_securityModule != address(0), "Invalid security module");
        
        assetRegistry = AssetRegistry(_assetRegistry);
        oracle = Oracle(_oracle);
        securityModule = SecurityModule(_securityModule);
        owner = msg.sender;
    }
    
    /// @notice Transfer ownership to a new address
    /// @param newOwner Address of the new owner
    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert InvalidParameter();
        
        address oldOwner = owner;
        owner = newOwner;
        
        emit OwnershipTransferred(oldOwner, newOwner);
    }
    
    /// @notice Update funding parameters
    /// @param interval New funding interval
    /// @param maxRate New maximum funding rate
    /// @param interest New interest rate
    function updateFundingParams(
        uint256 interval,
        uint256 maxRate,
        int256 interest
    ) external onlyOwner {
        if (interval < 1 hours || interval > 24 hours) revert InvalidParameter();
        if (maxRate > 0.01e18) revert InvalidParameter(); // Max 1% per interval
        
        fundingInterval = interval;
        maxFundingRate = maxRate;
        interestRate = interest;
        
        emit FundingParamsUpdated(interval, maxRate, interest);
    }
    
    /// @notice Update EMA periods for funding rate calculation
    /// @param periods New number of periods for EMA
    function updateFundingEMAPeriods(uint256 periods) external onlyOwner {
        if (periods == 0) revert InvalidParameter();
        
        uint256 oldPeriods = fundingEMAPeriods;
        fundingEMAPeriods = periods;
        
        emit FundingEMAPeriodsUpdated(oldPeriods, periods);
    }
    
    /// @notice Update dampening factor for funding rate changes
    /// @param factor New dampening factor (scaled by 100)
    function updateDampeningFactor(uint256 factor) external onlyOwner {
        if (factor > 100) revert InvalidParameter();
        
        uint256 oldFactor = dampeningFactor;
        dampeningFactor = factor;
        
        emit DampeningFactorUpdated(oldFactor, factor);
    }
    
    /// @notice Update maximum rate change percentage
    /// @param percent New maximum rate change percentage (scaled by 100)
    function updateMaxRateChangePercent(uint256 percent) external onlyOwner {
        if (percent == 0) revert InvalidParameter();
        
        uint256 oldPercent = maxRateChangePercent;
        maxRateChangePercent = percent;
        
        emit MaxRateChangePercentUpdated(oldPercent, percent);
    }
    
    /// @notice Update skew impact factor
    /// @param factor New skew impact factor
    function updateSkewImpactFactor(uint256 factor) external onlyOwner {
        uint256 oldFactor = skewImpactFactor;
        skewImpactFactor = factor;
        
        emit SkewImpactFactorUpdated(oldFactor, factor);
    }
    
    /// @notice Update funding rate clamping settings
    /// @param enabled Whether to enable clamping
    /// @param threshold Number of consecutive periods at max rate before clamping
    function updateFundingRateClamping(bool enabled, uint256 threshold) external onlyOwner {
        enableFundingRateClamping = enabled;
        fundingRateClampThreshold = threshold;
        
        emit FundingRateClampingUpdated(enabled, threshold);
    }
    
    /// @notice Update market size for an asset
    /// @param asset Asset symbol
    /// @param longSize New long position size
    /// @param shortSize New short position size
    function updateMarketSize(
        string calldata asset,
        uint256 longSize,
        uint256 shortSize
    ) external onlyOperator {
        FundingState storage state = fundingStates[_toBytes32(asset)];
        state.longSize = longSize;
        state.shortSize = shortSize;
        
        emit MarketSizeChanged(asset, longSize, shortSize);
    }
    
    /// @notice Calculate premium index based on market imbalance
    /// @param asset Asset symbol
    /// @return Premium index (scaled by 1e18)
    function calculatePremiumIndex(string calldata asset) public view returns (int256) {
        bytes32 assetKey = _toBytes32(asset);
        FundingState storage state = fundingStates[assetKey];
        
        // No open interest, return zero
        if (state.longSize == 0 && state.shortSize == 0) {
            return 0;
        }
        
        // Calculate market skew
        uint256 totalSize = state.longSize + state.shortSize;
        int256 longRatio = int256((state.longSize * 1e18) / totalSize);
        int256 shortRatio = int256((state.shortSize * 1e18) / totalSize);
        
        // Calculate premium based on imbalance
        int256 skew = longRatio - shortRatio;
        
        // Apply skew impact factor
        skew = (skew * int256(skewImpactFactor)) / 100;
        
        return skew;
    }
    
    /// @notice Calculate and update funding rate for an asset
    /// @param asset Asset symbol
    /// @return Current funding rate (scaled by 1e18)
    function updateFundingRate(string calldata asset) external whenNotPaused returns (int256) {
        bytes32 assetKey = _toBytes32(asset);
        FundingState storage state = fundingStates[assetKey];
        
        // Check if it's time for an update
        if (block.timestamp < state.lastUpdateTimestamp + fundingInterval) {
            revert NotYetFundingTime();
        }
        
        // Calculate the premium index based on market imbalance
        int256 premiumIndex = calculatePremiumIndex(asset);
        
        // Add interest rate
        int256 rawFundingRate = premiumIndex + interestRate;
        
        // Apply dampening to reduce volatility (if not the first update)
        int256 fundingRate;
        if (state.lastUpdateTimestamp > 0) {
            int256 dampened = (rawFundingRate * int256(dampeningFactor) + 
                               state.lastFundingRate * int256(100 - dampeningFactor)) / 100;
            
            // Limit rate change if needed
            int256 maxChange = (state.lastFundingRate * int256(maxRateChangePercent)) / 100;
            if (maxChange < 0) maxChange = -maxChange; // Absolute value
            
            // Check if the rate change exceeds the max allowed
            int256 rateChange = dampened - state.lastFundingRate;
            if (rateChange < 0) rateChange = -rateChange; // Absolute value
            
            if (rateChange > maxChange) {
                // Limit the change direction
                if (dampened > state.lastFundingRate) {
                    fundingRate = state.lastFundingRate + maxChange;
                } else {
                    fundingRate = state.lastFundingRate - maxChange;
                }
            } else {
                fundingRate = dampened;
            }
        } else {
            // First update, use raw rate
            fundingRate = rawFundingRate;
        }
        
        // Cap the funding rate
        if (fundingRate > int256(maxFundingRate)) {
            fundingRate = int256(maxFundingRate);
            
            // Track consecutive max rate periods for clamping
            if (enableFundingRateClamping) {
                consecutiveMaxRatePeriods[assetKey]++;
            }
        } else if (fundingRate < -int256(maxFundingRate)) {
            fundingRate = -int256(maxFundingRate);
            
            // Track consecutive max rate periods for clamping
            if (enableFundingRateClamping) {
                consecutiveMaxRatePeriods[assetKey]++;
            }
        } else {
            // Reset consecutive counter
            consecutiveMaxRatePeriods[assetKey] = 0;
        }
        
        // Apply clamping if enabled and threshold reached
        if (enableFundingRateClamping && 
            consecutiveMaxRatePeriods[assetKey] >= fundingRateClampThreshold) {
            // Reduce the rate by half
            fundingRate = fundingRate / 2;
            
            // Reset counter
            consecutiveMaxRatePeriods[assetKey] = 0;
        }
        
        // Store the rate in history
        if (state.recentRates.length >= fundingEMAPeriods) {
            // Shift array to remove oldest
            for (uint256 i = 0; i < state.recentRates.length - 1; i++) {
                state.recentRates[i] = state.recentRates[i+1];
            }
            state.recentRates[state.recentRates.length - 1] = fundingRate;
        } else {
            state.recentRates.push(fundingRate);
        }
        
        // Update state
        state.lastFundingRate = fundingRate;
        state.cumulativeFundingRate += fundingRate;
        state.lastUpdateTimestamp = block.timestamp;
        
        // Store the timestamp for this funding event
        fundingTimestamps[asset].push(block.timestamp);
        
        // Update 24-hour average
        updateAverageDailyFundingRate(asset);
        
        emit FundingRateUpdated(asset, fundingRate, block.timestamp);
        
        return fundingRate;
    }
    
    /// @notice Update the 24-hour average funding rate
    /// @param asset Asset symbol
    function updateAverageDailyFundingRate(string memory asset) internal {
        bytes32 assetKey = _toBytes32(asset);
        FundingState storage state = fundingStates[assetKey];
        
        // Need at least one rate
        if (state.recentRates.length == 0) return;
        
        // Calculate 24-hour average
        int256 sum = 0;
        uint256 count = 0;
        
        // Get funding events in the last 24 hours
        for (uint256 i = 0; i < fundingTimestamps[asset].length; i++) {
            if (block.timestamp - fundingTimestamps[asset][i] <= 24 hours) {
                // Get corresponding rate
                if (i < state.recentRates.length) {
                    sum += state.recentRates[i];
                    count++;
                }
            }
        }
        
        // Update average
        if (count > 0) {
            averageDailyFundingRate[asset] = sum / int256(count);
        } else {
            // If no rates in last 24 hours, use last rate
            averageDailyFundingRate[asset] = state.lastFundingRate;
        }
    }
    
    /// @notice Get the pending funding payment for a trader
    /// @param trader Trader address
    /// @param asset Asset symbol
    /// @param positionSize Position size
    /// @param isLong Whether the position is long
    /// @return pendingPayment Pending funding payment (positive means trader receives, negative means trader pays)
    function getPendingFundingPayment(
        address trader,
        string calldata asset,
        uint256 positionSize,
        bool isLong
    ) external view returns (int256 pendingPayment) {
        FundingState storage state = fundingStates[_toBytes32(asset)];
        
        // Get the funding timestamps since the trader's last payment
        uint256 lastIndex = lastFundingPaymentPointer[trader][asset];
        uint256 currentIndex = fundingTimestamps[asset].length;
        
        // If no funding events or already up to date, return 0
        if (currentIndex == 0 || lastIndex == currentIndex) {
            return 0;
        }
        
        // Calculate funding payment based on cumulative rate changes
        pendingPayment = 0;
        
        // For each funding event since the last payment
        for (uint256 i = lastIndex; i < currentIndex; i++) {
            // Get the funding rate for this period
            int256 periodRate;
            if (i < state.recentRates.length) {
                periodRate = state.recentRates[i];
            } else {
                periodRate = state.lastFundingRate;
            }
            
            // Calculate payment direction
            // Long positions pay when rate is positive, receive when negative
            // Short positions receive when rate is positive, pay when negative
            int256 paymentDirection = isLong ? -periodRate : periodRate;
            
            // Calculate payment for this period
            int256 periodPayment = (paymentDirection * int256(positionSize)) / 1e18;
            pendingPayment += periodPayment;
        }
        
        return pendingPayment;
    }
    
    /// @notice Calculate an EMA of the funding rate
    /// @param asset Asset symbol
    /// @return EMA of the funding rate
    function calculateEMA(string calldata asset) public view returns (int256) {
        bytes32 assetKey = _toBytes32(asset);
        FundingState storage state = fundingStates[assetKey];
        
        if (state.recentRates.length == 0) return 0;
        if (state.recentRates.length == 1) return state.recentRates[0];
        
        int256 alpha = int256(2 * 1e18) / int256(int256(state.recentRates.length) + 1);
        int256 ema = state.recentRates[0];
        
        for (uint256 i = 1; i < state.recentRates.length; i++) {
            ema = state.recentRates[i] * alpha / 1e18 + ema * (int256(1e18) - alpha) / 1e18;
        }
        
        return ema;
    }
    
    /// @notice Update the trader's funding payment pointer
    /// @param trader Trader address
    /// @param asset Asset symbol
    function updateFundingPaymentPointer(address trader, string calldata asset) external onlyOperator {
        lastFundingPaymentPointer[trader][asset] = fundingTimestamps[asset].length;
    }
    
    /// @notice Get funding state for an asset
    /// @param asset Asset symbol
    /// @return cumulativeFundingRate Accumulated funding rate (scaled by 1e18)
    /// @return lastFundingRate Last calculated funding rate (scaled by 1e18)
    /// @return lastUpdateTimestamp Last update timestamp
    /// @return longSize Total size of long positions
    /// @return shortSize Total size of short positions
    /// @return averageRate 24-hour average funding rate
    function getFundingState(string calldata asset) external view returns (
        int256 cumulativeFundingRate,
        int256 lastFundingRate,
        uint256 lastUpdateTimestamp,
        uint256 longSize,
        uint256 shortSize,
        int256 averageRate
    ) {
        FundingState storage state = fundingStates[_toBytes32(asset)];
        
        return (
            state.cumulativeFundingRate,
            state.lastFundingRate,
            state.lastUpdateTimestamp,
            state.longSize,
            state.shortSize,
            averageDailyFundingRate[asset]
        );
    }
    
    /// @notice Get the latest funding rate for an asset
    /// @param asset Asset symbol
    /// @return Current funding rate (scaled by 1e18)
    function getCurrentFundingRate(string calldata asset) external view returns (int256) {
        return fundingStates[_toBytes32(asset)].lastFundingRate;
    }
    
    /// @notice Get the cumulative funding rate for an asset
    /// @param asset Asset symbol
    /// @return Cumulative funding rate (scaled by 1e18)
    function getCumulativeFundingRate(string calldata asset) external view returns (int256) {
        return fundingStates[_toBytes32(asset)].cumulativeFundingRate;
    }
    
    /// @notice Get the EMA of the funding rate
    /// @param asset Asset symbol
    /// @return EMA funding rate (scaled by 1e18)
    function getEMAFundingRate(string calldata asset) external view returns (int256) {
        return calculateEMA(asset);
    }
    
    /// @notice Get the time until next funding
    /// @param asset Asset symbol
    /// @return Time in seconds until next funding
    function getTimeUntilNextFunding(string calldata asset) external view returns (uint256) {
        bytes32 assetKey = _toBytes32(asset);
        FundingState storage state = fundingStates[assetKey];
        
        if (state.lastUpdateTimestamp == 0) {
            return 0; // No previous funding, can fund immediately
        }
        
        uint256 nextFundingTime = state.lastUpdateTimestamp + fundingInterval;
        
        if (block.timestamp >= nextFundingTime) {
            return 0; // Can fund now
        }
        
        return nextFundingTime - block.timestamp;
    }
    
    /// @notice Get recent rates for an asset
    /// @param asset Asset symbol
    /// @return Array of recent funding rates
    function getRecentRates(string calldata asset) external view returns (int256[] memory) {
        return fundingStates[_toBytes32(asset)].recentRates;
    }
    
    /// @notice Get funding rate history for an asset
    /// @param asset Asset symbol
    /// @param startIndex Start index of funding history
    /// @param endIndex End index of funding history
    /// @return timestamps Array of funding timestamps
    function getFundingHistory(
        string calldata asset,
        uint256 startIndex,
        uint256 endIndex
    ) external view returns (uint256[] memory timestamps) {
        if (startIndex >= endIndex) revert InvalidParameter();
        if (endIndex > fundingTimestamps[asset].length) revert InvalidParameter();
        
        timestamps = new uint256[](endIndex - startIndex);
        
        for (uint256 i = startIndex; i < endIndex; i++) {
            timestamps[i - startIndex] = fundingTimestamps[asset][i];
        }
        
        return timestamps;
    }
    
    /// @notice Get the 24-hour average funding rate for an asset
    /// @param asset Asset symbol
    /// @return Average daily funding rate
    function getAverageDailyRate(string calldata asset) external view returns (int256) {
        return averageDailyFundingRate[asset];
    }
    
    /// @notice Get the count of consecutive max rate periods
    /// @param asset Asset symbol
    /// @return Count of consecutive periods
    function getConsecutiveMaxRatePeriods(string calldata asset) external view returns (uint256) {
        return consecutiveMaxRatePeriods[_toBytes32(asset)];
    }
    
    /// @notice Get the number of funding events for an asset
    /// @param asset Asset symbol
    /// @return Count of funding events
    function getFundingEventCount(string calldata asset) external view returns (uint256) {
        return fundingTimestamps[asset].length;
    }
}