// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./SecurityModule.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title Collateral Manager for Omniliquid
/// @notice Manages collateral deposits, withdrawals, and multi-asset support
contract CollateralManager is ReentrancyGuard {
    // ETH collateral tracking
    mapping(address => uint256) public collateralBalances;
    mapping(address => uint256) public lockedCollateral;
    
    // Token collateral tracking
    mapping(address => mapping(address => uint256)) public tokenCollateral; // user -> token -> amount
    mapping(address => mapping(address => uint256)) public lockedTokenCollateral; // user -> token -> amount
    
    // Supported tokens
    mapping(address => bool) public supportedCollateral; // token -> is supported
    mapping(address => uint256) public collateralValueMultiplier; // token -> multiplier (scaled by 1e4)
    address[] public supportedTokens;
    
    // Platform state
    address public owner;
    address public securityModule;
    address public feeCollector;
    address public vault;
    uint256 public totalCollateral;
    uint256 public totalLockedCollateral;
    
    // Collateral limits
    uint256 public maxCollateralPerUser = 1000 ether; // Maximum collateral per user
    mapping(address => uint256) public tokenMaxCollateral; // token -> max amount
    
    // Events
    event CollateralDeposited(address indexed trader, uint256 amount);
    event CollateralWithdrawn(address indexed trader, uint256 amount);
    event TokenCollateralDeposited(address indexed trader, address indexed token, uint256 amount);
    event TokenCollateralWithdrawn(address indexed trader, address indexed token, uint256 amount);
    event CollateralLocked(address indexed trader, uint256 amount);
    event TokenCollateralLocked(address indexed trader, address indexed token, uint256 amount);
    event CollateralUnlocked(address indexed trader, uint256 amount, int256 pnl);
    event TokenCollateralUnlocked(address indexed trader, address indexed token, uint256 amount, int256 pnl);
    event LiquidatorRewarded(address indexed liquidator, uint256 amount);
    event ProtocolFeeCollected(uint256 amount);
    event TokenAdded(address indexed token, uint256 valueMultiplier);
    event TokenRemoved(address indexed token);
    event TokenValueMultiplierUpdated(address indexed token, uint256 oldMultiplier, uint256 newMultiplier);
    event MaxCollateralUpdated(uint256 oldMax, uint256 newMax);
    event TokenMaxCollateralUpdated(address indexed token, uint256 oldMax, uint256 newMax);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event SecurityModuleUpdated(address indexed oldModule, address indexed newModule);
    event FeeCollectorUpdated(address indexed oldCollector, address indexed newCollector);
    event VaultUpdated(address indexed oldVault, address indexed newVault);

    // Error messages
    error Unauthorized();
    error InsufficientCollateral(uint256 requested, uint256 available);
    error TransferFailed();
    error InvalidAmount();
    error InvalidAddress();
    error SystemPaused();
    error CollateralLimitExceeded();
    error UnsupportedToken();
    error WithdrawalLimitExceeded();

    // Modifiers
    modifier onlyOwner() {
        if (msg.sender != owner) revert Unauthorized();
        _;
    }
    
    modifier onlyAuthorized() {
        // Only owner, security module, or registered contracts can call
        SecurityModule security = SecurityModule(securityModule);
        if (msg.sender != owner && msg.sender != securityModule && !security.operators(msg.sender)) {
            revert Unauthorized();
        }
        _;
    }
    
    modifier whenNotPaused() {
        SecurityModule security = SecurityModule(securityModule);
        if (security.paused()) revert SystemPaused();
        _;
    }

    constructor(address _securityModule, address _feeCollector, address _vault) {
        if (_securityModule == address(0) || _feeCollector == address(0) || _vault == address(0)) revert InvalidAddress();
        owner = msg.sender;
        securityModule = _securityModule;
        feeCollector = _feeCollector;
        vault = _vault;
    }

    /// @notice Transfers ownership of the contract to a new account
    /// @param newOwner The address of the new owner
    function transferOwnership(address newOwner) public onlyOwner {
        if (newOwner == address(0)) revert InvalidAddress();
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }
    
    /// @notice Update the security module
    /// @param _newSecurityModule New security module address
    function updateSecurityModule(address _newSecurityModule) external onlyOwner {
        if (_newSecurityModule == address(0)) revert InvalidAddress();
        address oldModule = securityModule;
        securityModule = _newSecurityModule;
        emit SecurityModuleUpdated(oldModule, _newSecurityModule);
    }
    
    /// @notice Update the fee collector
    /// @param _newFeeCollector New fee collector address
    function updateFeeCollector(address _newFeeCollector) external onlyOwner {
        if (_newFeeCollector == address(0)) revert InvalidAddress();
        address oldCollector = feeCollector;
        feeCollector = _newFeeCollector;
        emit FeeCollectorUpdated(oldCollector, _newFeeCollector);
    }
    
    /// @notice Update the vault
    /// @param _newVault New vault address
    function updateVault(address _newVault) external onlyOwner {
        if (_newVault == address(0)) revert InvalidAddress();
        address oldVault = vault;
        vault = _newVault;
        emit VaultUpdated(oldVault, _newVault);
    }
    
    /// @notice Set maximum collateral per user
    /// @param _maxCollateral New maximum collateral amount
    function setMaxCollateralPerUser(uint256 _maxCollateral) external onlyOwner {
        uint256 oldMax = maxCollateralPerUser;
        maxCollateralPerUser = _maxCollateral;
        emit MaxCollateralUpdated(oldMax, _maxCollateral);
    }
    
    /// @notice Add a supported token
    /// @param token Token address
    /// @param valueMultiplier Value multiplier (scaled by 1e4)
    /// @param maxAmount Maximum amount allowed for this token
    function addSupportedToken(address token, uint256 valueMultiplier, uint256 maxAmount) external onlyOwner {
        if (token == address(0)) revert InvalidAddress();
        
        supportedCollateral[token] = true;
        collateralValueMultiplier[token] = valueMultiplier;
        tokenMaxCollateral[token] = maxAmount;
        
        // Add token to list if not already there
        bool exists = false;
        for (uint256 i = 0; i < supportedTokens.length; i++) {
            if (supportedTokens[i] == token) {
                exists = true;
                break;
            }
        }
        
        if (!exists) {
            supportedTokens.push(token);
        }
        
        emit TokenAdded(token, valueMultiplier);
        emit TokenMaxCollateralUpdated(token, 0, maxAmount);
    }
    
    /// @notice Remove a supported token
    /// @param token Token address
    function removeSupportedToken(address token) external onlyOwner {
        supportedCollateral[token] = false;
        
        // Remove token from list
        for (uint256 i = 0; i < supportedTokens.length; i++) {
            if (supportedTokens[i] == token) {
                supportedTokens[i] = supportedTokens[supportedTokens.length - 1];
                supportedTokens.pop();
                break;
            }
        }
        
        emit TokenRemoved(token);
    }
    
    /// @notice Update a token's value multiplier
    /// @param token Token address
    /// @param valueMultiplier New value multiplier
    function updateTokenValueMultiplier(address token, uint256 valueMultiplier) external onlyOwner {
        if (!supportedCollateral[token]) revert UnsupportedToken();
        
        uint256 oldMultiplier = collateralValueMultiplier[token];
        collateralValueMultiplier[token] = valueMultiplier;
        
        emit TokenValueMultiplierUpdated(token, oldMultiplier, valueMultiplier);
    }
    
    /// @notice Update a token's maximum allowed amount
    /// @param token Token address
    /// @param maxAmount New maximum amount
    function updateTokenMaxCollateral(address token, uint256 maxAmount) external onlyOwner {
        if (!supportedCollateral[token]) revert UnsupportedToken();
        
        uint256 oldMax = tokenMaxCollateral[token];
        tokenMaxCollateral[token] = maxAmount;
        
        emit TokenMaxCollateralUpdated(token, oldMax, maxAmount);
    }

    /// @notice Deposits collateral into the trader's account.
    function depositCollateral() external payable whenNotPaused nonReentrant {
        if (msg.value == 0) revert InvalidAmount();
        
        // Check max collateral limit
        if (collateralBalances[msg.sender] + msg.value > maxCollateralPerUser) revert CollateralLimitExceeded();
        
        // Forward ETH to vault
        (bool success, ) = vault.call{value: msg.value}("");
        if (!success) revert TransferFailed();
        
        // Update balances
        collateralBalances[msg.sender] += msg.value;
        totalCollateral += msg.value;
        
        emit CollateralDeposited(msg.sender, msg.value);
    }
    
    /// @notice Deposits token collateral
    /// @param token Token address
    /// @param amount Amount to deposit
    function depositTokenCollateral(address token, uint256 amount) external whenNotPaused nonReentrant {
        if (!supportedCollateral[token]) revert UnsupportedToken();
        if (amount == 0) revert InvalidAmount();
        
        // Check token max collateral
        if (tokenCollateral[msg.sender][token] + amount > tokenMaxCollateral[token]) revert CollateralLimitExceeded();
        
        // Transfer tokens from user to this contract
        IERC20 tokenContract = IERC20(token);
        bool success = tokenContract.transferFrom(msg.sender, address(this), amount);
        if (!success) revert TransferFailed();
        
        // Update balances
        tokenCollateral[msg.sender][token] += amount;
        
        emit TokenCollateralDeposited(msg.sender, token, amount);
    }

    /// @notice Withdraws collateral from the trader's account.
    /// @param amount The amount to withdraw.
    function withdrawCollateral(uint256 amount) external whenNotPaused nonReentrant {
        // Check available collateral (total minus locked)
        uint256 available = collateralBalances[msg.sender] - lockedCollateral[msg.sender];
        if (available < amount) revert InsufficientCollateral(amount, available);
        
        // Check daily withdrawal limits
        SecurityModule security = SecurityModule(securityModule);
        if (!security.isWithdrawalAllowed(msg.sender, amount)) revert WithdrawalLimitExceeded();
        
        // Update balances before transfer to prevent reentrancy
        collateralBalances[msg.sender] -= amount;
        totalCollateral -= amount;
        
        // Record withdrawal for daily limits
        security.recordWithdrawal(msg.sender, amount);
        
        // Request withdrawal from vault
        IVault(vault).authorizedWithdrawal(amount, msg.sender);
        
        emit CollateralWithdrawn(msg.sender, amount);
    }
    
    /// @notice Withdraws token collateral
    /// @param token Token address
    /// @param amount Amount to withdraw
    function withdrawTokenCollateral(address token, uint256 amount) external whenNotPaused nonReentrant {
        if (!supportedCollateral[token]) revert UnsupportedToken();
        
        // Check available collateral (total minus locked)
        uint256 available = tokenCollateral[msg.sender][token] - lockedTokenCollateral[msg.sender][token];
        if (available < amount) revert InsufficientCollateral(amount, available);
        
        // Update balances before transfer to prevent reentrancy
        tokenCollateral[msg.sender][token] -= amount;
        
        // Transfer tokens to user
        IERC20 tokenContract = IERC20(token);
        bool success = tokenContract.transfer(msg.sender, amount);
        if (!success) revert TransferFailed();
        
        emit TokenCollateralWithdrawn(msg.sender, token, amount);
    }

    /// @notice Locks collateral for an open position.
    /// @param trader The address of the trader.
    /// @param amount The amount of collateral to lock.
    function lockCollateral(address trader, uint256 amount) external onlyAuthorized whenNotPaused {
        uint256 available = collateralBalances[trader] - lockedCollateral[trader];
        if (available < amount) revert InsufficientCollateral(amount, available);
        
        lockedCollateral[trader] += amount;
        totalLockedCollateral += amount;
        
        emit CollateralLocked(trader, amount);
    }
    
    /// @notice Locks token collateral for an open position
    /// @param trader The address of the trader
    /// @param token Token address
    /// @param amount The amount of collateral to lock
    function lockTokenCollateral(address trader, address token, uint256 amount) external onlyAuthorized whenNotPaused {
        if (!supportedCollateral[token]) revert UnsupportedToken();
        
        uint256 available = tokenCollateral[trader][token] - lockedTokenCollateral[trader][token];
        if (available < amount) revert InsufficientCollateral(amount, available);
        
        lockedTokenCollateral[trader][token] += amount;
        
        emit TokenCollateralLocked(trader, token, amount);
    }

    /// @notice Unlocks collateral after closing a position and adjusts for PnL.
    /// @param trader The address of the trader.
    /// @param amount The amount of collateral to unlock.
    /// @param pnl The profit or loss from the position (signed).
    function unlockCollateral(address trader, uint256 amount, int256 pnl) external onlyAuthorized {
        // Ensure we don't unlock more than was locked
        if (amount > lockedCollateral[trader]) revert InsufficientCollateral(amount, lockedCollateral[trader]);
        
        // Update locked amounts
        lockedCollateral[trader] -= amount;
        totalLockedCollateral -= amount;
        
        // Handle PnL adjustment - can be positive (profit) or negative (loss)
        if (pnl > 0) {
            // Add profit to trader's balance
            collateralBalances[trader] += uint256(pnl);
            totalCollateral += uint256(pnl);
        } else if (pnl < 0) {
            // Handle loss - ensure we don't underflow
            uint256 absLoss = uint256(-pnl);
            // If loss exceeds trader's balance, cap it
            if (absLoss > collateralBalances[trader]) {
                absLoss = collateralBalances[trader];
            }
            collateralBalances[trader] -= absLoss;
            totalCollateral -= absLoss;
        }
        
        emit CollateralUnlocked(trader, amount, pnl);
    }
    
    /// @notice Unlocks token collateral
    /// @param trader The address of the trader
    /// @param token Token address
    /// @param amount The amount to unlock
    /// @param pnl The profit or loss (signed)
    function unlockTokenCollateral(address trader, address token, uint256 amount, int256 pnl) external onlyAuthorized {
        if (!supportedCollateral[token]) revert UnsupportedToken();
        
        // Ensure we don't unlock more than was locked
        if (amount > lockedTokenCollateral[trader][token]) revert InsufficientCollateral(amount, lockedTokenCollateral[trader][token]);
        
        // Update locked amounts
        lockedTokenCollateral[trader][token] -= amount;
        
        // Handle PnL adjustment
        if (pnl > 0) {
            // Add profit to trader's token balance
            tokenCollateral[trader][token] += uint256(pnl);
        } else if (pnl < 0) {
            // Handle loss
            uint256 absLoss = uint256(-pnl);
            // If loss exceeds trader's balance, cap it
            if (absLoss > tokenCollateral[trader][token]) {
                absLoss = tokenCollateral[trader][token];
            }
            tokenCollateral[trader][token] -= absLoss;
        }
        
        emit TokenCollateralUnlocked(trader, token, amount, pnl);
    }
    
    /// @notice Reward a liquidator for successful liquidation
    /// @param liquidator Address of the liquidator
    /// @param amount Reward amount
    function rewardLiquidator(address liquidator, uint256 amount) external onlyAuthorized {
        if (liquidator == address(0)) revert InvalidAddress();
        
        // Request withdrawal from vault
        IVault(vault).authorizedWithdrawal(amount, liquidator);
        
        emit LiquidatorRewarded(liquidator, amount);
    }
    
    /// @notice Collect protocol fees
    /// @param amount Fee amount to collect
    function collectProtocolFee(uint256 amount) external onlyAuthorized {
        // Request withdrawal from vault
        IVault(vault).authorizedWithdrawal(amount, feeCollector);
        
        emit ProtocolFeeCollected(amount);
    }
    
    /// @notice Get trader's available collateral (not locked)
    /// @param trader Address of the trader
    /// @return Available collateral amount
    function getAvailableCollateral(address trader) external view returns (uint256) {
        return collateralBalances[trader] - lockedCollateral[trader];
    }
    
    /// @notice Get trader's available token collateral
    /// @param trader Address of the trader
    /// @param token Token address
    /// @return Available token collateral
    function getAvailableTokenCollateral(address trader, address token) external view returns (uint256) {
        if (!supportedCollateral[token]) return 0;
        return tokenCollateral[trader][token] - lockedTokenCollateral[trader][token];
    }
    
    /// @notice Get trader's total position (including locked collateral)
    /// @param trader Address of the trader
    /// @return Total collateral amount
    function getTotalCollateral(address trader) external view returns (uint256) {
        return collateralBalances[trader];
    }
    
    /// @notice Get all supported tokens
    /// @return Array of supported token addresses
    function getSupportedTokens() external view returns (address[] memory) {
        return supportedTokens;
    }
    
    /// @notice Get total collateral value for a trader (ETH + tokens)
    /// @param trader Address of the trader
    /// @return Total collateral value in ETH equivalent
    function getTotalCollateralValue(address trader) external view returns (uint256) {
        uint256 totalValue = collateralBalances[trader]; // ETH balance
        
        // Add token values
        for (uint256 i = 0; i < supportedTokens.length; i++) {
            address token = supportedTokens[i];
            if (supportedCollateral[token]) {
                uint256 tokenAmount = tokenCollateral[trader][token];
                uint256 tokenValue = tokenAmount * collateralValueMultiplier[token] / 1e4;
                totalValue += tokenValue;
            }
        }
        
        return totalValue;
    }
}

// Interface for the Vault
interface IVault {
    function authorizedWithdrawal(uint256 amount, address recipient) external;
}