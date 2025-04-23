// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./SecurityModule.sol";

/// @title Insurance Fund for Omniliquid
/// @notice Manages the insurance fund that covers losses from liquidations
contract InsuranceFund {
    address public owner;
    uint256 public totalFunds;
    uint256 public usedFunds;
    SecurityModule public securityModule;
    
    // Statistics tracking
    uint256 public totalLiquidationContributions;
    uint256 public totalFeeContributions;
    uint256 public totalDirectContributions;
    uint256 public totalUsedForLiquidations;
    uint256 public totalUsedForEmergencies;
    
    // Access control
    mapping(address => bool) public authorizedUsers;
    
    event FundsAdded(address indexed contributor, uint256 amount, string source);
    event FundsUsed(uint256 amount, string reason);
    event FundsWithdrawn(address indexed receiver, uint256 amount);
    event AuthorizedUserAdded(address indexed user);
    event AuthorizedUserRemoved(address indexed user);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    
    // Errors
    error Unauthorized();
    error InvalidAddress();
    error InsufficientFunds();
    error TransferFailed();
    
    // Modifiers
    modifier onlyOwner() {
        if (msg.sender != owner) revert Unauthorized();
        _;
    }
    
    modifier onlyAuthorized() {
        if (!authorizedUsers[msg.sender] && msg.sender != owner) revert Unauthorized();
        _;
    }
    
    modifier whenNotPaused() {
        if (securityModule.paused()) revert("System paused");
        _;
    }
    
    constructor(address _securityModule) {
        if (_securityModule == address(0)) revert InvalidAddress();
        
        owner = msg.sender;
        securityModule = SecurityModule(_securityModule);
        authorizedUsers[msg.sender] = true;
    }
    
    /// @notice Transfers ownership of the contract to a new account
    /// @param newOwner The address of the new owner
    function transferOwnership(address newOwner) public onlyOwner {
        if (newOwner == address(0)) revert InvalidAddress();
        
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }
    
    /// @notice Adds an authorized user
    /// @param user Address to authorize
    function addAuthorizedUser(address user) external onlyOwner {
        if (user == address(0)) revert InvalidAddress();
        
        authorizedUsers[user] = true;
        emit AuthorizedUserAdded(user);
    }
    
    /// @notice Removes an authorized user
    /// @param user Address to remove authorization from
    function removeAuthorizedUser(address user) external onlyOwner {
        authorizedUsers[user] = false;
        emit AuthorizedUserRemoved(user);
    }
    
    /// @notice Adds funds to the insurance fund
    function addFunds() external payable {
        if (msg.value == 0) revert("Amount must be greater than zero");
        
        totalFunds += msg.value;
        totalDirectContributions += msg.value;
        
        emit FundsAdded(msg.sender, msg.value, "direct");
    }
    
    /// @notice Adds funds from a liquidation
    function addFundsFromLiquidation() external payable onlyAuthorized {
        if (msg.value == 0) revert("Amount must be greater than zero");
        
        totalFunds += msg.value;
        totalLiquidationContributions += msg.value;
        
        emit FundsAdded(msg.sender, msg.value, "liquidation");
    }
    
    /// @notice Adds funds from collected fees
    function addFundsFromFees() external payable onlyAuthorized {
        if (msg.value == 0) revert("Amount must be greater than zero");
        
        totalFunds += msg.value;
        totalFeeContributions += msg.value;
        
        emit FundsAdded(msg.sender, msg.value, "fees");
    }
    
    /// @notice Uses funds to cover losses from liquidations
    /// @param amount The amount of funds to use
    /// @param reason The reason for using the funds
    function useFunds(uint256 amount, string calldata reason) external onlyAuthorized whenNotPaused {
        if (availableFunds() < amount) revert InsufficientFunds();
        
        usedFunds += amount;
        
        if (keccak256(bytes(reason)) == keccak256(bytes("liquidation"))) {
            totalUsedForLiquidations += amount;
        } else if (keccak256(bytes(reason)) == keccak256(bytes("emergency"))) {
            totalUsedForEmergencies += amount;
        }
        
        emit FundsUsed(amount, reason);
    }
    
    /// @notice Withdraws excess funds from the insurance fund
    /// @param amount The amount to withdraw
    /// @param receiver The address to receive the withdrawn funds
    function withdrawFunds(uint256 amount, address receiver) external onlyOwner whenNotPaused {
        if (receiver == address(0)) revert InvalidAddress();
        
        if (availableFunds() < amount) revert InsufficientFunds();
        
        totalFunds -= amount;
        
        (bool success, ) = receiver.call{value: amount}("");
        if (!success) revert TransferFailed();
        
        emit FundsWithdrawn(receiver, amount);
    }
    
    /// @notice Returns the amount of available funds
    /// @return The available funds in the insurance fund
    function availableFunds() public view returns (uint256) {
        return totalFunds - usedFunds;
    }
    
    /// @notice Gets fund statistics
    /// @return _totalFunds Total funds
    /// @return _usedFunds Used funds
    /// @return _availableFunds Available funds
    /// @return _totalLiquidationContributions Total contributions from liquidations
    /// @return _totalFeeContributions Total contributions from fees
    /// @return _totalDirectContributions Total direct contributions
    function getFundStatistics() external view returns (
        uint256 _totalFunds,
        uint256 _usedFunds,
        uint256 _availableFunds,
        uint256 _totalLiquidationContributions,
        uint256 _totalFeeContributions,
        uint256 _totalDirectContributions
    ) {
        return (
            totalFunds,
            usedFunds,
            availableFunds(),
            totalLiquidationContributions,
            totalFeeContributions,
            totalDirectContributions
        );
    }
    
    /// @notice Gets usage statistics
    /// @return _totalUsedForLiquidations Total used for liquidations
    /// @return _totalUsedForEmergencies Total used for emergencies
    function getUsageStatistics() external view returns (
        uint256 _totalUsedForLiquidations,
        uint256 _totalUsedForEmergencies
    ) {
        return (
            totalUsedForLiquidations,
            totalUsedForEmergencies
        );
    }
    
    // Allow the contract to receive ETH
    receive() external payable {
        totalFunds += msg.value;
        totalDirectContributions += msg.value;
        
        emit FundsAdded(msg.sender, msg.value, "direct");
    }
}