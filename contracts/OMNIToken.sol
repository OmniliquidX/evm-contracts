// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";
import "@openzeppelin/contracts/utils/Nonces.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";

/**
 * @title OMNI Token
 * @notice Governance and utility token for the Omniliquid protocol
 */
contract OMNIToken is ERC20, ERC20Burnable, ERC20Permit, ERC20Votes, AccessControl {
    bytes32 public constant MINTER_ROLE     = keccak256("MINTER_ROLE");
    bytes32 public constant GOVERNANCE_ROLE = keccak256("GOVERNANCE_ROLE");

    uint256 public maxSupply          = 100_000_000 * 1e18;
    uint256 public yearlyInflationCap =   5_000_000 * 1e18;

    uint256 public lastInflationUpdate;
    uint256 public yearlyMinted;

    mapping(uint256 => uint256) public stakingDiscountTiers;

    uint256 public tradingFeeBase          = 50;    // 0.05%
    uint256 public maxLeverage             = 20;    // 20x
    uint256 public stakingRewardPercentage = 5000;  // 50%
    uint256 public treasuryPercentage      = 2000;  // 20%
    uint256 public buybackBurnPercentage   = 1000;  // 10%
    uint256 public insuranceFundPercentage = 2000;  // 20%

    address public treasury;
    address public insuranceFund;

    event Minted(address indexed to, uint256 amount);
    event TreasuryUpdated(address indexed treasury);
    event InsuranceFundUpdated(address indexed insuranceFund);
    event TradingFeeBaseUpdated(uint256 newFee);
    event MaxLeverageUpdated(uint256 newLeverage);
    event RewardDistributionUpdated(uint256 staking, uint256 treasury, uint256 buybackBurn, uint256 insurance);
    event DiscountTierSet(uint256 tier, uint256 discount);

    constructor(address initialGovernance)
        ERC20("Omniliquid", "OMNI")
        ERC20Permit("Omniliquid")
    {
        _grantRole(DEFAULT_ADMIN_ROLE, initialGovernance);
        _grantRole(GOVERNANCE_ROLE, initialGovernance);
        lastInflationUpdate = block.timestamp;
    }

    function mint(address to, uint256 amount) external onlyRole(MINTER_ROLE) {
        require(totalSupply() + amount <= maxSupply, "Max supply exceeded");
        if (block.timestamp > lastInflationUpdate + 365 days) {
            yearlyMinted = 0;
            lastInflationUpdate = block.timestamp;
        }
        require(yearlyMinted + amount <= yearlyInflationCap, "Inflation cap exceeded");
        yearlyMinted += amount;
        _mint(to, amount);
        emit Minted(to, amount);
    }

    // Governance setters

    function setTreasury(address _treasury) external onlyRole(GOVERNANCE_ROLE) {
        treasury = _treasury;
        emit TreasuryUpdated(_treasury);
    }

    function setInsuranceFund(address _insuranceFund) external onlyRole(GOVERNANCE_ROLE) {
        insuranceFund = _insuranceFund;
        emit InsuranceFundUpdated(_insuranceFund);
    }

    function setTradingFeeBase(uint256 _fee) external onlyRole(GOVERNANCE_ROLE) {
        tradingFeeBase = _fee;
        emit TradingFeeBaseUpdated(_fee);
    }

    function setMaxLeverage(uint256 _leverage) external onlyRole(GOVERNANCE_ROLE) {
        maxLeverage = _leverage;
        emit MaxLeverageUpdated(_leverage);
    }

    function setRewardDistribution(
        uint256 _staking,
        uint256 _treasury,
        uint256 _buybackBurn,
        uint256 _insurance
    ) external onlyRole(GOVERNANCE_ROLE) {
        require(_staking + _treasury + _buybackBurn + _insurance == 10000, "Must equal 100%");
        stakingRewardPercentage = _staking;
        treasuryPercentage = _treasury;
        buybackBurnPercentage = _buybackBurn;
        insuranceFundPercentage = _insurance;
        emit RewardDistributionUpdated(_staking, _treasury, _buybackBurn, _insurance);
    }

    function setDiscountTier(uint256 tier, uint256 discountBps) external onlyRole(GOVERNANCE_ROLE) {
        require(discountBps <= 10000, "Max 100%");
        stakingDiscountTiers[tier] = discountBps;
        emit DiscountTierSet(tier, discountBps);
    }

    function getDiscountForStakedAmount(uint256 stakedAmount) public view returns (uint256) {
        uint256 applicableDiscount = 0;
        for (uint256 tier = 0; tier < 10; ++tier) {
            if (stakedAmount >= tier * 1000 ether) {
                applicableDiscount = stakingDiscountTiers[tier];
            }
        }
        return applicableDiscount;
    }

    function getDiscountTiers() external view returns (uint256[] memory) {
        uint256[] memory discounts = new uint256[](10);
        for (uint256 i = 0; i < 10; i++) {
            discounts[i] = stakingDiscountTiers[i];
        }
        return discounts;
    }

    // OpenZeppelin v5 override

    function _update(address from, address to, uint256 amount)
        internal
        override(ERC20, ERC20Votes)
    {
        super._update(from, to, amount);
    }

    function nonces(address owner)
        public
        view
        override(ERC20Permit, Nonces)
        returns (uint256)
    {
        return super.nonces(owner);
    }
}
