// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
}

/// @title Governance for Omniliquid
/// @notice Manages protocol governance, proposals, and voting
contract Governance {
    // Governance token (simplified - would be an actual ERC20 in production)
    address public governanceToken;
    
    // Proposal states
    enum ProposalState {
        Pending,
        Active,
        Defeated,
        Succeeded,
        Executed,
        Canceled
    }
    
    // Proposal structure
    struct Proposal {
        uint256 id;
        address proposer;
        string description;
        bytes[] callDatas;
        address[] targets;
        uint256[] values;
        uint256 startBlock;
        uint256 endBlock;
        uint256 forVotes;
        uint256 againstVotes;
        bool executed;
        bool canceled;
        mapping(address => Receipt) receipts;
    }
    
    // Vote receipt
    struct Receipt {
        bool hasVoted;
        bool support;
        uint256 votes;
    }
    
    // Simplified version for external viewing
    struct ProposalView {
        uint256 id;
        address proposer;
        string description;
        uint256 startBlock;
        uint256 endBlock;
        uint256 forVotes;
        uint256 againstVotes;
        bool executed;
        bool canceled;
        ProposalState state;
    }
    
    // Protocol parameters
    struct ProtocolParams {
        uint256 minPositionSize;
        uint256 maxLeverage;
        uint256 liquidationThreshold;
        uint256 maxDailyWithdrawal;
        uint256 insuranceFundFee;
    }
    
    // State variables
    mapping(uint256 => Proposal) public proposals;
    uint256 public proposalCount;
    uint256 public proposalThreshold = 1000 ether; // Min governance tokens to create proposal
    uint256 public votingPeriod = 17280; // ~3 days in blocks
    uint256 public votingDelay = 1; // 1 block
    address public admin;
    ProtocolParams public params;
    
    // Timelock for proposal execution
    uint256 public executionDelay = 2 days;
    mapping(uint256 => uint256) public proposalTimelocks;
    
    // Events
    event ProposalCreated(
        uint256 indexed proposalId,
        address indexed proposer,
        string description,
        uint256 startBlock,
        uint256 endBlock
    );
    
    event VoteCast(
        address indexed voter,
        uint256 indexed proposalId,
        bool support,
        uint256 votes
    );
    
    event ProposalExecuted(uint256 indexed proposalId);
    event ProposalCanceled(uint256 indexed proposalId);
    event ParameterUpdated(string param, uint256 value);
    event AdminTransferred(address indexed oldAdmin, address indexed newAdmin);
    event GovernanceTokenSet(address indexed token);
    
    // Errors
    error Unauthorized();
    error InvalidProposal();
    error ProposalNotActive();
    error AlreadyVoted();
    error ProposalAlreadyExecuted();
    error ProposalNotSucceeded();
    error TimelockNotExpired();
    error ExecutionFailed();
    
    modifier onlyAdmin() {
        if (msg.sender != admin) revert Unauthorized();
        _;
    }
    
    constructor(address _governanceToken) {
        require(_governanceToken != address(0), "Invalid governance token");
        governanceToken = _governanceToken;
        admin = msg.sender;
        
        // Set default protocol parameters
        params = ProtocolParams({
            minPositionSize: 0.01 ether,
            maxLeverage: 20,
            liquidationThreshold: 80, // 80%
            maxDailyWithdrawal: 100 ether,
            insuranceFundFee: 10 // 0.1%
        });
    }
    
    /// @notice Transfers admin rights
    /// @param newAdmin New admin address
    function transferAdmin(address newAdmin) external onlyAdmin {
        require(newAdmin != address(0), "Invalid address");
        emit AdminTransferred(admin, newAdmin);
        admin = newAdmin;
    }
    
    /// @notice Sets the governance token
    /// @param _governanceToken The new governance token address
    function setGovernanceToken(address _governanceToken) external onlyAdmin {
        require(_governanceToken != address(0), "Invalid token address");
        governanceToken = _governanceToken;
        emit GovernanceTokenSet(_governanceToken);
    }
    
    /// @notice Creates a governance proposal
    /// @param targets The addresses to call
    /// @param values The ETH values to send
    /// @param callDatas The calldata for each call
    /// @param description The proposal description
    /// @return The proposal ID
    function propose(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory callDatas,
        string memory description
    ) external returns (uint256) {
        require(targets.length > 0, "Empty proposal");
        require(targets.length == values.length, "Array length mismatch");
        require(targets.length == callDatas.length, "Array length mismatch");
        
        // Check proposer has enough governance tokens
        uint256 proposerVotes = IERC20(governanceToken).balanceOf(msg.sender);
        require(proposerVotes >= proposalThreshold, "Below proposal threshold");
        
        // Create proposal
        proposalCount++;
        uint256 proposalId = proposalCount;
        Proposal storage proposal = proposals[proposalId];
        
        proposal.id = proposalId;
        proposal.proposer = msg.sender;
        proposal.description = description;
        proposal.startBlock = block.number + votingDelay;
        proposal.endBlock = proposal.startBlock + votingPeriod;
        
        for (uint256 i = 0; i < targets.length; i++) {
            proposal.targets.push(targets[i]);
            proposal.values.push(values[i]);
            proposal.callDatas.push(callDatas[i]);
        }
        
        emit ProposalCreated(
            proposalId,
            msg.sender,
            description,
            proposal.startBlock,
            proposal.endBlock
        );
        
        return proposalId;
    }
    
    /// @notice Casts a vote on a proposal
    /// @param proposalId The proposal ID
    /// @param support Whether to support the proposal
    function castVote(uint256 proposalId, bool support) external {
        if (state(proposalId) != ProposalState.Active) revert ProposalNotActive();
        
        Proposal storage proposal = proposals[proposalId];
        if (proposal.receipts[msg.sender].hasVoted) revert AlreadyVoted();
        
        uint256 votes = getVotes(msg.sender);
        require(votes > 0, "No voting power");
        
        if (support) {
            proposal.forVotes += votes;
        } else {
            proposal.againstVotes += votes;
        }
        
        proposal.receipts[msg.sender] = Receipt({
            hasVoted: true,
            support: support,
            votes: votes
        });
        
        emit VoteCast(msg.sender, proposalId, support, votes);
    }
    
    /// @notice Queues a successful proposal for execution
    /// @param proposalId The proposal ID
    function queueProposal(uint256 proposalId) external {
        if (state(proposalId) != ProposalState.Succeeded) revert ProposalNotSucceeded();
        
        // Set timelock expiration
        proposalTimelocks[proposalId] = block.timestamp + executionDelay;
    }
    
    /// @notice Executes a successful proposal
    /// @param proposalId The proposal ID
    function executeProposal(uint256 proposalId) external {
        ProposalState currentState = state(proposalId);
        if (currentState != ProposalState.Succeeded) revert ProposalNotSucceeded();
        
        // Check timelock
        if (proposalTimelocks[proposalId] == 0) {
            // Not queued yet, queue it first
            proposalTimelocks[proposalId] = block.timestamp + executionDelay;
            revert TimelockNotExpired();
        }
        
        if (block.timestamp < proposalTimelocks[proposalId]) revert TimelockNotExpired();
        
        Proposal storage proposal = proposals[proposalId];
        proposal.executed = true;
        
        // Execute each call
        for (uint256 i = 0; i < proposal.targets.length; i++) {
            (bool success, ) = proposal.targets[i].call{value: proposal.values[i]}(
                proposal.callDatas[i]
            );
            if (!success) revert ExecutionFailed();
        }
        
        emit ProposalExecuted(proposalId);
    }
    
    /// @notice Cancels a proposal
    /// @param proposalId The proposal ID
    function cancelProposal(uint256 proposalId) external {
        ProposalState currentState = state(proposalId);
        require(
            currentState != ProposalState.Executed &&
            currentState != ProposalState.Canceled,
            "Cannot cancel"
        );
        
        Proposal storage proposal = proposals[proposalId];
        require(
            msg.sender == proposal.proposer || 
            msg.sender == admin,
            "Not authorized"
        );
        
        proposal.canceled = true;
        emit ProposalCanceled(proposalId);
    }
    
    /// @notice Gets the current state of a proposal
    /// @param proposalId The proposal ID
    /// @return The proposal state
    function state(uint256 proposalId) public view returns (ProposalState) {
        if (proposalId == 0 || proposalId > proposalCount) revert InvalidProposal();
        
        Proposal storage proposal = proposals[proposalId];
        
        if (proposal.canceled) {
            return ProposalState.Canceled;
        }
        
        if (proposal.executed) {
            return ProposalState.Executed;
        }
        
        if (block.number <= proposal.startBlock) {
            return ProposalState.Pending;
        }
        
        if (block.number <= proposal.endBlock) {
            return ProposalState.Active;
        }
        
        if (proposal.forVotes <= proposal.againstVotes) {
            return ProposalState.Defeated;
        }
        
        return ProposalState.Succeeded;
    }
    
    /// @notice Gets the voting power of an account
    /// @param account The account address
    /// @return The voting power
    function getVotes(address account) public view returns (uint256) {
        return IERC20(governanceToken).balanceOf(account);
    }
    
    /// @notice Gets proposal details for external viewing
    /// @param proposalId The proposal ID
    /// @return A ProposalView struct with proposal details
    function getProposal(uint256 proposalId) external view returns (ProposalView memory) {
        if (proposalId == 0 || proposalId > proposalCount) revert InvalidProposal();
        
        Proposal storage proposal = proposals[proposalId];
        
        return ProposalView({
            id: proposal.id,
            proposer: proposal.proposer,
            description: proposal.description,
            startBlock: proposal.startBlock,
            endBlock: proposal.endBlock,
            forVotes: proposal.forVotes,
            againstVotes: proposal.againstVotes,
            executed: proposal.executed,
            canceled: proposal.canceled,
            state: state(proposalId)
        });
    }
    
    /// @notice Updates protocol parameters (only admin for bootstrapping, later governance)
    /// @param _minPositionSize New minimum position size
    /// @param _maxLeverage New maximum leverage
    /// @param _liquidationThreshold New liquidation threshold
    /// @param _maxDailyWithdrawal New maximum daily withdrawal
    /// @param _insuranceFundFee New insurance fund fee
    function updateProtocolParams(
        uint256 _minPositionSize,
        uint256 _maxLeverage,
        uint256 _liquidationThreshold,
        uint256 _maxDailyWithdrawal,
        uint256 _insuranceFundFee
    ) external onlyAdmin {
        params.minPositionSize = _minPositionSize;
        params.maxLeverage = _maxLeverage;
        params.liquidationThreshold = _liquidationThreshold;
        params.maxDailyWithdrawal = _maxDailyWithdrawal;
        params.insuranceFundFee = _insuranceFundFee;
        
        emit ParameterUpdated("minPositionSize", _minPositionSize);
        emit ParameterUpdated("maxLeverage", _maxLeverage);
        emit ParameterUpdated("liquidationThreshold", _liquidationThreshold);
        emit ParameterUpdated("maxDailyWithdrawal", _maxDailyWithdrawal);
        emit ParameterUpdated("insuranceFundFee", _insuranceFundFee);
    }
    
    /// @notice Updates governance parameters
    /// @param _proposalThreshold New proposal threshold
    /// @param _votingPeriod New voting period
    /// @param _votingDelay New voting delay
    /// @param _executionDelay New execution delay
    function updateGovernanceParams(
        uint256 _proposalThreshold,
        uint256 _votingPeriod,
        uint256 _votingDelay,
        uint256 _executionDelay
    ) external onlyAdmin {
        proposalThreshold = _proposalThreshold;
        votingPeriod = _votingPeriod;
        votingDelay = _votingDelay;
        executionDelay = _executionDelay;
        
        emit ParameterUpdated("proposalThreshold", _proposalThreshold);
        emit ParameterUpdated("votingPeriod", _votingPeriod);
        emit ParameterUpdated("votingDelay", _votingDelay);
        emit ParameterUpdated("executionDelay", _executionDelay);
    }
    
    // Function to receive ETH
    receive() external payable {}
}