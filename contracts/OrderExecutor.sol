// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./Market.sol";
import "./PositionManager.sol";
import "./Oracle.sol";
import "./SecurityModule.sol";
import "./AssetRegistry.sol";

/// @title Order Executor for Omniliquid
/// @notice Handles execution of stop loss and take profit orders
contract OrderExecutor {
    Market public market;
    PositionManager public positionManager;
    Oracle public oracle;
    address public owner;
    SecurityModule public securityModule;
    AssetRegistry public assetRegistry;

    
    // Keeper registry
    mapping(address => bool) public authorizedKeepers;
    uint256 public keeperReward = 0.001 ether; // Reward for successful execution
    
    // Order execution tracking
    struct ExecutionRecord {
        uint256 positionId;
        uint256 orderId;
        uint128 triggerPrice;
        uint128 executionPrice;
        address executor;
        uint256 timestamp;
        bool success;
    }
    
    ExecutionRecord[] public executionHistory;
    
    // Events
    event KeeperAdded(address indexed keeper);
    event KeeperRemoved(address indexed keeper);
    event KeeperRewardUpdated(uint256 oldReward, uint256 newReward);
    event OrderExecuted(
        uint256 indexed positionId, 
        uint256 indexed orderId, 
        address indexed executor, 
        uint128 executionPrice,
        bool success
    );
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    
    // Errors
    error Unauthorized();
    error TransferFailed();
    error InvalidPositionId();
    error NoTriggerableOrders();
    
    modifier onlyOwner() {
        if (msg.sender != owner) revert Unauthorized();
        _;
    }
    
    modifier onlyKeeper() {
        if (!authorizedKeepers[msg.sender] && msg.sender != owner) revert Unauthorized();
        _;
    }
    
    modifier whenNotPaused() {
        require(!securityModule.paused(), "System is paused");
        _;
    }
    
    constructor(
        address _market,
        address _securityModule,
        address _assetRegistry,
        address _oracle,
        address _positionManager
    ) {
        require(_market != address(0), "Invalid market address");
        require(_positionManager != address(0), "Invalid position manager address");
        require(_oracle != address(0), "Invalid oracle address");
        require(_securityModule != address(0), "Invalid security module address");
        
        positionManager = PositionManager(_positionManager);
        owner = msg.sender;
        owner = msg.sender;
        assetRegistry = AssetRegistry(_assetRegistry);
        oracle = Oracle(_oracle);
        securityModule = SecurityModule(_securityModule);
        owner = msg.sender;
        
        // Add owner as a keeper
        authorizedKeepers[owner] = true;
    }
    
    /// @notice Transfers ownership of the contract to a new account
    /// @param newOwner The address of the new owner
    function transferOwnership(address newOwner) public onlyOwner {
        require(newOwner != address(0), "New owner cannot be zero address");
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }
    
    /// @notice Adds a new keeper
    /// @param keeper The address of the keeper to add
    function addKeeper(address keeper) external onlyOwner {
        require(keeper != address(0), "Invalid keeper address");
        authorizedKeepers[keeper] = true;
        emit KeeperAdded(keeper);
    }
    
    /// @notice Removes a keeper
    /// @param keeper The address of the keeper to remove
    function removeKeeper(address keeper) external onlyOwner {
        authorizedKeepers[keeper] = false;
        emit KeeperRemoved(keeper);
    }
    
    /// @notice Updates the keeper reward
    /// @param newReward The new reward amount
    function updateKeeperReward(uint256 newReward) external onlyOwner {
        uint256 oldReward = keeperReward;
        keeperReward = newReward;
        emit KeeperRewardUpdated(oldReward, newReward);
    }
    
    /// @notice Executes a triggerable order
    /// @param positionId The ID of the position
    /// @return success Whether the execution was successful
    function executeOrder(uint256 positionId) external onlyKeeper whenNotPaused returns (bool) {
        // Get the current price from oracle
        // First, get position details from market
   (
            address trader,
            string memory asset,
            uint128 amount,
            uint128 entryPrice,
            bool isLong,
            bool isOpen
        ) = market.getPositionDetails(positionId);

        // Ensure isOpen is already correctly assigned from market.getPositionDetails
        
        if (!isOpen) revert InvalidPositionId();
        
        // Get current price from oracle
        AssetRegistry.Asset memory assetDetails;
        try assetRegistry.getAsset(asset) returns (AssetRegistry.Asset memory details) {
            assetDetails = details;
        } catch {
            revert InvalidPositionId();
        }
        
        (uint128 currentPrice, ) = oracle.getPrice(assetDetails.feedKey);
        
        // Check and execute orders
        bool success = positionManager.checkAndExecuteOrders(positionId, currentPrice);
        if (!success) revert NoTriggerableOrders();
        
        // Record execution
        executionHistory.push(ExecutionRecord({
            positionId: positionId,
            orderId: 0, // We don't know which specific order was triggered
            triggerPrice: 0, // We don't know the trigger price
            executionPrice: currentPrice,
            executor: msg.sender,
            timestamp: block.timestamp,
            success: success
        }));
        
        // Pay keeper reward
        if (success && msg.sender != owner) {
            (bool transferSuccess, ) = msg.sender.call{value: keeperReward}("");
            if (!transferSuccess) revert TransferFailed();
        }
        
        emit OrderExecuted(positionId, 0, msg.sender, currentPrice, success);
        
        return success;
    }
    
    /// @notice Gets positions with triggerable orders
    /// @param asset The asset symbol
    /// @param startId The position ID to start from
    /// @param limit The maximum number of positions to check
    /// @return positionIds Array of position IDs with triggerable orders
    function getPositionsWithTriggerableOrders(
        string calldata asset,
        uint256 startId,
        uint256 limit
    ) external view returns (uint256[] memory) {
        uint256 positionCount = market.getTotalPositions();
        uint256[] memory results = new uint256[](limit);
        uint256 resultCount = 0;
        
        // Get current price from oracle
        AssetRegistry.Asset memory assetDetails;
        try assetRegistry.getAsset(asset) returns (AssetRegistry.Asset memory details) {
            assetDetails = details;
        } catch {
            return new uint256[](0);
        }
        
        (uint128 currentPrice, ) = oracle.getPrice(assetDetails.feedKey);
        
        for (uint256 i = startId; i < positionCount && resultCount < limit; i++) {
            try this.isOrderTriggerable(i, currentPrice) returns (bool triggerable) {
                if (triggerable) {
                    results[resultCount] = i;
                    resultCount++;
                }
            } catch {
                // Skip this position if any error occurs
                continue;
            }
        }
        
        // Create correctly sized array for results
        uint256[] memory triggerablePositions = new uint256[](resultCount);
        for (uint256 i = 0; i < resultCount; i++) {
            triggerablePositions[i] = results[i];
        }
        
        return triggerablePositions;
    }
    
    /// @notice Checks if a position has a triggerable order
    /// @param positionId The ID of the position
    /// @param currentPrice The current price of the asset
    /// @return Whether the position has a triggerable order
    function isOrderTriggerable(uint256 positionId, uint128 currentPrice) external view returns (bool) {
        // Get position details from market
        (
            address trader,
            string memory asset,
            uint128 amount,
            uint128 entryPrice,
            bool isLong,
            bool isOpen
        ) = market.getPositionDetails(positionId);
        
        if (!isOpen) return false;
        
        // Get order details
        (
            uint256[] memory orderIds,
            uint128[] memory triggerPrices,
            bool[] memory isStopLoss
        ) = positionManager.getActiveOrders(positionId);
        
        for (uint256 i = 0; i < orderIds.length; i++) {
            bool shouldTrigger = false;
            
            if (isStopLoss[i]) {
                // Stop loss logic
                if (isLong) {
                    // Long position: trigger if price falls below stop loss
                    shouldTrigger = currentPrice <= triggerPrices[i];
                } else {
                    // Short position: trigger if price rises above stop loss
                    shouldTrigger = currentPrice >= triggerPrices[i];
                }
            } else {
                // Take profit logic
                if (isLong) {
                    // Long position: trigger if price rises above take profit
                    shouldTrigger = currentPrice >= triggerPrices[i];
                } else {
                    // Short position: trigger if price falls below take profit
                    shouldTrigger = currentPrice <= triggerPrices[i];
                }
            }
            
            if (shouldTrigger) {
                return true;
            }
        }
        
        return false;
    }
    
    /// @notice Gets the execution history count
    /// @return The number of execution records
    function getExecutionHistoryCount() external view returns (uint256) {
        return executionHistory.length;
    }
    
    /// @notice Gets execution history for a specific position
    /// @param positionId The ID of the position
    /// @param limit The maximum number of records to return
    /// @return timestamps Array of execution timestamps
    /// @return executionPrices Array of execution prices
    /// @return executors Array of executor addresses
    /// @return successes Array of execution success flags
    function getExecutionHistoryForPosition(
        uint256 positionId,
        uint256 limit
    ) external view returns (
        uint256[] memory timestamps,
        uint128[] memory executionPrices,
        address[] memory executors,
        bool[] memory successes
    ) {
        // Count matching records for this position
        uint256 count = 0;
        for (uint256 i = 0; i < executionHistory.length && count < limit; i++) {
            if (executionHistory[i].positionId == positionId) {
                count++;
            }
        }
        
        // Initialize arrays
        timestamps = new uint256[](count);
        executionPrices = new uint128[](count);
        executors = new address[](count);
        successes = new bool[](count);
        
        // Fill arrays
        uint256 index = 0;
        for (uint256 i = 0; i < executionHistory.length && index < count; i++) {
            if (executionHistory[i].positionId == positionId) {
                timestamps[index] = executionHistory[i].timestamp;
                executionPrices[index] = executionHistory[i].executionPrice;
                executors[index] = executionHistory[i].executor;
                successes[index] = executionHistory[i].success;
                index++;
            }
        }
        
        return (timestamps, executionPrices, executors, successes);
    }
    
    /// @notice Withdraws ETH from the contract
    /// @param amount The amount to withdraw
    function withdraw(uint256 amount) external onlyOwner {
        require(amount <= address(this).balance, "Insufficient balance");
        
        (bool success, ) = owner.call{value: amount}("");
        if (!success) revert TransferFailed();
    }
    
    // Enable contract to receive ETH
    receive() external payable {}
}