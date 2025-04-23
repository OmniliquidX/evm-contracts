// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./SecurityModule.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title Interface for Supra Oracle Pull
 * @notice Defines the interface to interact with Supra's Oracle Pull functionality
 */
interface ISupraOraclePull {
    //Verified price data
    struct PriceData {
        // List of pairs
        uint256[] pairs;
        // List of prices
        // prices[i] is the price of pairs[i]
        uint256[] prices;
        // List of decimals
        // decimals[i] is the decimals of pairs[i]
        uint256[] decimals;
    }

    function verifyOracleProof(bytes calldata _bytesproof) external returns (PriceData memory);
}

/// @title Oracle Integration for Omniliquid
/// @notice Interfaces with Supra oracle and provides TWAP functionality
contract Oracle is ReentrancyGuard {
    // State variables
    address public owner;
    address public supraOracleAddress;
    SecurityModule public securityModule;
    
    // Pair mapping (asset symbol => Supra pair id)
    mapping(string => uint256) public pairMapping;
    
    // TWAP implementation
    struct PricePoint {
        uint128 price;
        uint128 timestamp;
    }
    
    mapping(string => PricePoint[]) public priceHistory;
    uint256 public twapInterval = 1 hours;
    uint256 public maxPricePoints = 12; // Keep 12 price points (5 min intervals for 1 hour TWAP)
    
    // Price deviation and freshness checks
    uint256 public maxPriceDeviation = 500; // 5% maximum allowed deviation (scaled by 100)
    uint256 public maxPriceAge = 3600; // 1 hour staleness limit
    
    // Latest price data by asset
    mapping(string => PricePoint) public latestPrices;
    
    // Events
    event OracleAddressUpdated(address indexed newOracleAddress);
    event PairMappingSet(string indexed assetKey, uint256 pairId);
    event PriceRecorded(string indexed key, uint128 price, uint128 timestamp);
    event TWAPIntervalUpdated(uint256 oldInterval, uint256 newInterval);
    event MaxPricePointsUpdated(uint256 oldMax, uint256 newMax);
    event MaxPriceDeviationUpdated(uint256 oldDeviation, uint256 newDeviation);
    event MaxPriceAgeUpdated(uint256 oldAge, uint256 newAge);
    event PriceUpdated(string indexed asset, uint128 price, uint128 timestamp);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    
    // Errors
    error Unauthorized();
    error InvalidOracleAddress();
    error PairNotMapped();
    error PriceDeviationTooLarge();
    error StalePriceData();
    error InvalidParameter();
    error PairIdNotFound();
    error InvalidPriceData();

    // Modifiers
    modifier onlyOwner() {
        if (msg.sender != owner) revert Unauthorized();
        _;
    }
    
    modifier onlyOperator() {
        if (!securityModule.operators(msg.sender) && msg.sender != owner) revert Unauthorized();
        _;
    }

    constructor(address _supraOracleAddress, address _securityModule) {
        if (_supraOracleAddress == address(0)) revert InvalidOracleAddress();
        if (_securityModule == address(0)) revert InvalidParameter();
        
        supraOracleAddress = _supraOracleAddress;
        securityModule = SecurityModule(_securityModule);
        owner = msg.sender;
    }

    /// @notice Transfers ownership of the contract to a new account
    /// @param newOwner The address of the new owner
    function transferOwnership(address newOwner) public onlyOwner {
        if (newOwner == address(0)) revert InvalidParameter();
        
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }

    /// @notice Updates the Supra oracle address
    /// @param _newOracleAddress New Supra oracle address
    function setOracleAddress(address _newOracleAddress) external onlyOwner {
        if (_newOracleAddress == address(0)) revert InvalidOracleAddress();
        
        supraOracleAddress = _newOracleAddress;
        emit OracleAddressUpdated(_newOracleAddress);
    }
    
    /// @notice Sets the mapping between asset keys and Supra pair IDs
    /// @param key The asset key (e.g., "BTC/USD")
    /// @param pairId The Supra oracle pair ID
    function setPairMapping(string calldata key, uint256 pairId) external onlyOwner {
        pairMapping[key] = pairId;
        emit PairMappingSet(key, pairId);
    }
    
    /// @notice Batch set multiple pair mappings
    /// @param keys Array of asset keys
    /// @param pairIds Array of corresponding Supra pair IDs
    function batchSetPairMapping(string[] calldata keys, uint256[] calldata pairIds) external onlyOwner {
        require(keys.length == pairIds.length, "Arrays length mismatch");
        
        for (uint256 i = 0; i < keys.length; i++) {
            pairMapping[keys[i]] = pairIds[i];
            emit PairMappingSet(keys[i], pairIds[i]);
        }
    }
    
    /// @notice Updates TWAP interval
    /// @param _twapInterval New TWAP interval in seconds
    function setTWAPInterval(uint256 _twapInterval) external onlyOwner {
        uint256 oldInterval = twapInterval;
        twapInterval = _twapInterval;
        
        emit TWAPIntervalUpdated(oldInterval, _twapInterval);
    }
    
    /// @notice Updates maximum price points for TWAP
    /// @param _maxPricePoints New maximum price points
    function setMaxPricePoints(uint256 _maxPricePoints) external onlyOwner {
        if (_maxPricePoints == 0) revert InvalidParameter();
        
        uint256 oldMax = maxPricePoints;
        maxPricePoints = _maxPricePoints;
        
        emit MaxPricePointsUpdated(oldMax, _maxPricePoints);
    }
    
    /// @notice Updates maximum allowed price deviation
    /// @param _maxDeviation New maximum price deviation (scaled by 100)
    function setMaxPriceDeviation(uint256 _maxDeviation) external onlyOwner {
        uint256 oldDeviation = maxPriceDeviation;
        maxPriceDeviation = _maxDeviation;
        
        emit MaxPriceDeviationUpdated(oldDeviation, _maxDeviation);
    }
    
    /// @notice Updates maximum allowed price age
    /// @param _maxAge New maximum price age in seconds
    function setMaxPriceAge(uint256 _maxAge) external onlyOwner {
        if (_maxAge == 0) revert InvalidParameter();
        
        uint256 oldAge = maxPriceAge;
        maxPriceAge = _maxAge;
        
        emit MaxPriceAgeUpdated(oldAge, _maxAge);
    }

    /// @notice Fetches the price and timestamp for a given asset key.
    /// @param key The price feed key (e.g., "BTC/USD").
    /// @return price The latest price (8 decimals).
    /// @return timestamp The Unix timestamp of last price update.
    function getPrice(string calldata key) 
        external 
        view 
        returns (uint128 price, uint128 timestamp) 
    {
        uint256 pairId = pairMapping[key];
        if (pairId == 0) revert PairNotMapped();
        
        // Get latest price from storage
        PricePoint memory latestPrice = latestPrices[key];
        
        // Check freshness
        if (block.timestamp - latestPrice.timestamp > maxPriceAge) revert StalePriceData();
        
        // If TWAP is enabled and we have price history, return TWAP
        if (twapInterval > 0 && priceHistory[key].length > 0) {
            price = calculateTWAP(key, latestPrice.price, latestPrice.timestamp);
        } else {
            price = latestPrice.price;
        }
        
        return (price, latestPrice.timestamp);
    }
    
    /// @notice Updates price from Supra oracle proof
    /// @param _bytesProof The proof data from Supra oracle
    function updatePrices(bytes calldata _bytesProof) external onlyOperator nonReentrant {
        ISupraOraclePull.PriceData memory pricesData = ISupraOraclePull(supraOracleAddress).verifyOracleProof(_bytesProof);
        
        if (pricesData.pairs.length == 0) revert InvalidPriceData();
        
        // Process all price updates
        for (uint256 i = 0; i < pricesData.pairs.length; i++) {
            uint256 pairId = pricesData.pairs[i];
            uint256 rawPrice = pricesData.prices[i];
            uint256 decimals = pricesData.decimals[i];
            
            // Find asset key for this pair ID
            string memory assetKey = getAssetKeyByPairId(pairId);
            if (bytes(assetKey).length == 0) continue; // Skip unknown pair IDs
            
            // Normalize price to 8 decimals for protocol standardization
            uint128 normalizedPrice = uint128(normalizePrice(rawPrice, decimals, 8));
            uint128 currentTimestamp = uint128(block.timestamp);
            
            // Check for price deviation if we have a previous price
            if (latestPrices[assetKey].timestamp > 0) {
                uint128 previousPrice = latestPrices[assetKey].price;
                checkPriceDeviation(previousPrice, normalizedPrice);
            }
            
            // Update latest price
            latestPrices[assetKey] = PricePoint({
                price: normalizedPrice,
                timestamp: currentTimestamp
            });
            
            // Push to history for TWAP
            recordPriceToHistory(assetKey, normalizedPrice, currentTimestamp);
            
            emit PriceUpdated(assetKey, normalizedPrice, currentTimestamp);
        }
    }
    
    /// @notice Get asset key by Supra pair ID
    /// @param pairId The Supra pair ID
    /// @return The asset key associated with the pair ID
    function getAssetKeyByPairId(uint256 pairId) public view returns (string memory) {
        // This is an O(n) operation but is acceptable since the number of assets is limited
        // In a production environment, consider maintaining a reverse mapping
        for (uint i = 0; i < getMappedAssetsCount(); i++) {
            string memory asset = getMappedAssetAtIndex(i);
            if (pairMapping[asset] == pairId) {
                return asset;
            }
        }
        return ""; // Return empty string if not found
    }
    
    /// @notice Gets the count of mapped assets
    /// @return The number of mapped assets
    function getMappedAssetsCount() public view returns (uint256) {
        // This is a mock implementation since we don't store mapped assets in an array
        // In production, you would maintain this list properly
        return 5; // Assuming 5 assets for example
    }
    
    /// @notice Gets the mapped asset at a specific index
    /// @param index The index of the asset
    /// @return The asset key at the given index
    function getMappedAssetAtIndex(uint256 index) public view returns (string memory) {
        // This is a mock implementation
        // In production, you would maintain this list properly
        if (index == 0) return "BTC/USD";
        if (index == 1) return "ETH/USD";
        if (index == 2) return "SOL/USD";
        if (index == 3) return "AAPL/USD";
        if (index == 4) return "TSLA/USD";
        return "";
    }
    
    /// @notice Checks if prices deviate too much
    /// @param oldPrice Previous price
    /// @param newPrice New price
    function checkPriceDeviation(uint128 oldPrice, uint128 newPrice) internal view {
        // Calculate deviation as percentage (scaled by 100)
        uint256 deviation;
        
        if (newPrice > oldPrice) {
            deviation = ((uint256(newPrice) - uint256(oldPrice)) * 10000) / uint256(oldPrice);
        } else {
            deviation = ((uint256(oldPrice) - uint256(newPrice)) * 10000) / uint256(oldPrice);
        }
        
        // Check against maximum allowed deviation
        if (deviation > maxPriceDeviation) revert PriceDeviationTooLarge();
    }
    
    /// @notice Records a price point to history for TWAP calculation
    /// @param key The asset key
    /// @param price The price to record
    /// @param timestamp The timestamp of the price
    function recordPriceToHistory(string memory key, uint128 price, uint128 timestamp) internal {
        // Push to history (only if enough time has passed since last record)
        if (priceHistory[key].length == 0 || 
            timestamp - priceHistory[key][priceHistory[key].length - 1].timestamp >= 5 minutes) {
            
            // Maintain fixed size array
            if (priceHistory[key].length >= maxPricePoints) {
                // Shift array to remove oldest
                for (uint256 i = 0; i < priceHistory[key].length - 1; i++) {
                    priceHistory[key][i] = priceHistory[key][i+1];
                }
                priceHistory[key][priceHistory[key].length - 1] = PricePoint(price, timestamp);
            } else {
                priceHistory[key].push(PricePoint(price, timestamp));
            }
            
            emit PriceRecorded(key, price, timestamp);
        }
    }
    
    /// @notice Normalizes a price to the desired number of decimals
    /// @param price The raw price
    /// @param sourceDecimals The decimals in the source
    /// @param targetDecimals The desired decimals
    /// @return The normalized price
    function normalizePrice(
        uint256 price, 
        uint256 sourceDecimals, 
        uint256 targetDecimals
    ) internal pure returns (uint256) {
        if (sourceDecimals == targetDecimals) {
            return price;
        } else if (sourceDecimals > targetDecimals) {
            return price / (10 ** (sourceDecimals - targetDecimals));
        } else {
            return price * (10 ** (targetDecimals - sourceDecimals));
        }
    }
    
    /// @notice Calculates Time-Weighted Average Price
    /// @param key The asset key
    /// @param currentPrice The current price
    /// @param currentTimestamp The current timestamp
    /// @return TWAP price
    function calculateTWAP(
        string memory key, 
        uint128 currentPrice, 
        uint128 currentTimestamp
    ) internal view returns (uint128) {
        if (priceHistory[key].length == 0) return currentPrice;
        
        uint256 totalWeight = 0;
        uint256 weightedSum = 0;
        
        for (uint256 i = 0; i < priceHistory[key].length; i++) {
            PricePoint memory point = priceHistory[key][i];
            
            // Skip points outside TWAP interval
            if (currentTimestamp - point.timestamp > twapInterval) continue;
            
            // Calculate weight (more recent points have higher weight)
            uint256 timeDiff = currentTimestamp - point.timestamp;
            uint256 weight = twapInterval - timeDiff;
            
            totalWeight += weight;
            weightedSum += uint256(point.price) * weight;
        }
        
        // Add current price to calculation
        weightedSum += uint256(currentPrice) * twapInterval;
        totalWeight += twapInterval;
        
        // Calculate final TWAP
        uint128 twapPrice = totalWeight > 0 ? 
            uint128(weightedSum / totalWeight) : currentPrice;
        
        return twapPrice;
    }
    
    /// @notice Gets the price history for a key
    /// @param key The price feed key
    /// @return prices Array of prices
    /// @return timestamps Array of timestamps
    function getPriceHistory(string calldata key) 
        external 
        view 
        returns (uint128[] memory prices, uint128[] memory timestamps) 
    {
        PricePoint[] storage history = priceHistory[key];
        
        prices = new uint128[](history.length);
        timestamps = new uint128[](history.length);
        
        for (uint256 i = 0; i < history.length; i++) {
            prices[i] = history[i].price;
            timestamps[i] = history[i].timestamp;
        }
        
        return (prices, timestamps);
    }
    
    /// @notice Gets the latest raw price directly (bypassing TWAP)
    /// @param key The price feed key
    /// @return price The latest price
    /// @return timestamp The timestamp of the price
    function getLatestPrice(string calldata key)
        external
        view
        returns (uint128 price, uint128 timestamp)
    {
        PricePoint memory latestPrice = latestPrices[key];
        
        // Check freshness
        if (block.timestamp - latestPrice.timestamp > maxPriceAge) revert StalePriceData();
        
        return (latestPrice.price, latestPrice.timestamp);
    }
}