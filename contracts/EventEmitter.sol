// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./SecurityModule.sol";


/// @title Event Emitter for Omniliquid
/// @notice Centralizes event emission for efficient indexing
contract EventEmitter {
    // State variables
    address public owner;
    SecurityModule public securityModule;
    
    // Registered contracts that can emit events
    mapping(address => bool) public authorizedEmitters;
    
    // Event categories
    enum EventCategory {
        TRADE,
        POSITION,
        LIQUIDATION,
        FUNDING,
        COLLATERAL,
        ORDER,
        GOVERNANCE,
        SYSTEM
    }
    
    // Complex event structures for indexing
    struct TradeEvent {
        address trader;
        string asset;
        uint128 amount;
        uint128 price;
        bool isLong;
        uint256 fee;
        uint256 timestamp;
    }
    
    struct PositionEvent {
        uint256 positionId;
        address trader;
        string asset;
        uint128 size;
        uint128 price;
        bool isLong;
        uint256 leverage;
        uint256 timestamp;
    }
    
    struct LiquidationEvent {
        uint256 positionId;
        address trader;
        address liquidator;
        string asset;
        uint128 size;
        uint128 price;
        uint256 penalty;
        uint256 timestamp;
    }
    
    struct FundingEvent {
        string asset;
        int256 fundingRate;
        uint256 longSize;
        uint256 shortSize;
        uint256 timestamp;
    }
    
    struct CollateralEvent {
        address trader;
        uint256 amount;
        bool isDeposit;
        uint256 timestamp;
    }
    
    struct OrderEvent {
        uint256 orderId;
        address trader;
        string asset;
        bool isBuy;
        uint128 price;
        uint128 amount;
        bool isMarket;
        bool isFilled;
        uint256 timestamp;
    }
    
    // Events (with indexed fields for efficient filtering)
    event TradeExecuted(
        EventCategory indexed category,
        bytes32 indexed assetKey,
        address indexed trader,
        bytes tradeData
    );
    
    event PositionUpdated(
        EventCategory indexed category,
        bytes32 indexed assetKey,
        address indexed trader,
        bytes positionData
    );
    
    event LiquidationOccurred(
        EventCategory indexed category,
        bytes32 indexed assetKey,
        address indexed trader,
        bytes liquidationData
    );
    
    event FundingUpdated(
        EventCategory indexed category,
        bytes32 indexed assetKey,
        bytes fundingData
    );
    
    event CollateralChanged(
        EventCategory indexed category,
        address indexed trader,
        bytes collateralData
    );
    
    event OrderUpdated(
        EventCategory indexed category,
        bytes32 indexed assetKey,
        address indexed trader,
        bytes orderData
    );
    
    event SystemEvent(
        EventCategory indexed category,
        bytes systemData
    );
    
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event EmitterAdded(address indexed emitter);
    event EmitterRemoved(address indexed emitter);
    
    // Errors
    error Unauthorized();
    error InvalidCategory();
    
    modifier onlyOwner() {
        if (msg.sender != owner) revert Unauthorized();
        _;
    }
    
    modifier onlyAuthorizedEmitter() {
        if (!authorizedEmitters[msg.sender]) revert Unauthorized();
        _;
    }
    
    constructor(address _securityModule) {
        require(_securityModule != address(0), "Invalid security module");
        securityModule = SecurityModule(_securityModule);
        owner = msg.sender;
        
        // Self-register
        authorizedEmitters[address(this)] = true;
    }
    
    /// @notice Transfers ownership of the contract to a new account
    /// @param newOwner The address of the new owner
    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "New owner cannot be zero address");
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }
    
    /// @notice Adds an authorized contract that can emit events
    /// @param emitter The address of the contract to authorize
    function addAuthorizedEmitter(address emitter) external onlyOwner {
        require(emitter != address(0), "Invalid emitter address");
        authorizedEmitters[emitter] = true;
        emit EmitterAdded(emitter);
    }
    
    /// @notice Removes an authorized contract
    /// @param emitter The address of the contract to deauthorize
    function removeAuthorizedEmitter(address emitter) external onlyOwner {
        authorizedEmitters[emitter] = false;
        emit EmitterRemoved(emitter);
    }

