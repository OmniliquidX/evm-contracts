// FeeDistributor.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/extensions/AccessControlEnumerable.sol";

/**
 * @title Fee Distributor
 * @notice Collects protocol fees and distributes them to staking, treasury, insurance fund, and buyback
 */
contract FeeDistributor is AccessControlEnumerable {
    // Roles
    bytes32 public constant FEE_COLLECTOR_ROLE = keccak256("FEE_COLLECTOR_ROLE");
    
    // OMNI token address
    address public omniToken;
    
    // Distribution addresses
    address public stakingContract;
    address public treasury;
    address public insuranceFund;
    
    // Distribution percentages (basis points)
    uint256 public stakingPercentage = 5000; // 50%
    uint256 public treasuryPercentage = 2000; // 20%
    uint256 public buybackBurnPercentage = 1000; // 10%
    uint256 public insuranceFundPercentage = 2000; // 20%
    
    // Fee collection statistics
    uint256 public totalFeesCollected;
    uint256 public totalStakingDistributed;
    uint256 public totalTreasuryDistributed;
    uint256 public totalBuybackBurned;
    uint256 public totalInsuranceFundDistributed;
    
    // Events
    event FeesCollected(uint256 amount);
    event FeesDistributed(
        uint256 stakingAmount,
        uint256 treasuryAmount,
        uint256 buybackAmount,
        uint256 insuranceFundAmount
    );
    event DistributionUpdated(
        uint256 stakingPercentage,
        uint256 treasuryPercentage,
        uint256 buybackBurnPercentage,
        uint256 insuranceFundPercentage
    );
    event AddressesUpdated(
        address stakingContract,
        address treasury,
        address insuranceFund
    );
    
    constructor(
        address _omniToken,
        address _stakingContract,
        address _treasury,
        address _insuranceFund,
        address admin
    ) {
        require(_omniToken != address(0), "Invalid OMN token address");
        require(_stakingContract != address(0), "Invalid staking contract address");
        require(_treasury != address(0), "Invalid treasury address");
        require(_insuranceFund != address(0), "Invalid insurance fund address");
        
        omniToken = _omniToken;
        stakingContract = _stakingContract;
        treasury = _treasury;
        insuranceFund = _insuranceFund;
        
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(FEE_COLLECTOR_ROLE, admin);
    }
    
    /**
     * @notice Collects fees from protocol operations
     */
    function collectFees() external payable onlyRole(FEE_COLLECTOR_ROLE) {
        require(msg.value > 0, "No fees to collect");
        
        totalFeesCollected += msg.value;
        
        emit FeesCollected(msg.value);
    }
    
    /**
     * @notice Distributes collected fees according to distribution percentages
     */
    function distributeFees() external {
        uint256 balance = address(this).balance;
        require(balance > 0, "No fees to distribute");
        
        // Calculate amounts
        uint256 stakingAmount = (balance * stakingPercentage) / 10000;
        uint256 treasuryAmount = (balance * treasuryPercentage) / 10000;
        uint256 buybackAmount = (balance * buybackBurnPercentage) / 10000;
        uint256 insuranceFundAmount = (balance * insuranceFundPercentage) / 10000;
        
        // Distribute to staking contract
        if (stakingAmount > 0) {
            (bool stakingSuccess, ) = stakingContract.call{value: stakingAmount}("");
            require(stakingSuccess, "Staking distribution failed");
            totalStakingDistributed += stakingAmount;
        }
        
        // Distribute to treasury
        if (treasuryAmount > 0) {
            (bool treasurySuccess, ) = treasury.call{value: treasuryAmount}("");
            require(treasurySuccess, "Treasury distribution failed");
            totalTreasuryDistributed += treasuryAmount;
        }
        
        // Distribute to insurance fund
        if (insuranceFundAmount > 0) {
            (bool insuranceSuccess, ) = insuranceFund.call{value: insuranceFundAmount}("");
            require(insuranceSuccess, "Insurance fund distribution failed");
            totalInsuranceFundDistributed += insuranceFundAmount;
        }
        
        // Use buyback amount to buy and burn OMNI tokens
        if (buybackAmount > 0) {
            // In a real implementation, we would use a DEX to buy tokens
            // This is simplified to just burn tokens
            // Mock buyback by transferring tokens from admin
            address admin = getRoleMember(DEFAULT_ADMIN_ROLE, 0);
            uint256 burnAmount = buybackAmount * 10; // Mocked exchange rate: 1 ETH = 10 OMNI
            
            try IERC20(omniToken).transferFrom(admin, address(this), burnAmount) {
                // Burn the tokens (assuming OMNI token has a burn function)
                try IERC20(omniToken).transfer(address(0), burnAmount) {
                    totalBuybackBurned += buybackAmount;
                } catch {
                    // Fallback if token doesn't support burn by transfer to zero address
                    (bool adminSuccess, ) = admin.call{value: buybackAmount}("");
                    require(adminSuccess, "Admin transfer failed");
                }
            } catch {
                // If mock fails, send to admin
                (bool adminSuccess, ) = admin.call{value: buybackAmount}("");
                require(adminSuccess, "Admin transfer failed");
            }
        }
        
        emit FeesDistributed(stakingAmount, treasuryAmount, buybackAmount, insuranceFundAmount);
    }
    
    /**
     * @notice Updates the fee distribution percentages
     * @param _stakingPercentage Percentage for staking (basis points)
     * @param _treasuryPercentage Percentage for treasury (basis points)
     * @param _buybackBurnPercentage Percentage for buyback & burn (basis points)
     * @param _insuranceFundPercentage Percentage for insurance fund (basis points)
     */
    function updateDistribution(
        uint256 _stakingPercentage,
        uint256 _treasuryPercentage,
        uint256 _buybackBurnPercentage,
        uint256 _insuranceFundPercentage
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(
            _stakingPercentage + _treasuryPercentage + _buybackBurnPercentage + _insuranceFundPercentage == 10000,
            "Percentages must add up to 100%"
        );
        
        stakingPercentage = _stakingPercentage;
        treasuryPercentage = _treasuryPercentage;
        buybackBurnPercentage = _buybackBurnPercentage;
        insuranceFundPercentage = _insuranceFundPercentage;
        
        emit DistributionUpdated(
            _stakingPercentage,
            _treasuryPercentage,
            _buybackBurnPercentage,
            _insuranceFundPercentage
        );
    }
    
    /**
     * @notice Updates distribution addresses
     * @param _stakingContract New staking contract address
     * @param _treasury New treasury address
     * @param _insuranceFund New insurance fund address
     */
    function updateAddresses(
        address _stakingContract,
        address _treasury,
        address _insuranceFund
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_stakingContract != address(0), "Invalid staking contract address");
        require(_treasury != address(0), "Invalid treasury address");
        require(_insuranceFund != address(0), "Invalid insurance fund address");
        
        stakingContract = _stakingContract;
        treasury = _treasury;
        insuranceFund = _insuranceFund;
        
        emit AddressesUpdated(
            _stakingContract,
            _treasury,
            _insuranceFund
        );
    }
    
    /**
     * @notice Allows the contract to receive ETH
     */
    receive() external payable {
        totalFeesCollected += msg.value;
        emit FeesCollected(msg.value);
    }
}