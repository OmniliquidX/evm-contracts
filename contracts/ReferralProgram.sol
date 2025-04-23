// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title Referral Program for Omniliquid
/// @notice Manages referral relationships and rewards
contract ReferralProgram {
    // State variables
    address public owner;
    address public feeManager;
    
    // Referral tiers
    struct Tier {
        uint256 volumeRequirement;
        uint256 referrerDiscount;  // in basis points (1 = 0.01%)
        uint256 referrerRebate;    // in basis points
    }
    
    // Referral relationships
    mapping(address => address) public referrers;  // trader -> referrer
    mapping(address => address[]) public referees;  // referrer -> traders referred
    
    // Referral stats
    mapping(address => uint256) public referralVolume;  // total volume from referrals
    mapping(address => uint256) public earnedRebates;   // total rebates earned
    mapping(address => uint256) public claimedRebates;  // rebates already claimed
    
    // Tiers
    Tier[] public tiers;
    mapping(address => uint256) public referrerTier;  // referrer -> current tier
    
    // Discount cap
    uint256 public maxDiscount = 1000;  // 10% maximum discount
    
    // Default referral code (for users without referrer)
    address public defaultReferrer;
    
    // Events
    event ReferralRegistered(address indexed trader, address indexed referrer);
    event ReferralVolumeAdded(address indexed trader, address indexed referrer, uint256 volume);
    event RebateEarned(address indexed referrer, address indexed trader, uint256 amount);
    event RebateClaimed(address indexed referrer, uint256 amount);
    event ReferrerTierUpdated(address indexed referrer, uint256 tier);
    event TierAdded(uint256 indexed tier, uint256 volumeRequirement, uint256 discount, uint256 rebate);
    event TierUpdated(uint256 indexed tier, uint256 volumeRequirement, uint256 discount, uint256 rebate);
    event MaxDiscountUpdated(uint256 oldMax, uint256 newMax);
    event DefaultReferrerUpdated(address indexed oldDefault, address indexed newDefault);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    
    // Errors
    error Unauthorized();
    error InvalidReferrer();
    error TierNotFound();
    error AlreadyReferred();
    error InsufficientRebates();
    
    modifier onlyOwner() {
        if (msg.sender != owner) revert Unauthorized();
        _;
    }
    
    modifier onlyFeeManager() {
        if (msg.sender != feeManager) revert Unauthorized();
        _;
    }
    
    constructor(address _feeManager) {
        require(_feeManager != address(0), "Invalid fee manager");
        feeManager = _feeManager;
        owner = msg.sender;
        
        // Initialize with default tiers
        tiers.push(Tier({
            volumeRequirement: 0,
            referrerDiscount: 50,    // 0.5% discount
            referrerRebate: 100      // 1% rebate
        }));
        
        tiers.push(Tier({
            volumeRequirement: 100 ether,
            referrerDiscount: 100,   // 1% discount
            referrerRebate: 150      // 1.5% rebate
        }));
        
        tiers.push(Tier({
            volumeRequirement: 1000 ether,
            referrerDiscount: 150,   // 1.5% discount
            referrerRebate: 200      // 2% rebate
        }));
    }
    
    /// @notice Transfers ownership of the contract to a new account
    /// @param newOwner The address of the new owner
    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "New owner cannot be zero address");
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }
    
    /// @notice Sets the fee manager address
    /// @param _feeManager The new fee manager address
    function setFeeManager(address _feeManager) external onlyOwner {
        require(_feeManager != address(0), "Invalid fee manager");
        feeManager = _feeManager;
    }
    
    /// @notice Sets the default referrer for users without a referral
    /// @param _defaultReferrer The default referrer address
    function setDefaultReferrer(address _defaultReferrer) external onlyOwner {
        require(_defaultReferrer != address(0), "Invalid referrer");
        address oldDefault = defaultReferrer;
        defaultReferrer = _defaultReferrer;
        emit DefaultReferrerUpdated(oldDefault, _defaultReferrer);
    }
    
    /// @notice Registers a referral relationship
    /// @param trader The trader being referred
    /// @param referrer The referrer
    function registerReferral(address trader, address referrer) external {
        // Can be called by trader or contract owner
        require(
            msg.sender == trader || 
            msg.sender == owner, 
            "Not authorized"
        );
        
        if (referrers[trader] != address(0)) revert AlreadyReferred();
        if (referrer == trader) revert InvalidReferrer();
        if (referrer == address(0)) revert InvalidReferrer();
        
        referrers[trader] = referrer;
        referees[referrer].push(trader);
        
        emit ReferralRegistered(trader, referrer);
    }
    
    /// @notice Records trading volume and calculates rebates
    /// @param trader The trader generating the volume
    /// @param volume The trading volume in ETH value
    /// @param fee The fee paid by the trader
    function recordVolume(address trader, uint256 volume, uint256 fee) external onlyFeeManager {
        // Get trader's referrer
        address referrer = referrers[trader];
        
        // If no referrer, use default
        if (referrer == address(0)) {
            referrer = defaultReferrer;
            
            // If no default either, exit
            if (referrer == address(0)) return;
        }
        
        // Add to referral volume
        referralVolume[referrer] += volume;
        
        // Check if referrer should be upgraded to next tier
        updateReferrerTier(referrer);
        
        // Get referrer's tier
        uint256 tierIndex = referrerTier[referrer];
        
        // Calculate rebate based on tier
        uint256 rebateAmount = (fee * tiers[tierIndex].referrerRebate) / 10000;
        
        // Add to earned rebates
        earnedRebates[referrer] += rebateAmount;
        
        emit ReferralVolumeAdded(trader, referrer, volume);
        emit RebateEarned(referrer, trader, rebateAmount);
    }
    
    /// @notice Updates a referrer's tier based on their volume
    /// @param referrer The referrer address
    function updateReferrerTier(address referrer) public {
        uint256 currentTier = referrerTier[referrer];
        uint256 currentVolume = referralVolume[referrer];
        
        // Check if eligible for a higher tier
        for (uint256 i = currentTier; i < tiers.length - 1; i++) {
            if (currentVolume >= tiers[i + 1].volumeRequirement) {
                referrerTier[referrer] = i + 1;
                emit ReferrerTierUpdated(referrer, i + 1);
            } else {
                break;
            }
        }
    }
    
    /// @notice Gets the fee discount for a trader
    /// @param trader The trader address
    /// @return The discount in basis points
    function getTraderDiscount(address trader) external view returns (uint256) {
        address referrer = referrers[trader];
        
        // If no referrer, use default
        if (referrer == address(0)) {
            referrer = defaultReferrer;
            
            // If no default either, no discount
            if (referrer == address(0)) return 0;
        }
        
        uint256 tierIndex = referrerTier[referrer];
        return tiers[tierIndex].referrerDiscount;
    }
    
    /// @notice Withdraws earned rebates
    /// @param amount The amount to withdraw
    function claimRebates(uint256 amount) external {
        address referrer = msg.sender;
        uint256 availableRebates = earnedRebates[referrer] - claimedRebates[referrer];
        
        if (availableRebates < amount) revert InsufficientRebates();
        
        // Update claimed amount
        claimedRebates[referrer] += amount;
        
        // Transfer rebates (would call to fee manager in actual implementation)
        // For simplicity, this is left as a stub
        
        emit RebateClaimed(referrer, amount);
    }
    
    /// @notice Adds a new tier
    /// @param volumeRequirement The volume requirement for the tier
    /// @param discount The discount for traders referred
    /// @param rebate The rebate for referrers
    function addTier(
        uint256 volumeRequirement,
        uint256 discount,
        uint256 rebate
    ) external onlyOwner {
        require(discount <= maxDiscount, "Discount exceeds maximum");
        
        // Add new tier
        tiers.push(Tier({
            volumeRequirement: volumeRequirement,
            referrerDiscount: discount,
            referrerRebate: rebate
        }));
        
        emit TierAdded(tiers.length - 1, volumeRequirement, discount, rebate);
    }
    
    /// @notice Updates an existing tier
    /// @param tier The tier index to update
    /// @param volumeRequirement The new volume requirement
    /// @param discount The new discount
    /// @param rebate The new rebate
    function updateTier(
        uint256 tier,
        uint256 volumeRequirement,
        uint256 discount,
        uint256 rebate
    ) external onlyOwner {
        if (tier >= tiers.length) revert TierNotFound();
        require(discount <= maxDiscount, "Discount exceeds maximum");
        
        tiers[tier].volumeRequirement = volumeRequirement;
        tiers[tier].referrerDiscount = discount;
        tiers[tier].referrerRebate = rebate;
        
        emit TierUpdated(tier, volumeRequirement, discount, rebate);
    }
    
    /// @notice Updates the maximum discount allowed
    /// @param _maxDiscount The new maximum discount
    function updateMaxDiscount(uint256 _maxDiscount) external onlyOwner {
        require(_maxDiscount <= 2000, "Maximum discount too high"); // Cap at 20%
        
        uint256 oldMax = maxDiscount;
        maxDiscount = _maxDiscount;
        
        emit MaxDiscountUpdated(oldMax, _maxDiscount);
    }
    
    /// @notice Gets the number of tiers
    /// @return The number of tiers
    function getTierCount() external view returns (uint256) {
        return tiers.length;
    }
    
    /// @notice Gets all referees for a referrer
    /// @param referrer The referrer address
    /// @return An array of referee addresses
    function getReferees(address referrer) external view returns (address[] memory) {
        return referees[referrer];
    }
    
    /// @notice Gets available rebates for a referrer
    /// @param referrer The referrer address
    /// @return The amount of available rebates
    function getAvailableRebates(address referrer) external view returns (uint256) {
        return earnedRebates[referrer] - claimedRebates[referrer];
    }
}