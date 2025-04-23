// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./AssetRegistry.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title Token Manager for Omniliquid
/// @notice Manages synthetic tokens and handles interactions with native tokens
contract TokenManager is ReentrancyGuard {
    using SafeERC20 for IERC20;
    
    address public owner;
    AssetRegistry public assetRegistry;
    
    // Token registry information
    struct TokenInfo {
        address tokenAddress;     // 0x0 for synthetic tokens
        bool isSynthetic;
        bool isEnabled;
        uint8 decimals;
        uint256 totalSupply;      // Only for synthetic tokens
        mapping(address => uint256) balances; // Only for synthetic tokens
    }
    
    // Token allowlists
    struct AllowList {
        bool isActive;
        mapping(address => bool) allowed;
    }
    
    mapping(bytes32 => TokenInfo) private tokens;
    mapping(bytes32 => AllowList) private allowLists;
    
    // Asset operators with higher privileges
    mapping(address => bool) public assetOperators;
    
    // Events
    event TokenRegistered(string symbol, address tokenAddress, bool isSynthetic, uint8 decimals);
    event TokenStatusChanged(string symbol, bool isEnabled);
    event SyntheticTokenMinted(string symbol, address indexed to, uint256 amount);
    event SyntheticTokenBurned(string symbol, address indexed from, uint256 amount);
    event TokenTransferred(string symbol, address indexed from, address indexed to, uint256 amount);
    event OperatorAdded(address indexed operator);
    event OperatorRemoved(address indexed operator);
    event AllowListStatusChanged(string symbol, bool isActive);
    event AddressAllowedForToken(string symbol, address indexed account);
    event AddressDisallowedForToken(string symbol, address indexed account);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    
    // Errors
    error Unauthorized();
    error InvalidToken();
    error InvalidAddress();
    error TokenNotSynthetic();
    error TokenDisabled();
    error InsufficientBalance();
    error AddressNotAllowed();
    event NativeTokenBalanceUpdated(string symbol, address indexed holder, uint256 newBalance);
    
    modifier onlyOwner() {
        if (msg.sender != owner) revert Unauthorized();
        _;
    }
    
    modifier onlyOperator() {
        if (!assetOperators[msg.sender] && msg.sender != owner) revert Unauthorized();
        _;
    }
    
    constructor(address _assetRegistry) {
        require(_assetRegistry != address(0), "Invalid asset registry address");
        assetRegistry = AssetRegistry(_assetRegistry);
        owner = msg.sender;
        
        // Add owner as operator
        assetOperators[owner] = true;
    }
    
    /// @notice Transfers ownership of the contract to a new account
    /// @param newOwner The address of the new owner
    function transferOwnership(address newOwner) public onlyOwner {
        if (newOwner == address(0)) revert InvalidAddress();
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }
    
    /// @notice Adds an asset operator
    /// @param operator The operator address to add
    function addOperator(address operator) external onlyOwner {
        if (operator == address(0)) revert InvalidAddress();
        assetOperators[operator] = true;
        emit OperatorAdded(operator);
    }
    
    /// @notice Removes an asset operator
    /// @param operator The operator address to remove
    function removeOperator(address operator) external onlyOwner {
        assetOperators[operator] = false;
        emit OperatorRemoved(operator);
    }
    
    /// @notice Registers a native token
    /// @param symbol The token symbol
    /// @param tokenAddress The token contract address
    /// @param decimals The token's decimal precision
    function registerNativeToken(
        string calldata symbol,
        address tokenAddress,
        uint8 decimals
    ) external onlyOwner {
        if (tokenAddress == address(0)) revert InvalidAddress();
        
        bytes32 key = keccak256(abi.encodePacked(symbol));
        
        // Initialize token info
        tokens[key].tokenAddress = tokenAddress;
        tokens[key].isSynthetic = false;
        tokens[key].isEnabled = true;
        tokens[key].decimals = decimals;
        
        emit TokenRegistered(symbol, tokenAddress, false, decimals);
    }
    
    /// @notice Registers a synthetic token
    /// @param symbol The token symbol
    /// @param decimals The token's decimal precision
    function registerSyntheticToken(
        string calldata symbol,
        uint8 decimals
    ) external onlyOwner {
        bytes32 key = keccak256(abi.encodePacked(symbol));
        
        // Initialize synthetic token info
        tokens[key].tokenAddress = address(0); // No token address for synthetic tokens
        tokens[key].isSynthetic = true;
        tokens[key].isEnabled = true;
        tokens[key].decimals = decimals;
        tokens[key].totalSupply = 0;
        
        emit TokenRegistered(symbol, address(0), true, decimals);
    }
    
    /// @notice Enables or disables a token
    /// @param symbol The token symbol
    /// @param isEnabled Whether the token is enabled
    function setTokenEnabled(string calldata symbol, bool isEnabled) external onlyOwner {
        bytes32 key = keccak256(abi.encodePacked(symbol));
        if (tokens[key].decimals == 0) revert InvalidToken();
        
        tokens[key].isEnabled = isEnabled;
        
        emit TokenStatusChanged(symbol, isEnabled);
    }
    
    /// @notice Activates or deactivates allow list for a token
    /// @param symbol The token symbol
    /// @param isActive Whether the allow list is active
    function setAllowListActive(string calldata symbol, bool isActive) external onlyOwner {
        bytes32 key = keccak256(abi.encodePacked(symbol));
        if (tokens[key].decimals == 0) revert InvalidToken();
        
        allowLists[key].isActive = isActive;
        
        emit AllowListStatusChanged(symbol, isActive);
    }
    
    /// @notice Adds an address to the allow list for a token
    /// @param symbol The token symbol
    /// @param account The account to allow
    function addToAllowList(string calldata symbol, address account) external onlyOwner {
        if (account == address(0)) revert InvalidAddress();
        
        bytes32 key = keccak256(abi.encodePacked(symbol));
        if (tokens[key].decimals == 0) revert InvalidToken();
        
        allowLists[key].allowed[account] = true;
        
        emit AddressAllowedForToken(symbol, account);
    }
    
    /// @notice Removes an address from the allow list for a token
    /// @param symbol The token symbol
    /// @param account The account to disallow
    function removeFromAllowList(string calldata symbol, address account) external onlyOwner {
        bytes32 key = keccak256(abi.encodePacked(symbol));
        if (tokens[key].decimals == 0) revert InvalidToken();
        
        allowLists[key].allowed[account] = false;
        
        emit AddressDisallowedForToken(symbol, account);
    }
    
    /// @notice Checks if an address is allowed for a token
    /// @param symbol The token symbol
    /// @param account The account to check
    /// @return Whether the account is allowed
    function isAllowed(string calldata symbol, address account) public view returns (bool) {
        bytes32 key = keccak256(abi.encodePacked(symbol));
        
        // If allow list is not active, all addresses are allowed
        if (!allowLists[key].isActive) {
            return true;
        }
        
        // Owner and operators are always allowed
        if (account == owner || assetOperators[account]) {
            return true;
        }
        
        return allowLists[key].allowed[account];
    }
    
    /// @notice Mints synthetic tokens to a user
    /// @param symbol The token symbol
    /// @param to The recipient address
    /// @param amount The amount to mint
    function mintSyntheticToken(
        string calldata symbol,
        address to,
        uint256 amount
    ) external onlyOperator nonReentrant {
        if (to == address(0)) revert InvalidAddress();
        if (amount == 0) revert InvalidToken();
        
        bytes32 key = keccak256(abi.encodePacked(symbol));
        if (!tokens[key].isSynthetic) revert TokenNotSynthetic();
        if (!tokens[key].isEnabled) revert TokenDisabled();
        
        // Check if recipient is allowed
        if (!isAllowed(symbol, to)) revert AddressNotAllowed();
        
        // Update user balance and total supply
        tokens[key].balances[to] += amount;
        tokens[key].totalSupply += amount;
        
        emit SyntheticTokenMinted(symbol, to, amount);
    }
    
    /// @notice Burns synthetic tokens from a user
    /// @param symbol The token symbol
    /// @param from The address to burn from
    /// @param amount The amount to burn
    function burnSyntheticToken(
        string calldata symbol,
        address from,
        uint256 amount
    ) external onlyOperator nonReentrant {
        if (from == address(0)) revert InvalidAddress();
        if (amount == 0) revert InvalidToken();
        
        bytes32 key = keccak256(abi.encodePacked(symbol));
        if (!tokens[key].isSynthetic) revert TokenNotSynthetic();
        if (!tokens[key].isEnabled) revert TokenDisabled();
        if (tokens[key].balances[from] < amount) revert InsufficientBalance();
        
        // Update user balance and total supply
        tokens[key].balances[from] -= amount;
        tokens[key].totalSupply -= amount;
        
        emit SyntheticTokenBurned(symbol, from, amount);
    }
    
    /// @notice Transfers synthetic tokens between users
    /// @param symbol The token symbol
    /// @param from The sender address
    /// @param to The recipient address
    /// @param amount The amount to transfer
    function transferSyntheticToken(
        string calldata symbol,
        address from,
        address to,
        uint256 amount
    ) external nonReentrant {
        if (from == address(0) || to == address(0)) revert InvalidAddress();
        if (amount == 0) revert InvalidToken();
        
        // Only owner, operators, or the sender themselves can call this
        if (msg.sender != from && msg.sender != owner && !assetOperators[msg.sender]) revert Unauthorized();
        
        bytes32 key = keccak256(abi.encodePacked(symbol));
        if (!tokens[key].isSynthetic) revert TokenNotSynthetic();
        if (!tokens[key].isEnabled) revert TokenDisabled();
        if (tokens[key].balances[from] < amount) revert InsufficientBalance();
        
        // Check if recipient is allowed
        if (!isAllowed(symbol, to)) revert AddressNotAllowed();
        
        // Update balances
        tokens[key].balances[from] -= amount;
        tokens[key].balances[to] += amount;
        
        emit TokenTransferred(symbol, from, to, amount);
    }
    
    /// @notice Updates a user's native token balance in the system
    /// @param symbol The token symbol
    /// @param holder The token holder
    /// @param balance The new balance
    function updateNativeTokenBalance(
        string calldata symbol,
        address holder,
        uint256 balance
    ) external onlyOperator {
        if (holder == address(0)) revert InvalidAddress();
        
        bytes32 key = keccak256(abi.encodePacked(symbol));
        if (tokens[key].isSynthetic) revert TokenNotSynthetic();
        if (!tokens[key].isEnabled) revert TokenDisabled();
        
        // This function only updates the system's knowledge of a user's balance
        // The actual token balance is managed by the ERC20 contract
        
        emit NativeTokenBalanceUpdated(symbol, holder, balance);
    }
    
    /// @notice Gets the balance of a synthetic token for a user
    /// @param symbol The token symbol
    /// @param user The user's address
    /// @return The user's balance
    function getSyntheticTokenBalance(
        string calldata symbol,
        address user
    ) external view returns (uint256) {
        bytes32 key = keccak256(abi.encodePacked(symbol));
        if (!tokens[key].isSynthetic) revert TokenNotSynthetic();
        
        return tokens[key].balances[user];
    }
    
    /// @notice Gets the actual balance of a native token for a user
    /// @param symbol The token symbol
    /// @param user The user's address
    /// @return The user's balance
    function getNativeTokenBalance(
        string calldata symbol,
        address user
    ) external view returns (uint256) {
        bytes32 key = keccak256(abi.encodePacked(symbol));
        if (tokens[key].isSynthetic) revert TokenNotSynthetic();
        
        address tokenAddress = tokens[key].tokenAddress;
        if (tokenAddress == address(0)) revert InvalidToken();
        
        return IERC20(tokenAddress).balanceOf(user);
    }
    
    /// @notice Gets the total supply of a synthetic token
    /// @param symbol The token symbol
    /// @return The total supply
    function getSyntheticTokenTotalSupply(
        string calldata symbol
    ) external view returns (uint256) {
        bytes32 key = keccak256(abi.encodePacked(symbol));
        if (!tokens[key].isSynthetic) revert TokenNotSynthetic();
        
        return tokens[key].totalSupply;
    }
    
    /// @notice Checks if a token is synthetic
    /// @param symbol The token symbol
    /// @return True if the token is synthetic
    function isSyntheticToken(string calldata symbol) external view returns (bool) {
        bytes32 key = keccak256(abi.encodePacked(symbol));
        return tokens[key].isSynthetic;
    }
    
    /// @notice Gets token information
    /// @param symbol The token symbol
    /// @return tokenAddress The token contract address (0x0 for synthetic tokens)
    /// @return isSynthetic Whether the token is synthetic
    /// @return isEnabled Whether the token is enabled
    /// @return decimals The token's decimal precision
    function getTokenInfo(
        string calldata symbol
    ) external view returns (
        address tokenAddress,
        bool isSynthetic,
        bool isEnabled,
        uint8 decimals
    ) {
        bytes32 key = keccak256(abi.encodePacked(symbol));
        
        return (
            tokens[key].tokenAddress,
            tokens[key].isSynthetic,
            tokens[key].isEnabled,
            tokens[key].decimals
        );
    }
    
    /// @notice Checks if a token has an active allow list
    /// @param symbol The token symbol
    /// @return Whether the token has an active allow list
    function hasActiveAllowList(string calldata symbol) external view returns (bool) {
        bytes32 key = keccak256(abi.encodePacked(symbol));
        return allowLists[key].isActive;
    }
}