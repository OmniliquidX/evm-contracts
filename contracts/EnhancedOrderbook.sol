// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./AssetRegistry.sol";
import "./EventEmitter.sol";
import "./SecurityModule.sol";

/// @title Enhanced OrderBook for Omniliquid
/// @notice Improved order book for efficient on-chain order matching
contract EnhancedOrderBook {
    enum OrderType { Limit, Market, StopLoss, TakeProfit }
    enum Side { Buy, Sell }
    enum OrderStatus { Open, Filled, PartiallyFilled, Cancelled }
    
    struct Order {
        uint256 id;
        address trader;
        bytes32 assetKey;  // hashed asset symbol for efficiency
        Side side;
        uint128 price;     // Price with 8 decimals precision
        uint128 originalAmount;  // Original amount in smallest units
        uint128 remainingAmount; // Remaining amount to be filled
        OrderType orderType;
        uint128 triggerPrice; // For stop-loss and take-profit orders
        uint256 timestamp;
        OrderStatus status;
    }
    
    // State variables
    mapping(bytes32 => mapping(uint256 => uint256[])) public buyOrdersByPrice;  // assetKey -> price -> order IDs
    mapping(bytes32 => mapping(uint256 => uint256[])) public sellOrdersByPrice; // assetKey -> price -> order IDs
    mapping(bytes32 => uint256[]) public buyPrices;   // assetKey -> sorted list of buy prices
    mapping(bytes32 => uint256[]) public sellPrices;  // assetKey -> sorted list of sell prices
    mapping(uint256 => Order) public orders;          // orderID -> Order
    
    // Order tracking
    uint256 public nextOrderId = 1;
    mapping(address => uint256[]) public userOrders;  // trader -> order IDs
    
    // Dependencies
    AssetRegistry public assetRegistry;
    EventEmitter public eventEmitter;
    SecurityModule public securityModule;
    
    // Owner
    address public owner;
    
    // Events
    event OrderPlaced(uint256 indexed orderId, address indexed trader, string asset, uint128 price, uint128 amount, Side side, OrderType orderType);
    event OrderCancelled(uint256 indexed orderId);
    event OrderFilled(uint256 indexed orderId, uint128 filledAmount, uint128 filledPrice);
    event OrderMatched(uint256 indexed buyOrderId, uint256 indexed sellOrderId, string asset, uint128 matchedAmount, uint128 matchedPrice);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    
    // Errors
    error Unauthorized();
    error OrderNotFound();
    error InvalidPrice();
    error InvalidAmount();
    error InvalidOrderStatus();
    error OrderbookPaused();
    error InvalidInput();
    
    // Modifiers
    modifier onlyOwner() {
        if (msg.sender != owner) revert Unauthorized();
        _;
    }
    
    modifier whenNotPaused() {
        if (securityModule.paused()) revert OrderbookPaused();
        _;
    }
    
    constructor(
        address _assetRegistry,
        address _eventEmitter,
        address _securityModule
    ) {
        require(_assetRegistry != address(0), "Invalid asset registry");
        require(_eventEmitter != address(0), "Invalid event emitter");
        require(_securityModule != address(0), "Invalid security module");
        
        assetRegistry = AssetRegistry(_assetRegistry);
        eventEmitter = EventEmitter(_eventEmitter);
        securityModule = SecurityModule(_securityModule);
        owner = msg.sender;
    }
    
    /// @notice Transfers ownership of the contract to a new account
    /// @param newOwner The address of the new owner
    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "New owner cannot be zero address");
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }
    
    /// @notice Places a new limit order
    /// @param asset The asset symbol
    /// @param side The order side (Buy or Sell)
    /// @param price The limit price
    /// @param amount The order amount
    /// @return The order ID
    function placeLimitOrder(
        string calldata asset,
        Side side,
        uint128 price,
        uint128 amount
    ) external whenNotPaused returns (uint256) {
        if (price == 0) revert InvalidPrice();
        if (amount == 0) revert InvalidAmount();
        
        // Check if asset is registered
        require(isAssetRegistered(asset), "Asset not registered");
        
        // Create the order
        return _createOrder(
            asset,
            side,
            price,
            amount,
            OrderType.Limit,
            0  // No trigger price for limit orders
        );
    }
    
    /// @notice Places a new market order
    /// @param asset The asset symbol
    /// @param side The order side (Buy or Sell)
    /// @param amount The order amount
    /// @return The order ID
    function placeMarketOrder(
        string calldata asset,
        Side side,
        uint128 amount
    ) external whenNotPaused returns (uint256) {
        if (amount == 0) revert InvalidAmount();
        
        // Check if asset is registered
        require(isAssetRegistered(asset), "Asset not registered");
        
        // For market orders, price is 0 (filled at best available price)
        return _createOrder(
            asset,
            side,
            0,  // Market orders don't have a specific price
            amount,
            OrderType.Market,
            0   // No trigger price
        );
    }
    
    /// @notice Places a new stop-loss order
    /// @param asset The asset symbol
    /// @param side The order side (Buy or Sell)
    /// @param triggerPrice The price at which the order becomes active
    /// @param amount The order amount
    /// @return The order ID
    function placeStopLossOrder(
        string calldata asset,
        Side side,
        uint128 triggerPrice,
        uint128 amount
    ) external whenNotPaused returns (uint256) {
        if (triggerPrice == 0) revert InvalidPrice();
        if (amount == 0) revert InvalidAmount();
        
        // Check if asset is registered
        require(isAssetRegistered(asset), "Asset not registered");
        
        return _createOrder(
            asset,
            side,
            0,  // Executed as market order when triggered
            amount,
            OrderType.StopLoss,
            triggerPrice
        );
    }
    
    /// @notice Places a new take-profit order
    /// @param asset The asset symbol
    /// @param side The order side (Buy or Sell)
    /// @param triggerPrice The price at which the order becomes active
    /// @param amount The order amount
    /// @return The order ID
    function placeTakeProfitOrder(
        string calldata asset,
        Side side,
        uint128 triggerPrice,
        uint128 amount
    ) external whenNotPaused returns (uint256) {
        if (triggerPrice == 0) revert InvalidPrice();
        if (amount == 0) revert InvalidAmount();
        
        // Check if asset is registered
        require(isAssetRegistered(asset), "Asset not registered");
        
        return _createOrder(
            asset,
            side,
            0,  // Executed as market order when triggered
            amount,
            OrderType.TakeProfit,
            triggerPrice
        );
    }
    
    /// @notice Internal function to create an order
    /// @param asset The asset symbol
    /// @param side The order side
    /// @param price The order price
    /// @param amount The order amount
    /// @param orderType The order type
    /// @param triggerPrice The trigger price (for stop/take-profit)
    /// @return The order ID
    function _createOrder(
        string calldata asset,
        Side side,
        uint128 price,
        uint128 amount,
        OrderType orderType,
        uint128 triggerPrice
    ) internal returns (uint256) {
        uint256 orderId = nextOrderId++;
        bytes32 assetKey = keccak256(abi.encodePacked(asset));
        
        orders[orderId] = Order({
            id: orderId,
            trader: msg.sender,
            assetKey: assetKey,
            side: side,
            price: price,
            originalAmount: amount,
            remainingAmount: amount,
            orderType: orderType,
            triggerPrice: triggerPrice,
            timestamp: block.timestamp,
            status: OrderStatus.Open
        });
        
        // Add to user orders
        userOrders[msg.sender].push(orderId);
        
        // Add to order book (for limit orders)
        if (orderType == OrderType.Limit) {
            if (side == Side.Buy) {
                // Add to buy orders
                _addBuyOrder(assetKey, price, orderId);
            } else {
                // Add to sell orders
                _addSellOrder(assetKey, price, orderId);
            }
        }
        
        // Emit events
        emit OrderPlaced(orderId, msg.sender, asset, price, amount, side, orderType);
        
        // Also emit to event emitter for indexing
        eventEmitter.emitOrderEvent(
            orderId,
            msg.sender,
            asset,
            side == Side.Buy,
            price,
            amount,
            orderType == OrderType.Market,
            false  // Not filled yet
        );
        
        // Try to match the order immediately
        if (orderType == OrderType.Market) {
            _matchMarketOrder(orderId);
        } else if (orderType == OrderType.Limit) {
            _matchLimitOrder(orderId);
        }
        // Stop-loss and take-profit orders are matched when triggered by price updates
        
        return orderId;
    }
    
    /// @notice Adds a buy order to the order book
    /// @param assetKey The asset key
    /// @param price The order price
    /// @param orderId The order ID
    function _addBuyOrder(bytes32 assetKey, uint128 price, uint256 orderId) internal {
        // Convert price to uint256 for mapping
        uint256 priceKey = uint256(price);
        
        // Add order to price level
        buyOrdersByPrice[assetKey][priceKey].push(orderId);
        
        // Add price to sorted list if not already there
        bool priceExists = false;
        for (uint256 i = 0; i < buyPrices[assetKey].length; i++) {
            if (buyPrices[assetKey][i] == priceKey) {
                priceExists = true;
                break;
            }
        }
        
        if (!priceExists) {
            // Insert price in descending order (highest first for buy orders)
            if (buyPrices[assetKey].length == 0) {
                buyPrices[assetKey].push(priceKey);
            } else {
                bool inserted = false;
                for (uint256 i = 0; i < buyPrices[assetKey].length; i++) {
                    if (priceKey > buyPrices[assetKey][i]) {
                        // Insert before current element
                        buyPrices[assetKey].push(0); // Extend array
                        
                        // Shift elements
                        for (uint256 j = buyPrices[assetKey].length - 1; j > i; j--) {
                            buyPrices[assetKey][j] = buyPrices[assetKey][j - 1];
                        }
                        
                        // Insert new price
                        buyPrices[assetKey][i] = priceKey;
                        inserted = true;
                        break;
                    }
                }
                
                if (!inserted) {
                    // Insert at the end
                    buyPrices[assetKey].push(priceKey);
                }
            }
        }
    }
    
    /// @notice Adds a sell order to the order book
    /// @param assetKey The asset key
    /// @param price The order price
    /// @param orderId The order ID
    function _addSellOrder(bytes32 assetKey, uint128 price, uint256 orderId) internal {
        // Convert price to uint256 for mapping
        uint256 priceKey = uint256(price);
        
        // Add order to price level
        sellOrdersByPrice[assetKey][priceKey].push(orderId);
        
        // Add price to sorted list if not already there
        bool priceExists = false;
        for (uint256 i = 0; i < sellPrices[assetKey].length; i++) {
            if (sellPrices[assetKey][i] == priceKey) {
                priceExists = true;
                break;
            }
        }
        
        if (!priceExists) {
            // Insert price in ascending order (lowest first for sell orders)
            if (sellPrices[assetKey].length == 0) {
                sellPrices[assetKey].push(priceKey);
            } else {
                bool inserted = false;
                for (uint256 i = 0; i < sellPrices[assetKey].length; i++) {
                    if (priceKey < sellPrices[assetKey][i]) {
                        // Insert before current element
                        sellPrices[assetKey].push(0); // Extend array
                        
                        // Shift elements
                        for (uint256 j = sellPrices[assetKey].length - 1; j > i; j--) {
                            sellPrices[assetKey][j] = sellPrices[assetKey][j - 1];
                        }
                        
                        // Insert new price
                        sellPrices[assetKey][i] = priceKey;
                        inserted = true;
                        break;
                    }
                }
                
                if (!inserted) {
                    // Insert at the end
                    sellPrices[assetKey].push(priceKey);
                }
            }
        }
    }
    
    /// @notice Matches a market order
    /// @param orderId The order ID to match
    function _matchMarketOrder(uint256 orderId) internal {
        Order storage order = orders[orderId];
        
        if (order.side == Side.Buy) {
            // Match against sell orders (lowest price first)
            bytes32 assetKey = order.assetKey;
            
            for (uint256 i = 0; i < sellPrices[assetKey].length && order.remainingAmount > 0; i++) {
                uint256 price = sellPrices[assetKey][i];
                uint256[] storage ordersAtPrice = sellOrdersByPrice[assetKey][price];
                
                for (uint256 j = 0; j < ordersAtPrice.length && order.remainingAmount > 0; j++) {
                    uint256 sellOrderId = ordersAtPrice[j];
                    _matchOrders(orderId, sellOrderId);
                }
            }
        } else {
            // Match against buy orders (highest price first)
            bytes32 assetKey = order.assetKey;
            
            for (uint256 i = 0; i < buyPrices[assetKey].length && order.remainingAmount > 0; i++) {
                uint256 price = buyPrices[assetKey][i];
                uint256[] storage ordersAtPrice = buyOrdersByPrice[assetKey][price];
                
                for (uint256 j = 0; j < ordersAtPrice.length && order.remainingAmount > 0; j++) {
                    uint256 buyOrderId = ordersAtPrice[j];
                    _matchOrders(buyOrderId, orderId);
                }
            }
        }
        
        // Update order status
        if (order.remainingAmount == 0) {
            order.status = OrderStatus.Filled;
        } else if (order.remainingAmount < order.originalAmount) {
            order.status = OrderStatus.PartiallyFilled;
        }
    }
    
    /// @notice Matches a limit order
    /// @param orderId The order ID to match
    function _matchLimitOrder(uint256 orderId) internal {
        Order storage order = orders[orderId];
        
        if (order.side == Side.Buy) {
            // Match against sell orders with price <= buy price
            bytes32 assetKey = order.assetKey;
            
            for (uint256 i = 0; i < sellPrices[assetKey].length && order.remainingAmount > 0; i++) {
                uint256 price = sellPrices[assetKey][i];
                
                if (price <= order.price) {
                    uint256[] storage ordersAtPrice = sellOrdersByPrice[assetKey][price];
                    
                    for (uint256 j = 0; j < ordersAtPrice.length && order.remainingAmount > 0; j++) {
                        uint256 sellOrderId = ordersAtPrice[j];
                        _matchOrders(orderId, sellOrderId);
                    }
                } else {
                    // Sell prices are sorted, so no need to check higher prices
                    break;
                }
            }
        } else {
            // Match against buy orders with price >= sell price
            bytes32 assetKey = order.assetKey;
            
            for (uint256 i = 0; i < buyPrices[assetKey].length && order.remainingAmount > 0; i++) {
                uint256 price = buyPrices[assetKey][i];
                
                if (price >= order.price) {
                    uint256[] storage ordersAtPrice = buyOrdersByPrice[assetKey][price];
                    
                    for (uint256 j = 0; j < ordersAtPrice.length && order.remainingAmount > 0; j++) {
                        uint256 buyOrderId = ordersAtPrice[j];
                        _matchOrders(buyOrderId, orderId);
                    }
                } else {
                    // Buy prices are sorted, so no need to check lower prices
                    break;
                }
            }
        }
        
        // Update order status
        if (order.remainingAmount == 0) {
            order.status = OrderStatus.Filled;
        } else if (order.remainingAmount < order.originalAmount) {
            order.status = OrderStatus.PartiallyFilled;
        }
    }
    
    /// @notice Matches two orders
    /// @param buyOrderId The buy order ID
    /// @param sellOrderId The sell order ID
    function _matchOrders(uint256 buyOrderId, uint256 sellOrderId) internal {
        Order storage buyOrder = orders[buyOrderId];
        Order storage sellOrder = orders[sellOrderId];
        
        // Skip if either order is not open
        if (buyOrder.status != OrderStatus.Open && buyOrder.status != OrderStatus.PartiallyFilled) return;
        if (sellOrder.status != OrderStatus.Open && sellOrder.status != OrderStatus.PartiallyFilled) return;
        
        // Skip if either order has no remaining amount
        if (buyOrder.remainingAmount == 0 || sellOrder.remainingAmount == 0) return;
        
        // Calculate match amount (minimum of both remaining amounts)
        uint128 matchAmount = buyOrder.remainingAmount < sellOrder.remainingAmount ? 
                             buyOrder.remainingAmount : sellOrder.remainingAmount;
        
        // Use the price of the resting order
        uint128 matchPrice;
        if (buyOrder.timestamp < sellOrder.timestamp) {
            matchPrice = buyOrder.price;
        } else {
            matchPrice = sellOrder.price;
        }
        
        // Update orders
        buyOrder.remainingAmount -= matchAmount;
        sellOrder.remainingAmount -= matchAmount;
        
        // Update order statuses
        if (buyOrder.remainingAmount == 0) {
            buyOrder.status = OrderStatus.Filled;
        } else {
            buyOrder.status = OrderStatus.PartiallyFilled;
        }
        
        if (sellOrder.remainingAmount == 0) {
            sellOrder.status = OrderStatus.Filled;
        } else {
            sellOrder.status = OrderStatus.PartiallyFilled;
        }
        
        // Get asset symbol from asset registry for events
        AssetRegistry.Asset memory assetInfo = assetRegistry.getAsset(getAssetSymbol(buyOrder.assetKey));
        
        // Emit events
        emit OrderFilled(buyOrderId, matchAmount, matchPrice);
        emit OrderFilled(sellOrderId, matchAmount, matchPrice);
        emit OrderMatched(buyOrderId, sellOrderId, assetInfo.symbol, matchAmount, matchPrice);
        
        // Also emit to event emitter for indexing
        eventEmitter.emitTradeEvent(
            assetInfo.symbol,
            buyOrder.trader,
            matchAmount,
            matchPrice,
            true,  // Buy is long
            0      // Fee handled elsewhere
        );
    }
    
    /// @notice Cancels an order
    /// @param orderId The order ID to cancel
    function cancelOrder(uint256 orderId) external {
        Order storage order = orders[orderId];
        
        if (order.trader != msg.sender) revert Unauthorized();
        if (order.status != OrderStatus.Open && order.status != OrderStatus.PartiallyFilled) {
            revert InvalidOrderStatus();
        }
        
        order.status = OrderStatus.Cancelled;
        
        // Remove from the order book if it's a limit order
        if (order.orderType == OrderType.Limit) {
            _removeOrderFromBook(order);
        }
        
        emit OrderCancelled(orderId);
        
        // Also emit to event emitter for indexing
        eventEmitter.emitOrderEvent(
            orderId,
            order.trader,
            getAssetSymbol(order.assetKey),
            order.side == Side.Buy,
            order.price,
            order.originalAmount,
            order.orderType == OrderType.Market,
            false  // Not filled
        );
    }
    
    /// @notice Removes an order from the order book
    /// @param order The order to remove
    function _removeOrderFromBook(Order storage order) internal {
        if (order.orderType != OrderType.Limit) return;
        
        uint256 priceKey = uint256(order.price);
        uint256[] storage ordersAtPrice;
        
        if (order.side == Side.Buy) {
            ordersAtPrice = buyOrdersByPrice[order.assetKey][priceKey];
        } else {
            ordersAtPrice = sellOrdersByPrice[order.assetKey][priceKey];
        }
        
        // Find and remove the order ID from the array
        for (uint256 i = 0; i < ordersAtPrice.length; i++) {
            if (ordersAtPrice[i] == order.id) {
                // Replace with the last element and pop
                ordersAtPrice[i] = ordersAtPrice[ordersAtPrice.length - 1];
                ordersAtPrice.pop();
                break;
            }
        }
        
        // If no more orders at this price, remove the price from the sorted list
        if (ordersAtPrice.length == 0) {
            if (order.side == Side.Buy) {
                for (uint256 i = 0; i < buyPrices[order.assetKey].length; i++) {
                    if (buyPrices[order.assetKey][i] == priceKey) {
                        // Replace with the last element and pop
                        buyPrices[order.assetKey][i] = buyPrices[order.assetKey][buyPrices[order.assetKey].length - 1];
                        buyPrices[order.assetKey].pop();
                        break;
                    }
                }
            } else {
                for (uint256 i = 0; i < sellPrices[order.assetKey].length; i++) {
                    if (sellPrices[order.assetKey][i] == priceKey) {
                        // Replace with the last element and pop
                        sellPrices[order.assetKey][i] = sellPrices[order.assetKey][sellPrices[order.assetKey].length - 1];
                        sellPrices[order.assetKey].pop();
                        break;
                    }
                }
            }
        }
    }
    
    /// @notice Processes triggered orders (stop-loss and take-profit)
    /// @param asset The asset symbol
    /// @param currentPrice The current price
    function processTriggerOrders(string calldata asset, uint128 currentPrice) external {
        // Only callable by oracle or security module
        require(
            msg.sender == address(securityModule) || 
            securityModule.operators(msg.sender),
            "Not authorized"
        );
        
        bytes32 assetKey = keccak256(abi.encodePacked(asset));
        
        // Process user orders for this asset
        // This is a simplified version and would need optimization in production
        for (uint256 i = 1; i < nextOrderId; i++) {
            Order storage order = orders[i];
            
            // Skip if order is not for this asset or not open
            if (order.assetKey != assetKey || 
                order.status != OrderStatus.Open) {
                continue;
            }
            
            // Check if the order should be triggered
            bool shouldTrigger = false;
            
            if (order.orderType == OrderType.StopLoss) {
                if (order.side == Side.Buy) {
                    // Buy stop: triggers when price rises above triggerPrice
                    shouldTrigger = currentPrice >= order.triggerPrice;
                } else {
                    // Sell stop: triggers when price falls below triggerPrice
                    shouldTrigger = currentPrice <= order.triggerPrice;
                }
            } else if (order.orderType == OrderType.TakeProfit) {
                if (order.side == Side.Buy) {
                    // Buy take-profit: triggers when price falls below triggerPrice
                    shouldTrigger = currentPrice <= order.triggerPrice;
                } else {
                    // Sell take-profit: triggers when price rises above triggerPrice
                    shouldTrigger = currentPrice >= order.triggerPrice;
                }
            }
            
            if (shouldTrigger) {
                // Convert to market order and match
                order.orderType = OrderType.Market;
                _matchMarketOrder(i);
            }
        }
    }
    
    /// @notice Gets the best bid price for an asset
    /// @param asset The asset symbol
    /// @return price The best bid price
    /// @return available The available amount at this price
    function getBestBid(string calldata asset) external view returns (uint128 price, uint128 available) {
        bytes32 assetKey = keccak256(abi.encodePacked(asset));
        
        if (buyPrices[assetKey].length == 0) {
            return (0, 0);
        }
        
        uint256 bestPrice = buyPrices[assetKey][0];  // Highest buy price
        uint256[] storage ordersAtPrice = buyOrdersByPrice[assetKey][bestPrice];
        
        uint128 totalAvailable = 0;
        for (uint256 i = 0; i < ordersAtPrice.length; i++) {
            Order storage order = orders[ordersAtPrice[i]];
            if (order.status == OrderStatus.Open || order.status == OrderStatus.PartiallyFilled) {
                totalAvailable += order.remainingAmount;
            }
        }
        
        return (uint128(bestPrice), totalAvailable);
    }
    
    /// @notice Gets the best ask price for an asset
    /// @param asset The asset symbol
    /// @return price The best ask price
    /// @return available The available amount at this price
    function getBestAsk(string calldata asset) external view returns (uint128 price, uint128 available) {
        bytes32 assetKey = keccak256(abi.encodePacked(asset));
        
        if (sellPrices[assetKey].length == 0) {
            return (0, 0);
        }
        
        uint256 bestPrice = sellPrices[assetKey][0];  // Lowest sell price
        uint256[] storage ordersAtPrice = sellOrdersByPrice[assetKey][bestPrice];
        
        uint128 totalAvailable = 0;
        for (uint256 i = 0; i < ordersAtPrice.length; i++) {
            Order storage order = orders[ordersAtPrice[i]];
            if (order.status == OrderStatus.Open || order.status == OrderStatus.PartiallyFilled) {
                totalAvailable += order.remainingAmount;
            }
        }
        
        return (uint128(bestPrice), totalAvailable);
    }
    
    /// @notice Gets the order book depth for an asset
    /// @param asset The asset symbol
    /// @param levels The number of price levels to return
    /// @return bidPrices Array of bid prices
    /// @return bidSizes Array of bid sizes
    /// @return askPrices Array of ask prices
    /// @return askSizes Array of ask sizes
    function getOrderBookDepth(
        string calldata asset,
        uint256 levels
    ) external view returns (
        uint128[] memory bidPrices,
        uint128[] memory bidSizes,
        uint128[] memory askPrices,
        uint128[] memory askSizes
    ) {
        bytes32 assetKey = keccak256(abi.encodePacked(asset));
        
        // Limit levels to avoid gas issues
        if (levels > 50) levels = 50;
        
        // Determine actual levels based on available price points
        uint256 bidLevels = buyPrices[assetKey].length < levels ? buyPrices[assetKey].length : levels;
        uint256 askLevels = sellPrices[assetKey].length < levels ? sellPrices[assetKey].length : levels;
        
        bidPrices = new uint128[](bidLevels);
        bidSizes = new uint128[](bidLevels);
        askPrices = new uint128[](askLevels);
        askSizes = new uint128[](askLevels);
        
        // Fill bid prices and sizes
        for (uint256 i = 0; i < bidLevels; i++) {
            uint256 priceKey = buyPrices[assetKey][i];
            bidPrices[i] = uint128(priceKey);
            
            uint256[] storage ordersAtPrice = buyOrdersByPrice[assetKey][priceKey];
            uint128 totalSize = 0;
            
            for (uint256 j = 0; j < ordersAtPrice.length; j++) {
                Order storage order = orders[ordersAtPrice[j]];
                if (order.status == OrderStatus.Open || order.status == OrderStatus.PartiallyFilled) {
                    totalSize += order.remainingAmount;
                }
            }
            
            bidSizes[i] = totalSize;
        }
        
        // Fill ask prices and sizes
        for (uint256 i = 0; i < askLevels; i++) {
            uint256 priceKey = sellPrices[assetKey][i];
            askPrices[i] = uint128(priceKey);
            
            uint256[] storage ordersAtPrice = sellOrdersByPrice[assetKey][priceKey];
            uint128 totalSize = 0;
            
            for (uint256 j = 0; j < ordersAtPrice.length; j++) {
                Order storage order = orders[ordersAtPrice[j]];
                if (order.status == OrderStatus.Open || order.status == OrderStatus.PartiallyFilled) {
                    totalSize += order.remainingAmount;
                }
            }
            
            askSizes[i] = totalSize;
        }
        
        return (bidPrices, bidSizes, askPrices, askSizes);
    }
    
    /// @notice Gets all orders for a trader
    /// @param trader The trader address
    /// @return orders Array of order IDs
    function getOrdersForTrader(address trader) external view returns (uint256[] memory) {
        return userOrders[trader];
    }
    
    /// @notice Gets details for an order
    /// @param orderId The order ID
    /// @return The order details
    function getOrder(uint256 orderId) external view returns (Order memory) {
        if (orderId >= nextOrderId) revert OrderNotFound();
        return orders[orderId];
    }
    
    /// @notice Checks if an asset is registered
    /// @param asset The asset symbol
    /// @return Whether the asset is registered
    function isAssetRegistered(string memory asset) internal view returns (bool) {
        try assetRegistry.getAsset(asset) returns (AssetRegistry.Asset memory) {
            return true;
        } catch {
            return false;
        }
    }
    
    /// @notice Gets the asset symbol for an asset key
    /// @param assetKey The asset key
    /// @return The asset symbol
    function getAssetSymbol(bytes32 assetKey) internal view returns (string memory) {
        string[] memory allAssets = assetRegistry.getAllAssets();
        
        for (uint256 i = 0; i < allAssets.length; i++) {
            if (keccak256(abi.encodePacked(allAssets[i])) == assetKey) {
                return allAssets[i];
            }
        }
        
        return "";
    }
}