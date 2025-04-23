// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./Market.sol";
import "./CollateralManager.sol";
import "./FeeManager.sol";
import "./Oracle.sol";
import "./RiskManager.sol";
import "./InsuranceFund.sol";

/// @title Clearing House for Omniliquid
/// @notice Handles the settlement and clearing of trades across the platform
contract ClearingHouse {
    address public owner;
    
    Market public market;
    CollateralManager public collateralManager;
    FeeManager public feeManager;
    Oracle public oracle;
    RiskManager public riskManager;
    InsuranceFund public insuranceFund;
    
    // Tracking variables
    uint256 public totalVolumeEth;
    uint256 public dailyVolumeEth;
    uint256 public lastVolumeResetTime;
    
    // Trade tracking
    struct Trade {
        address trader;
        string asset;
        uint128 amount;
        uint128 price;
        bool isLong;
        bool isLiquidation;
        uint256 timestamp;
    }
    
    Trade[] public trades;
    
    // Events
    event TradeSettled(
        address indexed trader, 
        string asset, 
        uint128 amount, 
        uint128 price, 
        bool isLong,
        uint256 fee
    );
    event LiquidationSettled(
        address indexed trader,
        address indexed liquidator,
        string asset,
        uint128 amount,
        uint128 price
    );
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    
    modifier onlyOwner() {
        require(msg.sender == owner, "Not authorized");
        _;
    }
    
    constructor(
        address _market,
        address _collateralManager,
        address _feeManager,
        address _oracle,
        address _riskManager,
        address _insuranceFund
    ) {
        require(_market != address(0), "Invalid market address");
        require(_collateralManager != address(0), "Invalid collateral manager address");
        require(_feeManager != address(0), "Invalid fee manager address");
        require(_oracle != address(0), "Invalid oracle address");
        require(_riskManager != address(0), "Invalid risk manager address");
        require(_insuranceFund != address(0), "Invalid insurance fund address");
        
        market = Market(_market);
        collateralManager = CollateralManager(_collateralManager);
        feeManager = FeeManager(payable(_feeManager));
        oracle = Oracle(_oracle);
        riskManager = RiskManager(_riskManager);
        insuranceFund = InsuranceFund(payable(_insuranceFund));
        
        owner = msg.sender;
        lastVolumeResetTime = block.timestamp;
    }
    
    /// @notice Transfers ownership of the contract to a new account
    /// @param newOwner The address of the new owner
    function transferOwnership(address newOwner) public onlyOwner {
        require(newOwner != address(0), "New owner cannot be the zero address");
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }
    
    /// @notice Settles a trade and updates relevant statistics
    /// @param trader The trader's address
    /// @param asset The asset symbol
    /// @param amount The trade amount
    /// @param price The trade price
    /// @param isLong Whether the trade is long (true) or short (false)
    /// @return The trade ID
    function settleTrade(
        address trader,
        string calldata asset,
        uint128 amount,
        uint128 price,
        bool isLong
    ) external returns (uint256) {
        // Only market contract can call this
        require(msg.sender == address(market), "Only market can settle trades");
        
        // Check risk parameters
        require(riskManager.isTradeEnabledForAsset(asset), "Trading disabled for asset");
        
        // Calculate trade value in ETH
        uint256 tradeValueEth = (uint256(amount) * uint256(price)) / 1e8; // Assuming price has 8 decimals
        
        // Calculate and collect fees
        string memory feeType = "taker"; // Default to taker fee
        uint256 fee = feeManager.calculateFee(tradeValueEth, feeType);
        feeManager.collectFee(fee, feeType);
        
        // Reset daily volume if it's a new day
        if (block.timestamp >= lastVolumeResetTime + 1 days) {
            dailyVolumeEth = 0;
            lastVolumeResetTime = block.timestamp;
        }
        
        // Update volume statistics
        totalVolumeEth += tradeValueEth;
        dailyVolumeEth += tradeValueEth;
        
        // Record the trade
        trades.push(Trade({
            trader: trader,
            asset: asset,
            amount: amount,
            price: price,
            isLong: isLong,
            isLiquidation: false,
            timestamp: block.timestamp
        }));
        
        uint256 tradeId = trades.length - 1;
        
        emit TradeSettled(trader, asset, amount, price, isLong, fee);
        
        return tradeId;
    }
    
    /// @notice Settles a liquidation
    /// @param trader The trader being liquidated
    /// @param liquidator The liquidator's address
    /// @param asset The asset symbol
    /// @param amount The liquidation amount
    /// @param price The liquidation price
    /// @return The trade ID
    function settleLiquidation(
        address trader,
        address liquidator,
        string calldata asset,
        uint128 amount,
        uint128 price
    ) external returns (uint256) {
        // Only liquidation engine can call this
        require(
            msg.sender == address(market) || 
            msg.sender == owner, 
            "Not authorized to settle liquidations"
        );
        
        // Record the liquidation as a trade
        trades.push(Trade({
            trader: trader,
            asset: asset,
            amount: amount,
            price: price,
            isLong: false, // Not relevant for liquidation
            isLiquidation: true,
            timestamp: block.timestamp
        }));
        
        uint256 tradeId = trades.length - 1;
        
        // Update volume statistics (liquidations count towards volume)
        uint256 liquidationValueEth = (uint256(amount) * uint256(price)) / 1e8;
        totalVolumeEth += liquidationValueEth;
        dailyVolumeEth += liquidationValueEth;
        
        emit LiquidationSettled(trader, liquidator, asset, amount, price);
        
        return tradeId;
    }
    
    /// @notice Gets the total number of trades
    /// @return The number of trades
    function getTotalTrades() external view returns (uint256) {
        return trades.length;
    }
    
    /// @notice Gets trade details by ID
    /// @param tradeId The trade ID
    /// @return The trade details
    function getTradeById(uint256 tradeId) external view returns (Trade memory) {
        require(tradeId < trades.length, "Invalid trade ID");
        return trades[tradeId];
    }
    
    /// @notice Gets recent trades for a specific trader
    /// @param trader The trader's address
    /// @param count The number of recent trades to retrieve
    /// @return An array of trade IDs
    function getRecentTradesForTrader(address trader, uint256 count) external view returns (uint256[] memory) {
        uint256 resultCount = 0;
        
        // First, count matching trades
        for (uint256 i = trades.length; i > 0 && resultCount < count; i--) {
            if (trades[i-1].trader == trader) {
                resultCount++;
            }
        }
        
        // Create result array of appropriate size
        uint256[] memory result = new uint256[](resultCount);
        uint256 currentIndex = 0;
        
        // Fill result array
        for (uint256 i = trades.length; i > 0 && currentIndex < resultCount; i--) {
            if (trades[i-1].trader == trader) {
                result[currentIndex] = i-1;
                currentIndex++;
            }
        }
        
        return result;
    }
    
    /// @notice Gets the daily trade volume in ETH
    /// @return The daily volume
    function getDailyVolume() external view returns (uint256) {
        return dailyVolumeEth;
    }
    
    /// @notice Gets the total trade volume in ETH
    /// @return The total volume
    function getTotalVolume() external view returns (uint256) {
        return totalVolumeEth;
    }
}