// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./SecurityModule.sol";

/// @title Fee Manager for Omniliquid
/// @notice Manages all platform fees with tiered fee structure and volume tracking
contract FeeManager {
    // State variables
    address public owner;
    address public treasury;
    SecurityModule public securityModule;
    
    // Fee structure (in basis points, 1 bp = 0.01%)
    uint16 public makerFee = 1;     // 0.01%
    uint16 public takerFee = 5;     // 0.05%
    uint16 public liquidationFee = 50; // 0.5%
    uint16 public withdrawalFee = 0;   // 0% initially
    
    // Tiered fee structure
    struct FeeTier {
        uint256 volumeThreshold;
        uint16 makerFee;
        uint16 takerFee;
    }
    
    FeeTier[] public feeTiers;
    
    // User volume tracking
    uint256 public volumeTrackingPeriod = 30 days;
    mapping(address => uint256) public userVolume;
    mapping(address => uint256) public userVolumeLastReset;
    
    // Referral program
    address public referralProgram;
    
    // Protocol fee collection
    uint256 public collectedFees;
    
    // Insurance fund contribution
    address public insuranceFund;
    uint16 public insuranceFundFee = 10; // 0.1% of fees go to insurance fund
    
    // Events
    event FeesCollected(uint256 amount, string feeType, address trader);
    event FeesWithdrawn(uint256 amount, address indexed receiver);
    event FeeUpdated(string feeType, uint16 oldFee, uint16 newFee);
    event FeeTierAdded(uint256 tier, uint256 volumeThreshold, uint16 makerFee, uint16 takerFee);
    event FeeTierUpdated(uint256 tier, uint256 volumeThreshold, uint16 makerFee, uint16 takerFee);
    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);
    event ReferralProgramUpdated(address indexed oldProgram, address indexed newProgram);
    event InsuranceFundUpdated(address indexed oldFund, address indexed newFund);
    event InsuranceFundFeeUpdated(uint16 oldFee, uint16 newFee);
    event VolumeTrackingPeriodUpdated(uint256 oldPeriod, uint256 newPeriod);
    event UserVolumeUpdated(address indexed user, uint256 volume, uint256 totalVolume);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    
    // Errors
    error Unauthorized();
    error InvalidFeeType();
    error InvalidAddress();
    error FeeTooHigh();
    error InvalidTier();

    // Modifiers
    modifier onlyOwner() {
        if (msg.sender != owner) revert Unauthorized();
        _;
    }
    
    modifier onlyOperator() {
        if (!securityModule.operators(msg.sender) && msg.sender != owner) revert Unauthorized();
        _;
    }

    constructor(address _treasury, address _securityModule) {
        if (_treasury == address(0)) revert InvalidAddress();
        if (_securityModule == address(0)) revert InvalidAddress();
        
        treasury = _treasury;
        securityModule = SecurityModule(_securityModule);
        owner = msg.sender;
        
        // Initialize default fee tiers
        feeTiers.push(FeeTier({
            volumeThreshold: 0,
            makerFee: 1,     // 0.01%
            takerFee: 5      // 0.05%
        }));
        
        feeTiers.push(FeeTier({
            volumeThreshold: 100 ether,
            makerFee: 1,     // 0.01%
            takerFee: 4      // 0.04%
        }));
        
        feeTiers.push(FeeTier({
            volumeThreshold: 1000 ether,
            makerFee: 0,     // 0%
            takerFee: 3      // 0.03%
        }));
    }
    
    /// @notice Transfers ownership of the contract to a new account
    /// @param newOwner The address of the new owner
    function transferOwnership(address newOwner) public onlyOwner {
        if (newOwner == address(0)) revert InvalidAddress();
        
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }
    
    /// @notice Updates the treasury address
    /// @param _newTreasury The new treasury address
    function setTreasury(address _newTreasury) external onlyOwner {
        if (_newTreasury == address(0)) revert InvalidAddress();
        
        address oldTreasury = treasury;
        treasury = _newTreasury;
        
        emit TreasuryUpdated(oldTreasury, _newTreasury);
    }
    
    /// @notice Sets the referral program contract
    /// @param _referralProgram The referral program contract address
    function setReferralProgram(address _referralProgram) external onlyOwner {
        address oldProgram = referralProgram;
        referralProgram = _referralProgram;
        
        emit ReferralProgramUpdated(oldProgram, _referralProgram);
    }
    
    /// @notice Sets the insurance fund contract
    /// @param _insuranceFund The insurance fund contract address
    function setInsuranceFund(address _insuranceFund) external onlyOwner {
        if (_insuranceFund == address(0)) revert InvalidAddress();
        
        address oldFund = insuranceFund;
        insuranceFund = _insuranceFund;
        
        emit InsuranceFundUpdated(oldFund, _insuranceFund);
    }
    
    /// @notice Sets the insurance fund fee
    /// @param _fee The insurance fund fee in basis points
    function setInsuranceFundFee(uint16 _fee) external onlyOwner {
        if (_fee > 5000) revert FeeTooHigh(); // Max 50%
        
        uint16 oldFee = insuranceFundFee;
        insuranceFundFee = _fee;
        
        emit InsuranceFundFeeUpdated(oldFee, _fee);
    }
    
    /// @notice Updates the volume tracking period
    /// @param _period The new period in seconds
    function setVolumeTrackingPeriod(uint256 _period) external onlyOwner {
        uint256 oldPeriod = volumeTrackingPeriod;
        volumeTrackingPeriod = _period;
        
        emit VolumeTrackingPeriodUpdated(oldPeriod, _period);
    }
    
    /// @notice Updates the maker fee
    /// @param _newFee The new maker fee in basis points
    function setMakerFee(uint16 _newFee) external onlyOwner {
        if (_newFee > 100) revert FeeTooHigh(); // Max 1%
        
        uint16 oldFee = makerFee;
        makerFee = _newFee;
        
        emit FeeUpdated("maker", oldFee, _newFee);
    }
    
    /// @notice Updates the taker fee
    /// @param _newFee The new taker fee in basis points
    function setTakerFee(uint16 _newFee) external onlyOwner {
        if (_newFee > 200) revert FeeTooHigh(); // Max 2%
        
        uint16 oldFee = takerFee;
        takerFee = _newFee;
        
        emit FeeUpdated("taker", oldFee, _newFee);
    }
    
    /// @notice Updates the liquidation fee
    /// @param _newFee The new liquidation fee in basis points
    function setLiquidationFee(uint16 _newFee) external onlyOwner {
        if (_newFee > 500) revert FeeTooHigh(); // Max 5%
        
        uint16 oldFee = liquidationFee;
        liquidationFee = _newFee;
        
        emit FeeUpdated("liquidation", oldFee, _newFee);
    }
    
    /// @notice Updates the withdrawal fee
    /// @param _newFee The new withdrawal fee in basis points
    function setWithdrawalFee(uint16 _newFee) external onlyOwner {
        if (_newFee > 100) revert FeeTooHigh(); // Max 1%
        
        uint16 oldFee = withdrawalFee;
        withdrawalFee = _newFee;
        
        emit FeeUpdated("withdrawal", oldFee, _newFee);
    }
    
    /// @notice Adds a new fee tier
    /// @param volumeThreshold The volume threshold for the tier
    /// @param tierMakerFee The maker fee for the tier
    /// @param tierTakerFee The taker fee for the tier
    function addFeeTier(
        uint256 volumeThreshold,
        uint16 tierMakerFee,
        uint16 tierTakerFee
    ) external onlyOwner {
        if (tierMakerFee > 100) revert FeeTooHigh(); // Max 1%
        if (tierTakerFee > 200) revert FeeTooHigh(); // Max 2%
        
        feeTiers.push(FeeTier({
            volumeThreshold: volumeThreshold,
            makerFee: tierMakerFee,
            takerFee: tierTakerFee
        }));
        
        emit FeeTierAdded(feeTiers.length - 1, volumeThreshold, tierMakerFee, tierTakerFee);
    }
    
    /// @notice Updates an existing fee tier
    /// @param tier The tier index
    /// @param volumeThreshold The volume threshold for the tier
    /// @param tierMakerFee The maker fee for the tier
    /// @param tierTakerFee The taker fee for the tier
    function updateFeeTier(
        uint256 tier,
        uint256 volumeThreshold,
        uint16 tierMakerFee,
        uint16 tierTakerFee
    ) external onlyOwner {
        if (tier >= feeTiers.length) revert InvalidTier();
        if (tierMakerFee > 100) revert FeeTooHigh(); // Max 1%
        if (tierTakerFee > 200) revert FeeTooHigh(); // Max 2%
        
        feeTiers[tier].volumeThreshold = volumeThreshold;
        feeTiers[tier].makerFee = tierMakerFee;
        feeTiers[tier].takerFee = tierTakerFee;
        
        emit FeeTierUpdated(tier, volumeThreshold, tierMakerFee, tierTakerFee);
    }
    
    /// @notice Gets the number of fee tiers
    /// @return The number of fee tiers
    function getFeeTierCount() external view returns (uint256) {
        return feeTiers.length;
    }
    
    /// @notice Gets the fee tier for a user
    /// @param user The user address
    /// @return The fee tier index
    function getUserFeeTier(address user) public view returns (uint256) {
        uint256 volume = userVolume[user];
        
        // Find the highest tier the user qualifies for
        for (uint256 i = feeTiers.length; i > 0; i--) {
            if (volume >= feeTiers[i-1].volumeThreshold) {
                return i-1;
            }
        }
        
        return 0; // Default tier
    }
    
    /// @notice Records trading volume for a user
    /// @param user The user address
    /// @param volume The volume to record
    function recordUserVolume(address user, uint256 volume) external onlyOperator {
        // Check if volume should be reset (if tracking period has passed)
        if (block.timestamp >= userVolumeLastReset[user] + volumeTrackingPeriod) {
            userVolume[user] = volume;
            userVolumeLastReset[user] = block.timestamp;
        } else {
            userVolume[user] += volume;
        }
        
        emit UserVolumeUpdated(user, volume, userVolume[user]);
    }
    
    /// @notice Calculates the fee amount based on the transaction value, fee type, and user
    /// @param value The transaction value
    /// @param feeType The type of fee (maker, taker, liquidation, withdrawal)
    /// @param user The user address
    /// @return The calculated fee amount
    function calculateFee(
        uint256 value,
        string memory feeType,
        address user
    ) public view returns (uint256) {
        uint16 fee;
        uint256 tierIndex = getUserFeeTier(user);
        
        bytes32 feeTypeHash = keccak256(bytes(feeType));
        
        if (feeTypeHash == keccak256(bytes("maker"))) {
            fee = feeTiers[tierIndex].makerFee;
        } else if (feeTypeHash == keccak256(bytes("taker"))) {
            fee = feeTiers[tierIndex].takerFee;
        } else if (feeTypeHash == keccak256(bytes("liquidation"))) {
            fee = liquidationFee; // Liquidation fee doesn't get tier discount
        } else if (feeTypeHash == keccak256(bytes("withdrawal"))) {
            fee = withdrawalFee; // Withdrawal fee doesn't get tier discount
        } else {
            revert InvalidFeeType();
        }
        
        // Apply referral discount if applicable and referral program is set
        if (referralProgram != address(0) && 
            (feeTypeHash == keccak256(bytes("maker")) || feeTypeHash == keccak256(bytes("taker")))) {
            try IReferralProgram(referralProgram).getTraderDiscount(user) returns (uint256 discount) {
                // Ensure we don't make the fee negative
                if (discount < fee) {
                    fee -= uint16(discount);
                } else {
                    fee = 0;
                }
            } catch {
                // If referral program call fails, use original fee
            }
        }
        
        return value * fee / 10000; // Convert basis points to percentage
    }
    
    /// @notice Simplified version of calculateFee for backward compatibility
    /// @param value The transaction value
    /// @param feeType The type of fee
    /// @return The calculated fee amount
    function calculateFee(uint256 value, string memory feeType) external view returns (uint256) {
        return calculateFee(value, feeType, address(0));
    }
    
    /// @notice Collects fees from various operations
    /// @param amount The fee amount to collect
    /// @param feeType The type of fee being collected
    /// @param trader The trader who paid the fee
    function collectFee(
        uint256 amount,
        string memory feeType,
        address trader
    ) external onlyOperator {
        collectedFees += amount;
        
        // Record fee for referral program if applicable
        if (referralProgram != address(0) && 
            (keccak256(bytes(feeType)) == keccak256(bytes("maker")) || 
             keccak256(bytes(feeType)) == keccak256(bytes("taker")))) {
            try IReferralProgram(referralProgram).recordVolume(trader, amount * 20, amount) { // Estimate volume as 20x fee
                // Successfully recorded
            } catch {
                // If referral program call fails, continue
            }
        }
        
        emit FeesCollected(amount, feeType, trader);
    }
    
    /// @notice Simplified version of collectFee for backward compatibility
    /// @param amount The fee amount to collect
    /// @param feeType The type of fee being collected
    function collectFee(uint256 amount, string memory feeType) external onlyOperator {
        this.collectFee(amount, feeType, address(0));
    }
    
    /// @notice Withdraws collected fees to the treasury and insurance fund
    function withdrawFees() external onlyOwner {
        if (collectedFees == 0) return;
        
        uint256 amount = collectedFees;
        collectedFees = 0;
        
        // Calculate insurance fund portion if applicable
        uint256 insuranceAmount = 0;
        if (insuranceFund != address(0) && insuranceFundFee > 0) {
            insuranceAmount = (amount * insuranceFundFee) / 10000;
            amount -= insuranceAmount;
        }
        
        // Transfer to treasury
        (bool success, ) = treasury.call{value: amount}("");
        require(success, "Treasury fee transfer failed");
        
        // Transfer to insurance fund if applicable
        if (insuranceAmount > 0) {
            (success, ) = insuranceFund.call{value: insuranceAmount}("");
            require(success, "Insurance fund fee transfer failed");
        }
        
        emit FeesWithdrawn(amount, treasury);
    }
    
    // Allow the contract to receive ETH
    receive() external payable {}
}

// Interface for the referral program
interface IReferralProgram {
    function getTraderDiscount(address trader) external view returns (uint256);
    function recordVolume(address trader, uint256 volume, uint256 fee) external;
}