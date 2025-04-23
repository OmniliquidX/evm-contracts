// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title Security Module for Omniliquid
/// @notice Provides security functions including emergency shutdown, access control, and circuit breakers
contract SecurityModule {
    // State variables
    address public admin;
    address public guardian;  // Multi-sig that can trigger emergency actions
    bool public paused;
    
    // Role-based access control
    struct Role {
        mapping(address => bool) members;
        bool exists;
    }

    mapping(bytes32 => Role) private roles;
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN");
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR");
    bytes32 public constant LIQUIDATOR_ROLE = keccak256("LIQUIDATOR");
    bytes32 public constant EMERGENCY_ROLE = keccak256("EMERGENCY");
    
    // Legacy access control mappings for backward compatibility
    mapping(address => bool) public operators;
    mapping(address => bool) public liquidators;
    
    // Circuit breaker thresholds
    uint256 public volatilityThreshold = 30; // 30% price move in 5 minutes triggers circuit breaker
    uint256 public lastCircuitBreakerTriggered;
    uint256 public circuitBreakerCooldown = 6 hours;
    
    // Asset-specific circuit breakers
    struct CircuitBreaker {
        uint256 priceDeviationThreshold;
        uint256 volumeThreshold;
        uint256 openInterestThreshold;
        uint256 lastTriggered;
        uint256 cooldownPeriod;
        bool isTriggered;
    }

    mapping(string => CircuitBreaker) public assetCircuitBreakers;
    
    // Admin control parameters
    uint256 public maxDailyWithdrawal = 1000 ether; // Maximum withdrawal per day
    mapping(address => uint256) public dailyWithdrawalAmount;
    mapping(address => uint256) public lastWithdrawalDay;
    
    // Events
    event Paused(address indexed trigger);
    event Unpaused(address indexed trigger);
    event CircuitBreakerTriggered(string asset, uint256 priceDelta, uint256 volume, uint256 openInterest);
    event CircuitBreakerReset(string asset);
    event AssetCircuitBreakerUpdated(string asset, uint256 priceDeviation, uint256 volumeThreshold, uint256 openInterestThreshold, uint256 cooldownPeriod);
    event RoleGranted(bytes32 indexed role, address indexed account, address indexed sender);
    event RoleRevoked(bytes32 indexed role, address indexed account, address indexed sender);
    event GuardianUpdated(address indexed oldGuardian, address indexed newGuardian);
    event AdminTransferred(address indexed oldAdmin, address indexed newAdmin);
    event DailyWithdrawalLimitUpdated(uint256 oldLimit, uint256 newLimit);
    event CircuitBreakerParamsUpdated(uint256 threshold, uint256 cooldown);
    
    // Errors
    error Unauthorized();
    error UnrecognizedRole();
    error CircuitBreakerNotConfigured();
    error CircuitBreakerCooldownActive();
    error ThresholdNotExceeded();
    error CircuitBreakerNotTriggered();
    error InvalidAddress();
    error InvalidParameter();

    // Modifiers
    modifier onlyRole(bytes32 role) {
        if (!hasRole(role, msg.sender)) revert Unauthorized();
        _;
    }
    
    modifier onlyAdmin() {
        if (msg.sender != admin && !hasRole(ADMIN_ROLE, msg.sender)) revert Unauthorized();
        _;
    }
    
    modifier onlyGuardian() {
        if (msg.sender != guardian && !hasRole(EMERGENCY_ROLE, msg.sender)) revert Unauthorized();
        _;
    }
    
    modifier onlyAdminOrGuardian() {
        if (msg.sender != admin && msg.sender != guardian && 
            !hasRole(ADMIN_ROLE, msg.sender) && !hasRole(EMERGENCY_ROLE, msg.sender)) {
            revert Unauthorized();
        }
        _;
    }
    
    modifier whenNotPaused() {
        require(!paused, "System is paused");
        _;
    }
    
    constructor(address _guardian) {
        if (_guardian == address(0)) revert InvalidAddress();
        
        admin = msg.sender;
        guardian = _guardian;
        
        // Setup roles
        _setupRole(ADMIN_ROLE, msg.sender);
        _setupRole(EMERGENCY_ROLE, _guardian);
        _setupRole(OPERATOR_ROLE, msg.sender);
        
        // Initialize legacy mappings
        operators[msg.sender] = true;
        
        // Mark roles as existing
        roles[ADMIN_ROLE].exists = true;
        roles[OPERATOR_ROLE].exists = true;
        roles[LIQUIDATOR_ROLE].exists = true;
        roles[EMERGENCY_ROLE].exists = true;
    }
    
    /// @notice Internal function to setup a role
    /// @param role The role to setup
    /// @param account The account to assign the role to
    function _setupRole(bytes32 role, address account) internal {
        roles[role].members[account] = true;
    }
    
    /// @notice Checks if an account has a specific role
    /// @param role The role to check
    /// @param account The account to check
    /// @return Whether the account has the role
    function hasRole(bytes32 role, address account) public view returns (bool) {
        return roles[role].exists && roles[role].members[account];
    }
    
    /// @notice Grants a role to an account
    /// @param role The role to grant
    /// @param account The account to grant the role to
    function grantRole(bytes32 role, address account) external onlyAdmin {
        if (!roles[role].exists) revert UnrecognizedRole();
        if (account == address(0)) revert InvalidAddress();
        
        roles[role].members[account] = true;
        
        // Update legacy mappings for backward compatibility
        if (role == OPERATOR_ROLE) {
            operators[account] = true;
        } else if (role == LIQUIDATOR_ROLE) {
            liquidators[account] = true;
        }
        
        emit RoleGranted(role, account, msg.sender);
    }
    
    /// @notice Revokes a role from an account
    /// @param role The role to revoke
    /// @param account The account to revoke the role from
    function revokeRole(bytes32 role, address account) external onlyAdmin {
        if (!roles[role].exists) revert UnrecognizedRole();
        
        roles[role].members[account] = false;
        
        // Update legacy mappings for backward compatibility
        if (role == OPERATOR_ROLE) {
            operators[account] = false;
        } else if (role == LIQUIDATOR_ROLE) {
            liquidators[account] = false;
        }
        
        emit RoleRevoked(role, account, msg.sender);
    }
    
    /// @notice Pause the entire system in case of emergency
    function pause() external onlyAdminOrGuardian {
        paused = true;
        emit Paused(msg.sender);
    }
    
    /// @notice Unpause the system after emergency is resolved
    function unpause() external onlyAdmin {
        paused = false;
        emit Unpaused(msg.sender);
    }
    
    /// @notice Transfer admin rights
    /// @param newAdmin New admin address
    function transferAdmin(address newAdmin) external onlyAdmin {
        if (newAdmin == address(0)) revert InvalidAddress();
        
        address oldAdmin = admin;
        admin = newAdmin;
        
        // Update roles
        _setupRole(ADMIN_ROLE, newAdmin);
        roles[ADMIN_ROLE].members[oldAdmin] = false;
        
        emit AdminTransferred(oldAdmin, newAdmin);
    }
    
    /// @notice Update the guardian address
    /// @param newGuardian New guardian address
    function updateGuardian(address newGuardian) external onlyAdmin {
        if (newGuardian == address(0)) revert InvalidAddress();
        
        address oldGuardian = guardian;
        guardian = newGuardian;
        
        // Update roles
        _setupRole(EMERGENCY_ROLE, newGuardian);
        roles[EMERGENCY_ROLE].members[oldGuardian] = false;
        
        emit GuardianUpdated(oldGuardian, newGuardian);
    }
    
    /// @notice Set asset-specific circuit breaker parameters
    /// @param asset The asset symbol
    /// @param priceDeviationThreshold The price deviation threshold (percentage)
    /// @param volumeThreshold The volume threshold
    /// @param openInterestThreshold The open interest threshold
    /// @param cooldownPeriod The cooldown period after triggering
    function setAssetCircuitBreaker(
        string calldata asset,
        uint256 priceDeviationThreshold,
        uint256 volumeThreshold,
        uint256 openInterestThreshold,
        uint256 cooldownPeriod
    ) external onlyAdmin {
        if (bytes(asset).length == 0) revert InvalidParameter();
        if (cooldownPeriod == 0) revert InvalidParameter();
        
        assetCircuitBreakers[asset] = CircuitBreaker({
            priceDeviationThreshold: priceDeviationThreshold,
            volumeThreshold: volumeThreshold,
            openInterestThreshold: openInterestThreshold,
            lastTriggered: 0,
            cooldownPeriod: cooldownPeriod,
            isTriggered: false
        });
        
        emit AssetCircuitBreakerUpdated(
            asset, 
            priceDeviationThreshold, 
            volumeThreshold, 
            openInterestThreshold, 
            cooldownPeriod
        );
    }
    
    /// @notice Trigger circuit breaker for an asset
    /// @param asset Asset symbol that experienced volatility
    /// @param priceDelta Percentage change in price
    /// @param volume Trading volume
    /// @param openInterest Open interest amount
    function triggerCircuitBreaker(
        string calldata asset,
        uint256 priceDelta,
        uint256 volume,
        uint256 openInterest
    ) external onlyRole(OPERATOR_ROLE) {
        CircuitBreaker storage breaker = assetCircuitBreakers[asset];
        
        // Check if circuit breaker exists
        if (breaker.cooldownPeriod == 0) revert CircuitBreakerNotConfigured();
        
        // Check if thresholds are exceeded
        bool thresholdExceeded = 
            priceDelta >= breaker.priceDeviationThreshold ||
            volume >= breaker.volumeThreshold ||
            openInterest >= breaker.openInterestThreshold;
        
        if (!thresholdExceeded) revert ThresholdNotExceeded();
        
        // Check cooldown
        if (block.timestamp < breaker.lastTriggered + breaker.cooldownPeriod) {
            revert CircuitBreakerCooldownActive();
        }
        
        // Trigger circuit breaker
        breaker.isTriggered = true;
        breaker.lastTriggered = block.timestamp;
        
        emit CircuitBreakerTriggered(asset, priceDelta, volume, openInterest);
    }
    
    /// @notice Reset circuit breaker for an asset
    /// @param asset Asset symbol to reset
    function resetCircuitBreaker(string calldata asset) external onlyAdmin {
        CircuitBreaker storage breaker = assetCircuitBreakers[asset];
        
        // Check if circuit breaker exists and is triggered
        if (breaker.cooldownPeriod == 0) revert CircuitBreakerNotConfigured();
        if (!breaker.isTriggered) revert CircuitBreakerNotTriggered();
        
        // Reset circuit breaker
        breaker.isTriggered = false;
        
        emit CircuitBreakerReset(asset);
    }
    
    /// @notice Legacy function to add operator (for backward compatibility)
    /// @param operator Address to add as operator
    function addOperator(address operator) external onlyAdmin {
        if (operator == address(0)) revert InvalidAddress();
        
        operators[operator] = true;
        _setupRole(OPERATOR_ROLE, operator);
        
        emit RoleGranted(OPERATOR_ROLE, operator, msg.sender);
    }
    
    /// @notice Legacy function to remove operator (for backward compatibility)
    /// @param operator Address to remove from operators
    function removeOperator(address operator) external onlyAdmin {
        operators[operator] = false;
        roles[OPERATOR_ROLE].members[operator] = false;
        
        emit RoleRevoked(OPERATOR_ROLE, operator, msg.sender);
    }
    
    /// @notice Legacy function to add liquidator (for backward compatibility)
    /// @param liquidator Address to add as liquidator
    function addLiquidator(address liquidator) external onlyAdmin {
        if (liquidator == address(0)) revert InvalidAddress();
        
        liquidators[liquidator] = true;
        _setupRole(LIQUIDATOR_ROLE, liquidator);
        
        emit RoleGranted(LIQUIDATOR_ROLE, liquidator, msg.sender);
    }
    
    /// @notice Legacy function to remove liquidator (for backward compatibility)
    /// @param liquidator Address to remove from liquidators
    function removeLiquidator(address liquidator) external onlyAdmin {
        liquidators[liquidator] = false;
        roles[LIQUIDATOR_ROLE].members[liquidator] = false;
        
        emit RoleRevoked(LIQUIDATOR_ROLE, liquidator, msg.sender);
    }
    
    /// @notice Check if withdrawal is allowed based on daily limits
    /// @param user User address
    /// @param amount Amount to withdraw
    /// @return Whether the withdrawal is allowed
    function isWithdrawalAllowed(address user, uint256 amount) public view returns (bool) {
        // Check if this is a new day
        uint256 currentDay = block.timestamp / 1 days;
        
        // If new day, reset counter
        if (currentDay > lastWithdrawalDay[user]) {
            return amount <= maxDailyWithdrawal;
        }
        
        // Check if user has exceeded daily withdrawal limit
        return dailyWithdrawalAmount[user] + amount <= maxDailyWithdrawal;
    }
    
    /// @notice Record a withdrawal to track daily limits
    /// @param user User address
    /// @param amount Amount withdrawn
    function recordWithdrawal(address user, uint256 amount) external onlyRole(OPERATOR_ROLE) {
        uint256 currentDay = block.timestamp / 1 days;
        
        // If new day, reset counter
        if (currentDay > lastWithdrawalDay[user]) {
            lastWithdrawalDay[user] = currentDay;
            dailyWithdrawalAmount[user] = amount;
        } else {
            // Add to today's total
            dailyWithdrawalAmount[user] += amount;
        }
        
        require(dailyWithdrawalAmount[user] <= maxDailyWithdrawal, "Daily withdrawal limit exceeded");
    }
    
    /// @notice Update daily withdrawal limit
    /// @param newLimit New daily withdrawal limit
    function updateDailyWithdrawalLimit(uint256 newLimit) external onlyAdmin {
        uint256 oldLimit = maxDailyWithdrawal;
        maxDailyWithdrawal = newLimit;
        
        emit DailyWithdrawalLimitUpdated(oldLimit, newLimit);
    }
    
    /// @notice Update legacy circuit breaker parameters
    /// @param newThreshold New volatility threshold
    /// @param newCooldown New cooldown period
    function updateCircuitBreakerParams(uint256 newThreshold, uint256 newCooldown) external onlyAdmin {
        volatilityThreshold = newThreshold;
        circuitBreakerCooldown = newCooldown;
        
        emit CircuitBreakerParamsUpdated(newThreshold, newCooldown);
    }
    
    /// @notice Check if an asset is paused
    /// @param asset The asset symbol
    /// @return Whether the asset is paused
    function isAssetPaused(string calldata asset) external view returns (bool) {
        return paused || assetCircuitBreakers[asset].isTriggered;
    }
}