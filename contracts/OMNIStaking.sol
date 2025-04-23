// OMNStaking.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/extensions/AccessControlEnumerable.sol";

interface IOMNIToken {
    function getDiscountForStakedAmount(uint256 stakedAmount) external view returns (uint256);
}

interface IFeeDistributor {
    function distributeToStakers() external payable;
}

/**
 * @title OMNI Staking Contract
 * @notice Allows users to stake OMNI tokens to earn ETH rewards and trading fee discounts
 */
contract OMNIStaking is ReentrancyGuard, AccessControlEnumerable {
    using SafeERC20 for IERC20;
    
    // Roles
    bytes32 public constant FEE_DISTRIBUTOR_ROLE = keccak256("FEE_DISTRIBUTOR_ROLE");
    
    // Staking parameters
    struct StakingTier {
        uint256 lockDuration; // in seconds
        uint256 rewardMultiplier; // in basis points (100 = 1x, 110 = 1.1x, etc.)
    }
    
    struct UserStake {
        uint256 amount;
        uint256 lockDuration;
        uint256 startTime;
        uint256 endTime;
        uint256 lastRewardClaimTime;
        bool unlocked;
    }
    
    // Token address
    IERC20 public omniToken;
    
    // Mapping from lock duration -> staking tier info
    mapping(uint256 => StakingTier) public stakingTiers;
    
    // Available lock durations
    uint256[] public lockDurations;
    
    // Mapping from user -> staking info
    mapping(address => UserStake[]) public userStakes;
    
    // Reward tracking
    uint256 public totalStaked;
    uint256 public totalRewardsDistributed;
    uint256 public accumulatedRewardsPerToken; // Scaled by 1e18
    mapping(address => uint256) public userRewardDebts;
    mapping(address => uint256) public pendingRewards;
    
    // Early withdrawal fee
    uint256 public earlyWithdrawalPenalty = 1000; // 10% in basis points
    
    // Events
    event Staked(address indexed user, uint256 amount, uint256 lockDuration, uint256 endTime);
    event Unstaked(address indexed user, uint256 amount, bool penalized);
    event RewardsClaimed(address indexed user, uint256 amount);
    event RewardsDistributed(uint256 amount);
    event StakingTierAdded(uint256 lockDuration, uint256 rewardMultiplier);
    event StakingTierUpdated(uint256 lockDuration, uint256 rewardMultiplier);
    event EarlyWithdrawalPenaltyUpdated(uint256 penalty);
    
    constructor(address _omniToken, address admin) {
        omniToken = IERC20(_omniToken);
        
        // Grant admin role
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        
        // Set up initial staking tiers
        _addStakingTier(0, 100); // Flexible staking - 1.0x multiplier
        _addStakingTier(30 days, 105); // 30 days - 1.05x multiplier
        _addStakingTier(90 days, 115); // 90 days - 1.15x multiplier
        _addStakingTier(180 days, 130); // 180 days - 1.3x multiplier
        _addStakingTier(365 days, 150); // 365 days - 1.5x multiplier
    }
    
    /**
     * @notice Adds a new staking tier
     * @param lockDuration Duration in seconds
     * @param rewardMultiplier Multiplier in basis points
     */
    function addStakingTier(uint256 lockDuration, uint256 rewardMultiplier) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _addStakingTier(lockDuration, rewardMultiplier);
    }
    
    /**
     * @notice Internal function to add a staking tier
     */
    function _addStakingTier(uint256 lockDuration, uint256 rewardMultiplier) internal {
        require(rewardMultiplier >= 100, "Multiplier must be at least 100 (1x)");
        require(stakingTiers[lockDuration].rewardMultiplier == 0, "Tier already exists");
        
        stakingTiers[lockDuration] = StakingTier({
            lockDuration: lockDuration,
            rewardMultiplier: rewardMultiplier
        });
        
        lockDurations.push(lockDuration);
        
        emit StakingTierAdded(lockDuration, rewardMultiplier);
    }
    
    /**
     * @notice Updates an existing staking tier
     * @param lockDuration Duration to update
     * @param rewardMultiplier New multiplier
     */
    function updateStakingTier(uint256 lockDuration, uint256 rewardMultiplier) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(rewardMultiplier >= 100, "Multiplier must be at least 100 (1x)");
        require(stakingTiers[lockDuration].rewardMultiplier != 0, "Tier doesn't exist");
        
        stakingTiers[lockDuration].rewardMultiplier = rewardMultiplier;
        
        emit StakingTierUpdated(lockDuration, rewardMultiplier);
    }
    
    /**
     * @notice Updates the early withdrawal penalty
     * @param penalty New penalty in basis points
     */
    function updateEarlyWithdrawalPenalty(uint256 penalty) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(penalty <= 3000, "Penalty cannot exceed 30%");
        earlyWithdrawalPenalty = penalty;
        emit EarlyWithdrawalPenaltyUpdated(penalty);
    }
    
    /**
     * @notice Stakes OMNI tokens
     * @param amount Amount to stake
     * @param lockDurationIndex Index of the lock duration in the lockDurations array
     */
    function stake(uint256 amount, uint256 lockDurationIndex) external nonReentrant {
        require(amount > 0, "Cannot stake 0");
        require(lockDurationIndex < lockDurations.length, "Invalid lock duration index");
        
        uint256 lockDuration = lockDurations[lockDurationIndex];
        // Ensure the lock duration exists
        require(stakingTiers[lockDuration].rewardMultiplier > 0, "Invalid lock duration");
        
        // Claim any pending rewards first
        _updateAndClaimRewards(msg.sender);
        
        // Transfer tokens from user
        omniToken.safeTransferFrom(msg.sender, address(this), amount);
        
        // Create new stake
        uint256 endTime = block.timestamp + lockDuration;
        userStakes[msg.sender].push(UserStake({
            amount: amount,
            lockDuration: lockDuration,
            startTime: block.timestamp,
            endTime: endTime,
            lastRewardClaimTime: block.timestamp,
            unlocked: false
        }));
        
        // Update total staked
        totalStaked += amount;
        
        // Update user reward debt
        userRewardDebts[msg.sender] = (amount * accumulatedRewardsPerToken) / 1e18;
        
        emit Staked(msg.sender, amount, lockDuration, endTime);
    }
    
    /**
     * @notice Unstakes tokens for a specific stake
     * @param stakeIndex Index of the stake to unstake
     */
    function unstake(uint256 stakeIndex) external nonReentrant {
        require(stakeIndex < userStakes[msg.sender].length, "Invalid stake index");
        
        UserStake storage userStake = userStakes[msg.sender][stakeIndex];
        require(!userStake.unlocked, "Stake already unlocked");
        
        uint256 amount = userStake.amount;
        bool penalized = false;
        
        // Claim any pending rewards first
        _updateAndClaimRewards(msg.sender);
        
        // Check if lock period has ended
        if (block.timestamp < userStake.endTime) {
            // Apply early withdrawal penalty
            uint256 penalty = (amount * earlyWithdrawalPenalty) / 10000;
            amount = amount - penalty;
            penalized = true;
            
            // Send penalty to rewards pool - effectively redistributing to other stakers
            totalStaked -= penalty;
            _distributeRewards(penalty);
        }
        
        // Mark stake as unlocked
        userStake.unlocked = true;
        
        // Update total staked
        totalStaked -= userStake.amount;
        
        // Update user reward debt
        userRewardDebts[msg.sender] = ((getTotalStakedByUser(msg.sender) - userStake.amount) * accumulatedRewardsPerToken) / 1e18;
        
        // Transfer tokens back to user
        omniToken.safeTransfer(msg.sender, amount);
        
        emit Unstaked(msg.sender, amount, penalized);
    }
    
    /**
     * @notice Claims pending rewards
     */
    function claimRewards() external nonReentrant {
        _updateAndClaimRewards(msg.sender);
    }
    
    /**
     * @notice Internal function to update and claim rewards
     * @param user User address
     */
    function _updateAndClaimRewards(address user) internal {
        if (getTotalStakedByUser(user) == 0) return;
        
        // Calculate pending rewards
        uint256 pending = calculatePendingRewards(user);
        
        if (pending > 0) {
            // Update reward claim time for all stakes
            for (uint i = 0; i < userStakes[user].length; i++) {
                if (!userStakes[user][i].unlocked) {
                    userStakes[user][i].lastRewardClaimTime = block.timestamp;
                }
            }
            
            // Reset pending rewards
            pendingRewards[user] = 0;
            
            // Send rewards to user
            (bool success, ) = user.call{value: pending}("");
            require(success, "ETH transfer failed");
            
            emit RewardsClaimed(user, pending);
        }
    }
    
    /**
     * @notice Calculate pending rewards for a user
     * @param user User address
     * @return Pending rewards in wei
     */
    function calculatePendingRewards(address user) public view returns (uint256) {
        if (getTotalStakedByUser(user) == 0) return 0;
        
        uint256 newRewards = (getTotalStakedByUser(user) * accumulatedRewardsPerToken) / 1e18 - userRewardDebts[user];
        
        // Apply reward multipliers based on lock periods
        uint256 adjustedRewards = 0;
        uint256 totalUserStaked = getTotalStakedByUser(user);
        
        if (totalUserStaked > 0) {
            for (uint i = 0; i < userStakes[user].length; i++) {
                UserStake memory myStake = userStakes[user][i];
                if (!myStake.unlocked) {
                    uint256 stakeShare = (myStake.amount * 1e18) / totalUserStaked;
                    uint256 stakeRewards = (newRewards * stakeShare) / 1e18;
                    uint256 multiplier = stakingTiers[myStake.lockDuration].rewardMultiplier;
                    adjustedRewards += (stakeRewards * multiplier) / 100;
                }
            }
        }
        
        return pendingRewards[user] + adjustedRewards;
    }
    
    /**
     * @notice Distributes ETH rewards to stakers
     */
    function distributeRewards() external payable onlyRole(FEE_DISTRIBUTOR_ROLE) {
        require(msg.value > 0, "Cannot distribute 0");
        _distributeRewards(msg.value);
    }
    
    /**
     * @notice Internal function to distribute rewards
     * @param amount Amount to distribute
     */
    function _distributeRewards(uint256 amount) internal {
        if (totalStaked == 0) {
            // If no stakers, send to admin
            bool adminExists = false;
            for (uint256 i = 0; i < 256; i++) {
                try this.getRoleMember(DEFAULT_ADMIN_ROLE, i) returns (address admin) {
                    if (admin != address(0)) {
                        adminExists = true;
                        break;
                    }
                } catch {
                    break;
                }
            }
            require(adminExists, "No admin available");
            (bool success, ) = payable(getRoleMember(DEFAULT_ADMIN_ROLE, 0)).call{value: amount}("");
            require(success, "ETH transfer failed");
            return;
        }
        
        // Increase accumulated rewards per token
        accumulatedRewardsPerToken += (amount * 1e18) / totalStaked;
        totalRewardsDistributed += amount;
        
        emit RewardsDistributed(amount);
    }
    
    /**
     * @notice Gets the total amount staked by a user
     * @param user User address
     * @return Total staked amount
     */
    function getTotalStakedByUser(address user) public view returns (uint256) {
        uint256 total = 0;
        for (uint i = 0; i < userStakes[user].length; i++) {
            if (!userStakes[user][i].unlocked) {
                total += userStakes[user][i].amount;
            }
        }
        return total;
    }
    
    /**
     * @notice Gets all active stakes for a user
     * @param user User address
     * @return amounts Array of stake amounts
     * @return userLockDurations Array of lock durations
     * @return startTimes Array of start times
     * @return endTimes Array of end times
     * @return multipliers Array of reward multipliers
     */
    function getStakesByUser(address user) external view returns (
        uint256[] memory amounts,
        uint256[] memory userLockDurations,
        uint256[] memory startTimes,
        uint256[] memory endTimes,
        uint256[] memory multipliers
    ) {
        uint256 activeCount = 0;
        
        // Count active stakes
        for (uint i = 0; i < userStakes[user].length; i++) {
            if (!userStakes[user][i].unlocked) {
                activeCount++;
            }
        }
        
        // Initialize arrays
        amounts = new uint256[](activeCount);
        userLockDurations = new uint256[](activeCount);
        startTimes = new uint256[](activeCount);
        endTimes = new uint256[](activeCount);
        multipliers = new uint256[](activeCount);
        
        // Fill arrays
        uint256 index = 0;
        for (uint i = 0; i < userStakes[user].length; i++) {
            if (!userStakes[user][i].unlocked) {
                UserStake memory userStake = userStakes[user][i];
                amounts[index] = userStake.amount;
                userLockDurations[index] = userStake.lockDuration;
                startTimes[index] = userStake.startTime;
                endTimes[index] = userStake.endTime;
                multipliers[index] = stakingTiers[userStake.lockDuration].rewardMultiplier;
                index++;
            }
        }
        
        return (amounts, lockDurations, startTimes, endTimes, multipliers);
    }
    
    /**
     * @notice Gets the fee discount for a user based on their staked amount
     * @param user User address
     * @return Discount in basis points
     */
    function getFeeDiscount(address user) external view returns (uint256) {
        uint256 totalAmountStaked = getTotalStakedByUser(user);
        return IOMNIToken(address(omniToken)).getDiscountForStakedAmount(totalAmountStaked);
    }
    
    /**
     * @notice Gets all available lock durations
     * @return Array of lock durations in seconds
     */
    function getLockDurations() external view returns (uint256[] memory) {
        return lockDurations;
    }
    
    /**
     * @notice Gets staking tier info for a specific lock duration
     * @param lockDuration Duration in seconds
     * @return duration Lock duration in seconds
     * @return multiplier Reward multiplier in basis points
     */
    function getStakingTier(uint256 lockDuration) external view returns (
        uint256 duration,
        uint256 multiplier
    ) {
        StakingTier memory tier = stakingTiers[lockDuration];
        return (tier.lockDuration, tier.rewardMultiplier);
    }
    
    // Allow contract to receive ETH
    receive() external payable {
        _distributeRewards(msg.value);
    }
}
