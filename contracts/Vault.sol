// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./SecurityModule.sol";

/// @title Protocol Vault for Omniliquidity Provider (OLP)
/// @notice Secure storage of user collateral for market making and liquidations
contract Vault {
    // State variables
    address public owner;
    SecurityModule public securityModule;
    address public collateralManager;
    
    // Vault metrics
    uint256 public totalDeposits;
    uint256 public totalVaultValue;
    uint256 public olpPrice = 1 ether; // Initial price of 1 OLP = 1 ETH
    uint256 public olpSupply;
    uint256 public lastPriceUpdate;
    
    // Lock-up period - 4 days
    uint256 public constant LOCKUP_PERIOD = 4 days;
    
    // User data
    struct UserInfo {
        uint256 olpAmount;         // Amount of OLP tokens held
        uint256 lastDepositTime;   // Timestamp of last deposit
        uint256 initialDeposit;    // Initial deposit value for performance tracking
        uint256 depositValue;      // Current value of deposits (for performance tracking)
    }
    
    mapping(address => UserInfo) public userInfo;
    
    // Historical performance
    struct PerformanceSnapshot {
        uint256 timestamp;
        uint256 olpPrice;
        uint256 totalVaultValue;
        uint256 totalDeposits;
    }
    
    PerformanceSnapshot[] public performanceHistory;
    
    // Events
    event Deposited(address indexed user, uint256 ethAmount, uint256 olpAmount);
    event Withdrawn(address indexed user, uint256 olpAmount, uint256 ethAmount);
    event OLPPriceUpdated(uint256 oldPrice, uint256 newPrice);
    event VaultValueUpdated(uint256 oldValue, uint256 newValue);
    event PerformanceRecorded(uint256 timestamp, uint256 olpPrice, uint256 totalVaultValue);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event CollateralManagerUpdated(address indexed oldManager, address indexed newManager);
    
    // Errors
    error Unauthorized();
    error TransferFailed();
    error SystemPaused();
    error StillInLockupPeriod(uint256 unlockTime);
    error InvalidAmount();
    error InsufficientBalance();
    
    modifier onlyOwner() {
        if (msg.sender != owner) revert Unauthorized();
        _;
    }
    
    modifier onlyCollateralManager() {
        if (msg.sender != collateralManager) revert Unauthorized();
        _;
    }
    
    modifier whenNotPaused() {
        if (securityModule.paused()) revert SystemPaused();
        _;
    }
    
    constructor(address _securityModule) {
        require(_securityModule != address(0), "Invalid security module");
        securityModule = SecurityModule(_securityModule);
        owner = msg.sender;
        lastPriceUpdate = block.timestamp;
        
        // Initialize performance history
        performanceHistory.push(PerformanceSnapshot({
            timestamp: block.timestamp,
            olpPrice: olpPrice,
            totalVaultValue: 0,
            totalDeposits: 0
        }));
    }
    
    /// @notice Transfers ownership of the contract to a new account
    /// @param newOwner The address of the new owner
    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "New owner cannot be zero address");
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }
    
    /// @notice Sets the collateral manager address
    /// @param _collateralManager The new collateral manager address
    function setCollateralManager(address _collateralManager) external onlyOwner {
        require(_collateralManager != address(0), "Invalid collateral manager address");
        address oldManager = collateralManager;
        collateralManager = _collateralManager;
        emit CollateralManagerUpdated(oldManager, _collateralManager);
    }
    
    /// @notice Deposits ETH into the vault and mints OLP tokens
    /// @dev User receives OLP tokens based on current OLP price
    function deposit() external payable whenNotPaused {
        require(msg.value > 0, "Zero deposit amount");
        
        uint256 olpToMint = (msg.value * 1 ether) / olpPrice;
        UserInfo storage user = userInfo[msg.sender];
        
        // Update user info
        user.lastDepositTime = block.timestamp;
        
        // If this is user's first deposit, initialize performance tracking
        if (user.olpAmount == 0) {
            user.initialDeposit = msg.value;
            user.depositValue = msg.value;
        } else {
            // Add to existing deposit value
            user.depositValue += msg.value;
        }
        
        user.olpAmount += olpToMint;
        
        // Update global stats
        totalDeposits += msg.value;
        olpSupply += olpToMint;
        
        // Update total vault value (totalDeposits + PnL)
        updateVaultValue();
        
        emit Deposited(msg.sender, msg.value, olpToMint);
    }
    
    /// @notice Withdraws ETH from the vault by burning OLP tokens
    /// @param olpAmount The amount of OLP tokens to burn
    function withdraw(uint256 olpAmount) external whenNotPaused {
        UserInfo storage user = userInfo[msg.sender];
        
        if (olpAmount == 0 || olpAmount > user.olpAmount) revert InvalidAmount();
        
        // Check lock-up period
        if (block.timestamp < user.lastDepositTime + LOCKUP_PERIOD) {
            revert StillInLockupPeriod(user.lastDepositTime + LOCKUP_PERIOD);
        }
        
        // Calculate ETH amount based on current OLP price
        uint256 ethAmount = (olpAmount * olpPrice) / 1 ether;
        
        // Check contract balance
        if (address(this).balance < ethAmount) revert InsufficientBalance();
        
        // Update user info
        user.olpAmount -= olpAmount;
        
        // If full withdrawal, reset performance tracking
        if (user.olpAmount == 0) {
            // Calculate withdrawal as percentage of deposit
            uint256 withdrawRatio = (olpAmount * 1 ether) / (user.olpAmount + olpAmount);
            uint256 withdrawValue = (user.depositValue * withdrawRatio) / 1 ether;
            user.depositValue -= withdrawValue;
            
            // If all OLP is withdrawn, reset initial deposit
            if (user.olpAmount == 0) {
                user.initialDeposit = 0;
                user.depositValue = 0;
            }
        }
        
        // Update global stats
        olpSupply -= olpAmount;
        
        // Update vault value
        updateVaultValue();
        
        // Transfer ETH to user
        (bool success, ) = msg.sender.call{value: ethAmount}("");
        if (!success) revert TransferFailed();
        
        emit Withdrawn(msg.sender, olpAmount, ethAmount);
    }
    
    /// @notice Updates the total value of the vault
    /// @dev Called by collateral manager or automatically during deposits/withdrawals
    function updateVaultValue() public {
        // In production, this would calculate the actual value including open positions
        // For now, we'll use a simple implementation that just adds the contract balance
        uint256 oldValue = totalVaultValue;
        totalVaultValue = address(this).balance;
        
        // Update OLP price if supply exists
        if (olpSupply > 0) {
            uint256 oldPrice = olpPrice;
            olpPrice = (totalVaultValue * 1 ether) / olpSupply;
            emit OLPPriceUpdated(oldPrice, olpPrice);
        }
        
        emit VaultValueUpdated(oldValue, totalVaultValue);
        
        // Record performance snapshot (not every time, but periodically)
        if (block.timestamp >= lastPriceUpdate + 1 hours) {
            recordPerformance();
            lastPriceUpdate = block.timestamp;
        }
    }
    
    /// @notice Records a snapshot of vault performance metrics
    function recordPerformance() public {
        performanceHistory.push(PerformanceSnapshot({
            timestamp: block.timestamp,
            olpPrice: olpPrice,
            totalVaultValue: totalVaultValue,
            totalDeposits: totalDeposits
        }));
        
        emit PerformanceRecorded(block.timestamp, olpPrice, totalVaultValue);
    }
    
    /// @notice Allows collateral manager to withdraw funds for market making or liquidations
    /// @param amount The amount to withdraw
    /// @param recipient The recipient address
    function authorizedWithdrawal(uint256 amount, address recipient) external onlyCollateralManager {
        require(amount > 0, "Zero withdrawal amount");
        require(recipient != address(0), "Invalid recipient");
        require(amount <= address(this).balance, "Insufficient balance");
        
        // Transfer funds
        (bool success, ) = recipient.call{value: amount}("");
        if (!success) revert TransferFailed();
        
        // Update vault value after withdrawal
        updateVaultValue();
    }
    
    /// @notice Gets the balance of the vault
    /// @return The total ETH balance of the vault
    function getVaultBalance() external view returns (uint256) {
        return address(this).balance;
    }
    
    /// @notice Gets the current APY based on historical performance
    /// @return The estimated APY in basis points (1% = 100 bps)
    function getCurrentAPY() external view returns (uint256) {
        // Require at least two data points and 1 day of history
        if (performanceHistory.length < 2) return 0;
        
        PerformanceSnapshot memory latest = performanceHistory[performanceHistory.length - 1];
        PerformanceSnapshot memory oldest = performanceHistory[0];
        
        // Get time difference in days
        uint256 timeSpan = (latest.timestamp - oldest.timestamp) / 1 days;
        if (timeSpan < 1) return 0;
        
        // Calculate price change
        if (oldest.olpPrice == 0) return 0;
        
        uint256 priceChange = ((latest.olpPrice - oldest.olpPrice) * 10000) / oldest.olpPrice;
        
        // Annualize (365 / timeSpan) * priceChange
        uint256 annualizedReturn = (365 * priceChange) / timeSpan;
        
        return annualizedReturn;
    }
    
    /// @notice Gets user's performance metrics
    /// @param user The user address
    /// @return olpAmount The amount of OLP tokens held
    /// @return ethValue The current value in ETH
    /// @return performancePct The performance percentage (gain/loss)
    /// @return unlockTime The time when user can withdraw
    function getUserPerformance(address user) external view returns (
        uint256 olpAmount,
        uint256 ethValue,
        int256 performancePct,
        uint256 unlockTime
    ) {
        UserInfo memory myUserInfo = userInfo[user];
        olpAmount = myUserInfo.olpAmount;
        ethValue = (olpAmount * olpPrice) / 1 ether;
        
        // Calculate performance percentage
        if (myUserInfo.initialDeposit > 0) {
            uint256 currentValue = (myUserInfo.olpAmount * olpPrice) / 1 ether;
            if (currentValue > myUserInfo.initialDeposit) {
                performancePct = int256(((currentValue - myUserInfo.initialDeposit) * 10000) /myUserInfo.initialDeposit);
            } else {
                performancePct = -int256(((myUserInfo.initialDeposit - currentValue) * 10000) / myUserInfo.initialDeposit);
            }
        }
        
        // Calculate unlock time
        unlockTime = myUserInfo.lastDepositTime + LOCKUP_PERIOD;
        
        return (olpAmount, ethValue, performancePct, unlockTime);
    }
    
    /// @notice Gets historical performance snapshots (paginated)
    /// @param start The starting index
    /// @param limit The number of entries to return
    function getPerformanceHistory(uint256 start, uint256 limit) external view returns (
        uint256[] memory timestamps,
        uint256[] memory prices,
        uint256[] memory values
    ) {
        uint256 totalEntries = performanceHistory.length;
        if (start >= totalEntries) {
            return (new uint256[](0), new uint256[](0), new uint256[](0));
        }
        
        uint256 end = start + limit;
        if (end > totalEntries) {
            end = totalEntries;
        }
        
        uint256 resultSize = end - start;
        timestamps = new uint256[](resultSize);
        prices = new uint256[](resultSize);
        values = new uint256[](resultSize);
        
        for (uint256 i = 0; i < resultSize; i++) {
            PerformanceSnapshot memory snapshot = performanceHistory[start + i];
            timestamps[i] = snapshot.timestamp;
            prices[i] = snapshot.olpPrice;
            values[i] = snapshot.totalVaultValue;
        }
        
        return (timestamps, prices, values);
    }
    
    // Enable contract to receive ETH
    receive() external payable {
        // Update vault value when receiving ETH
        updateVaultValue();
    }
}