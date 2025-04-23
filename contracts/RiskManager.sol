// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./AssetRegistry.sol";
import "./Oracle.sol";
import "./Market.sol";

/// @title Risk Manager for Omniliquid
/// @notice Handles platform-wide risk parameters and controls
contract RiskManager {
    address public owner;
    address public riskController;
    
    AssetRegistry public assetRegistry;
    Oracle public oracle;
    
    // Global risk parameters
    uint256 public maxGlobalOpenInterest;
    uint256 public maxPositionSize;
    uint256 public globalUtilizationLimit;
    uint256 public emergencyShutdownThreshold;
    
    // Asset-specific risk parameters
    mapping(bytes32 => uint256) public assetMaxLeverage;
    mapping(bytes32 => uint256) public assetMaxOI;
    mapping(bytes32 => uint256) public assetVolatilityMultiplier;
    mapping(bytes32 => bool) public assetTradeEnabled;
    
    // State variables
    bool public emergencyMode;
    
    event RiskParameterUpdated(string paramName, uint256 newValue);
    event AssetRiskParameterUpdated(string asset, string paramName, uint256 newValue);
    event AssetTradeStatusChanged(string asset, bool enabled);
    event EmergencyModeActivated();
    event EmergencyModeDeactivated();
    event RiskControllerUpdated(address indexed oldController, address indexed newController);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    
    modifier onlyOwner() {
        require(msg.sender == owner, "Not authorized");
        _;
    }
    
    modifier onlyRiskController() {
        require(msg.sender == riskController || msg.sender == owner, "Not authorized");
        _;
    }
    
    modifier notInEmergencyMode() {
        require(!emergencyMode, "Platform in emergency mode");
        _;
    }
    
    constructor(address _assetRegistry, address _oracle) {
        require(_assetRegistry != address(0), "Invalid asset registry address");
        require(_oracle != address(0), "Invalid oracle address");
        
        assetRegistry = AssetRegistry(_assetRegistry);
        oracle = Oracle(_oracle);
        owner = msg.sender;
        riskController = msg.sender;
        
        // Default values
        maxGlobalOpenInterest = 10000 ether;
        maxPositionSize = 1000 ether;
        globalUtilizationLimit = 80; // 80%
        emergencyShutdownThreshold = 95; // 95%
        emergencyMode = false;
    }
    
    /// @notice Transfers ownership of the contract to a new account
    /// @param newOwner The address of the new owner
    function transferOwnership(address newOwner) public onlyOwner {
        require(newOwner != address(0), "New owner cannot be the zero address");
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }
    
    /// @notice Updates the risk controller address
    /// @param _newController The new risk controller address
    function setRiskController(address _newController) external onlyOwner {
        require(_newController != address(0), "Invalid controller address");
        address oldController = riskController;
        riskController = _newController;
        emit RiskControllerUpdated(oldController, _newController);
    }
    
    /// @notice Sets maximum global open interest
    /// @param _maxGlobalOI New maximum global open interest value
    function setMaxGlobalOpenInterest(uint256 _maxGlobalOI) external onlyRiskController {
        maxGlobalOpenInterest = _maxGlobalOI;
        emit RiskParameterUpdated("maxGlobalOpenInterest", _maxGlobalOI);
    }
    
    /// @notice Sets maximum position size
    /// @param _maxPositionSize New maximum position size
    function setMaxPositionSize(uint256 _maxPositionSize) external onlyRiskController {
        maxPositionSize = _maxPositionSize;
        emit RiskParameterUpdated("maxPositionSize", _maxPositionSize);
    }
    
    /// @notice Sets global utilization limit
    /// @param _utilizationLimit New global utilization limit (percentage)
    function setGlobalUtilizationLimit(uint256 _utilizationLimit) external onlyRiskController {
        require(_utilizationLimit > 0 && _utilizationLimit <= 100, "Invalid utilization limit");
        globalUtilizationLimit = _utilizationLimit;
        emit RiskParameterUpdated("globalUtilizationLimit", _utilizationLimit);
    }
    
    /// @notice Sets emergency shutdown threshold
    /// @param _threshold New emergency shutdown threshold (percentage)
    function setEmergencyShutdownThreshold(uint256 _threshold) external onlyRiskController {
        require(_threshold > 0 && _threshold <= 100, "Invalid threshold");
        emergencyShutdownThreshold = _threshold;
        emit RiskParameterUpdated("emergencyShutdownThreshold", _threshold);
    }
    
    /// @notice Sets asset-specific maximum leverage
    /// @param asset The asset symbol
    /// @param maxLeverage The maximum leverage for the asset
    function setAssetMaxLeverage(string calldata asset, uint256 maxLeverage) external onlyRiskController {
        require(maxLeverage > 0 && maxLeverage <= 100, "Invalid leverage");
        bytes32 assetKey = keccak256(abi.encodePacked(asset));
        assetMaxLeverage[assetKey] = maxLeverage;
        emit AssetRiskParameterUpdated(asset, "maxLeverage", maxLeverage);
    }
    
    /// @notice Sets asset-specific maximum open interest
    /// @param asset The asset symbol
    /// @param maxOI The maximum open interest for the asset
    function setAssetMaxOI(string calldata asset, uint256 maxOI) external onlyRiskController {
        bytes32 assetKey = keccak256(abi.encodePacked(asset));
        assetMaxOI[assetKey] = maxOI;
        emit AssetRiskParameterUpdated(asset, "maxOI", maxOI);
    }
    
    /// @notice Sets asset-specific volatility multiplier
    /// @param asset The asset symbol
    /// @param multiplier The volatility multiplier for the asset
    function setAssetVolatilityMultiplier(string calldata asset, uint256 multiplier) external onlyRiskController {
        require(multiplier > 0, "Invalid multiplier");
        bytes32 assetKey = keccak256(abi.encodePacked(asset));
        assetVolatilityMultiplier[assetKey] = multiplier;
        emit AssetRiskParameterUpdated(asset, "volatilityMultiplier", multiplier);
    }
    
    /// @notice Enables or disables trading for a specific asset
    /// @param asset The asset symbol
    /// @param enabled Whether trading is enabled for the asset
    function setAssetTradeEnabled(string calldata asset, bool enabled) external onlyRiskController {
        bytes32 assetKey = keccak256(abi.encodePacked(asset));
        assetTradeEnabled[assetKey] = enabled;
        emit AssetTradeStatusChanged(asset, enabled);
    }
    
    /// @notice Activates emergency mode, which halts most platform operations
    function activateEmergencyMode() external onlyRiskController {
        emergencyMode = true;
        emit EmergencyModeActivated();
    }
    
    /// @notice Deactivates emergency mode, allowing platform operations to resume
    function deactivateEmergencyMode() external onlyRiskController {
        emergencyMode = false;
        emit EmergencyModeDeactivated();
    }
    
    /// @notice Checks if a position size is within risk limits
    /// @param asset The asset symbol
    /// @param size The position size to check
    /// @return True if the position size is acceptable
    function isPositionSizeValid(string calldata asset, uint256 size) external view returns (bool) {
        if (size > maxPositionSize) {
            return false;
        }
        
        bytes32 assetKey = keccak256(abi.encodePacked(asset));
        if (assetMaxOI[assetKey] > 0 && size > assetMaxOI[assetKey]) {
            return false;
        }
        
        return true;
    }
    
    /// @notice Checks if a leverage value is within risk limits for an asset
    /// @param asset The asset symbol
    /// @param leverage The leverage value to check
    /// @return True if the leverage is acceptable
    function isLeverageValid(string calldata asset, uint256 leverage) external view returns (bool) {
        bytes32 assetKey = keccak256(abi.encodePacked(asset));
        uint256 maxLeverage = assetMaxLeverage[assetKey];
        
        // If no asset-specific limit, use global default
        if (maxLeverage == 0) {
            return leverage <= 20; // Default max leverage
        }
        
        return leverage <= maxLeverage;
    }
    
    /// @notice Checks if trading is enabled for an asset
    /// @param asset The asset symbol
    /// @return True if trading is enabled
    function isTradeEnabledForAsset(string calldata asset) external view returns (bool) {
        if (emergencyMode) {
            return false;
        }
        
        bytes32 assetKey = keccak256(abi.encodePacked(asset));
        return assetTradeEnabled[assetKey];
    }
    
    /// @notice Gets the asset volatility multiplier
    /// @param asset The asset symbol
    /// @return The volatility multiplier
    function getAssetVolatilityMultiplier(string calldata asset) external view returns (uint256) {
        bytes32 assetKey = keccak256(abi.encodePacked(asset));
        uint256 multiplier = assetVolatilityMultiplier[assetKey];
        
        // If no asset-specific multiplier, return default
        if (multiplier == 0) {
            return 1; // Default multiplier
        }
        
        return multiplier;
    }
}