/// @notice Emits a trade event
    /// @param asset The asset symbol
    /// @param trader The trader's address
    /// @param amount The trade amount
    /// @param price The trade price
    /// @param isLong Whether it's a long position
    /// @param fee The fee amount
    function emitTradeEvent(
        string calldata asset,
        address trader,
        uint128 amount,
        uint128 price,
        bool isLong,
        uint256 fee
    ) external onlyAuthorizedEmitter {
        TradeEvent memory tradeEvent = TradeEvent({
            trader: trader,
            asset: asset,
            amount: amount,
            price: price,
            isLong: isLong,
            fee: fee,
            timestamp: block.timestamp
        });
        
        bytes32 assetKey = keccak256(abi.encodePacked(asset));
        
        emit TradeExecuted(
            EventCategory.TRADE,
            assetKey,
            trader,
            abi.encode(tradeEvent)
        );
    }
    
    /// @notice Emits a position event
    /// @param positionId The position ID
    /// @param trader The trader's address
    /// @param asset The asset symbol
    /// @param size The position size
    /// @param price The entry price
    /// @param isLong Whether it's a long position
    /// @param leverage The leverage used
    function emitPositionEvent(
        uint256 positionId,
        address trader,
        string calldata asset,
        uint128 size,
        uint128 price,
        bool isLong,
        uint256 leverage
    ) external onlyAuthorizedEmitter {
        PositionEvent memory posEvent = PositionEvent({
            positionId: positionId,
            trader: trader,
            asset: asset,
            size: size,
            price: price,
            isLong: isLong,
            leverage: leverage,
            timestamp: block.timestamp
        });
        
        bytes32 assetKey = keccak256(abi.encodePacked(asset));
        
        emit PositionUpdated(
            EventCategory.POSITION,
            assetKey,
            trader,
            abi.encode(posEvent)
        );
    }
    
    /// @notice Emits a liquidation event
    /// @param positionId The position ID
    /// @param trader The trader's address
    /// @param liquidator The liquidator's address
    /// @param asset The asset symbol
    /// @param size The position size
    /// @param price The liquidation price
    /// @param penalty The liquidation penalty
    function emitLiquidationEvent(
        uint256 positionId,
        address trader,
        address liquidator,
        string calldata asset,
        uint128 size,
        uint128 price,
        uint256 penalty
    ) external onlyAuthorizedEmitter {
        LiquidationEvent memory liqEvent = LiquidationEvent({
            positionId: positionId,
            trader: trader,
            liquidator: liquidator,
            asset: asset,
            size: size,
            price: price,
            penalty: penalty,
            timestamp: block.timestamp
        });
        
        bytes32 assetKey = keccak256(abi.encodePacked(asset));
        
        emit LiquidationOccurred(
            EventCategory.LIQUIDATION,
            assetKey,
            trader,
            abi.encode(liqEvent)
        );
    }
    
    /// @notice Emits a funding rate update event
    /// @param asset The asset symbol
    /// @param fundingRate The new funding rate
    /// @param longSize The total long size
    /// @param shortSize The total short size
    function emitFundingEvent(
        string calldata asset,
        int256 fundingRate,
        uint256 longSize,
        uint256 shortSize
    ) external onlyAuthorizedEmitter {
        FundingEvent memory fundingEvent = FundingEvent({
            asset: asset,
            fundingRate: fundingRate,
            longSize: longSize,
            shortSize: shortSize,
            timestamp: block.timestamp
        });
        
        bytes32 assetKey = keccak256(abi.encodePacked(asset));
        
        emit FundingUpdated(
            EventCategory.FUNDING,
            assetKey,
            abi.encode(fundingEvent)
        );
    }
    
    /// @notice Emits a collateral change event
    /// @param trader The trader's address
    /// @param amount The collateral amount
    /// @param isDeposit Whether it's a deposit (true) or withdrawal (false)
    function emitCollateralEvent(
        address trader,
        uint256 amount,
        bool isDeposit
    ) external onlyAuthorizedEmitter {
        CollateralEvent memory collateralEvent = CollateralEvent({
            trader: trader,
            amount: amount,
            isDeposit: isDeposit,
            timestamp: block.timestamp
        });
        
        emit CollateralChanged(
            EventCategory.COLLATERAL,
            trader,
            abi.encode(collateralEvent)
        );
    }
    
    /// @notice Emits an order update event
    /// @param orderId The order ID
    /// @param trader The trader's address
    /// @param asset The asset symbol
    /// @param isBuy Whether it's a buy (true) or sell (false) order
    /// @param price The order price
    /// @param amount The order amount
    /// @param isMarket Whether it's a market order
    /// @param isFilled Whether the order is filled
    function emitOrderEvent(
        uint256 orderId,
        address trader,
        string calldata asset,
        bool isBuy,
        uint128 price,
        uint128 amount,
        bool isMarket,
        bool isFilled
    ) external onlyAuthorizedEmitter {
        OrderEvent memory orderEvent = OrderEvent({
            orderId: orderId,
            trader: trader,
            asset: asset,
            isBuy: isBuy,
            price: price,
            amount: amount,
            isMarket: isMarket,
            isFilled: isFilled,
            timestamp: block.timestamp
        });
        
        bytes32 assetKey = keccak256(abi.encodePacked(asset));
        
        emit OrderUpdated(
            EventCategory.ORDER,
            assetKey,
            trader,
            abi.encode(orderEvent)
        );
    }
    
    /// @notice Emits a system event
    /// @param data The system event data
    function emitSystemEvent(bytes calldata data) external onlyAuthorizedEmitter {
        emit SystemEvent(
            EventCategory.SYSTEM,
            data
        );
    }
}
