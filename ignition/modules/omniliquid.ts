import { buildModule } from "@nomicfoundation/hardhat-ignition/modules";
import { ethers } from "ethers";

/**
 * Omniliquid Protocol Deployment Module - Synthetic Token Version
 * 
 * Deploys the Omniliquid protocol with synthetic tokens only (no external ERC20s)
 * for use on Pharos devnet, using collateral in native ETH to mint synthetic
 * tokens representing assets across crypto, forex, commodities, and ETFs.
 */
export default buildModule("OmniliquidProtocol", (m) => {
  // Define contract deployment parameters
  const deployParams = {
    // Initial parameters
    maxLeverage: 20,                          // 20x max leverage
    minPositionSize: ethers.parseEther("0.01"), // 0.01 ETH minimum
    liquidationThreshold: 80,                 // 80% liquidation threshold
    maxSkew: 25,                             // 25% max market skew
    
    // Fee structure (in basis points, 1 bp = 0.01%)
    makerFee: 1,     // 0.01%
    takerFee: 5,     // 0.05%
    liquidationFee: 50, // 0.5%
    
    // Insurance fund parameters
    insuranceFundFee: 10, // 0.1% of fees go to insurance fund
    
    // Supra Oracle configuration - Pharos devnet
    supraOracleAddress: "0xF439Cea7B2ec0338Ee7EC16ceAd78C9e1f47bc4c", // address for Pharos devnet
    
    // Supported synthetic assets
  // Supported synthetic assets
  syntheticAssets: {
    // Cryptocurrencies
    "BTC": {
      decimals: 8,
      oraclePairId: 0,
      maxAmount: ethers.parseEther("100")
    },
    "ETH": {
      decimals: 18,
      oraclePairId: 1,
      maxAmount: ethers.parseEther("1000")
    },
    "SOL": {
      decimals: 9,
      oraclePairId: 10,
      maxAmount: ethers.parseEther("10000")
    },
    
    // Forex
    "EUR": {
      decimals: 6,
      oraclePairId: 5000,
      maxAmount: ethers.parseEther("100000")
    },
    "GBP": {
      decimals: 6,
      oraclePairId: 5002,
      maxAmount: ethers.parseEther("100000")
    },
    
    // Commodities
    "XAU": {
      decimals: 6,
      oraclePairId: 5500,
      maxAmount: ethers.parseEther("1000")
    },
    "XAG": {
      decimals: 6,
      oraclePairId: 5501,
      maxAmount: ethers.parseEther("5000")
    },
    
    // Stocks
    "TSLA": {
      decimals: 6,
      oraclePairId: 6000,
      maxAmount: ethers.parseEther("10000")
    },
    "MSFT": {
      decimals: 6,
      oraclePairId: 6001,
      maxAmount: ethers.parseEther("10000")
    },
    "NVDA": {
      decimals: 6,
      oraclePairId: 6002,
      maxAmount: ethers.parseEther("10000")
    }
  }
  }
  


    
  
  
  // Use a fixed address instead of getAccount(1)
  const owner = "0x51a3faa325787dDD9a5EB1Dc996471A4051Ac51D";

  // ================================================================
  // Deploy Core Infrastructure Contracts
  // ================================================================
  
  // 1. Security Module - handles access control and emergency procedures
  const securityModule = m.contract("SecurityModule", [
     owner, // Initial guardian is the deployer
  ]);

  // 2. Asset Registry - manages supported asset definitions
  const assetRegistry = m.contract("AssetRegistry");

  // 3. Oracle - provides price data (updated to use Supra)
  const oracle = m.contract("Oracle", 
    [deployParams.supraOracleAddress, securityModule],
  );

  // 4. Event Emitter - centralizes event emission
  const eventEmitter = m.contract("EventEmitter", 
    [securityModule],
  );

  // ================================================================
  // Deploy Financial Infrastructure Contracts
  // ================================================================
  
  // 5. OLPVault - securely stores assets
  const olpvault = m.contract("Vault", [securityModule]);




  // 6. Insurance Fund - covers losses from liquidations
  // Using fully qualified name to avoid ambiguity
  const insuranceFund = m.contract("contracts/InsuranceFund.sol:InsuranceFund", [securityModule]);

  // 7. Risk Manager - handles risk parameters
  const riskManager = m.contract("RiskManager",
     [assetRegistry, oracle],
  );

  // 8. Token Manager - handles synthetic tokens issuance and management
  const tokenManager = m.contract("TokenManager",
    [assetRegistry],
  );

  // 9. Fee Manager - manages fee collection and distribution
  const feeManager = m.contract("FeeManager", 
     [owner, securityModule], // Treasury is initially the deployer
  );

  // 10. Referral Program - manages referrals and rewards
  const referralProgram = m.contract("ReferralProgram", [
    feeManager
  ]);

  // ================================================================
  // Deploy Trading Infrastructure Contracts
  // ================================================================
  
  // 11. Collateral Manager - manages trader collateral
  const collateralManagerV2 = m.contract("CollateralManager",
    [securityModule, feeManager, olpvault],
  );

  // 12. EnhancedOrderbook - for order matching
  const orderbook = m.contract("EnhancedOrderBook", 
    [assetRegistry, eventEmitter, securityModule],
  );

  // 13. Funding Rate Manager - manages funding rates for perpetuals
  const fundingRateManager = m.contract("FundingRateManager", 
    [assetRegistry, oracle, securityModule],
  );

    // 14. Cross-Margin Account Manager - manages portfolio margin
    const crossMarginAccount = m.contract("CrossMarginAccountManager", [
      collateralManagerV2,
      assetRegistry,
      oracle,
      riskManager,
    ],
  );


  // 15. Market - core trading contract
  const market = m.contract("Market", [
      assetRegistry,
      orderbook,
      oracle,
      securityModule,
      collateralManagerV2,
      crossMarginAccount,
      fundingRateManager,
      eventEmitter,
    ],
  );


  // 16. Position Manager - handles position lifecycle
  const positionManager = m.contract("PositionManager", [
      market,
      collateralManagerV2,
      assetRegistry,
      oracle,
      feeManager,
      riskManager,
    ],
  );

  // 17. Liquidation Engine - handles liquidations
  const liquidationEngine = m.contract("LiquidationEngine", [
      market,
      collateralManagerV2,
      assetRegistry,
      oracle,
      securityModule,
      insuranceFund,
    ],
  );

  // 18. Order Executor - executes stop-loss and take-profit orders
  const orderExecutor = m.contract("OrderExecutor", [
      market,
      securityModule,
      assetRegistry,
      oracle,
      positionManager,
    ],
  );

  // 19. Clearing House - handles settlement and clearing of trades
  const clearingHouse = m.contract("ClearingHouse", [
      market,
      collateralManagerV2,
      feeManager,
      oracle,
      riskManager,
      insuranceFund,
    ],
  );

  //20. OMNITOKEN - ERC20 token for the protocol
  const omniToken = m.contract("OMNIToken", [
    owner, // Initial owner is the deployer

  ]);

  // 21. OMNIStaking - staking contract for OMNIToken
  const omniStaking = m.contract("OMNIStaking", [
      omniToken,
      owner,
    ],
  );

  //22. FeeDistributor - distributes fees to stakers
  const feeDistributor = m.contract("FeeDistributor", [
      omniToken,
      omniStaking,
      owner,
      insuranceFund,
      owner,
    ],
  );


  // ================================================================
  // Configure Contract Connections
  // ================================================================
  
  // Connect TokenManager to CollateralManager
  m.call(collateralManagerV2, "updateTokenManager", [tokenManager], { id: "collateralManager_updateTokenManager" });
  
  // Update Treasury Management 
  m.call(feeManager, "setInsuranceFund", [insuranceFund], { id: "feeManager_setInsuranceFund" });
  m.call(feeManager, "setReferralProgram", [referralProgram], { id: "feeManager_setReferralProgram" });
  m.call(feeManager, "setInsuranceFundFee", [deployParams.insuranceFundFee], { id: "feeManager_setInsuranceFundFee" });

  // Update Market with Cross-Margin Account
  m.call(crossMarginAccount, "setMarket", [market], { id: "crossMarginAccount_setMarket" });

  // Set Position Manager in Market
  m.call(market, "setPositionManager", [positionManager], { id: "market_setPositionManager" });

  // Set Liquidation Engine in Market
  m.call(market, "setLiquidationEngine", [liquidationEngine], { id: "market_setLiquidationEngine" });

  // Set Collateral Manager in Vault
  m.call(olpvault, "setCollateralManager", [collateralManagerV2], { id: "vault_setCollateralManager" });

  // // Configure Risk Manager defaults
  m.call(riskManager, "setMaxGlobalOpenInterest", [ethers.parseEther("10")], { id: "riskManager_setMaxGlobalOpenInterest" });
  m.call(riskManager, "setMaxPositionSize", [ethers.parseEther("1")], { id: "riskManager_setMaxPositionSize" });
  m.call(riskManager, "setGlobalUtilizationLimit", [80], { id: "riskManager_setGlobalUtilizationLimit" });
  
  // Configure Permissions
  m.call(securityModule, "addOperator", [orderbook], { id: "securityModule_addOperator_orderbook" });
  m.call(securityModule, "addOperator", [market], { id: "securityModule_addOperator_market" });
  m.call(securityModule, "addOperator", [positionManager], { id: "securityModule_addOperator_positionManager" });
  m.call(securityModule, "addOperator", [liquidationEngine], { id: "securityModule_addOperator_liquidationEngine" });
  m.call(securityModule, "addOperator", [orderExecutor], { id: "securityModule_addOperator_orderExecutor" });
  // m.call(securityModule, "addOperator", [clearingHouse], { id: "securityModule_addOperator_clearingHouse" });
  m.call(securityModule, "addOperator", [tokenManager], { id: "securityModule_addOperator_tokenManager" });
  
  m.call(eventEmitter, "addAuthorizedEmitter", [orderbook], { id: "eventEmitter_addAuthorizedEmitter_orderbook" });
  m.call(eventEmitter, "addAuthorizedEmitter", [market], { id: "eventEmitter_addAuthorizedEmitter_market" });
  m.call(eventEmitter, "addAuthorizedEmitter", [liquidationEngine], { id: "eventEmitter_addAuthorizedEmitter_liquidationEngine" });
  // m.call(eventEmitter, "addAuthorizedEmitter", [clearingHouse], { id: "eventEmitter_addAuthorizedEmitter_clearingHouse" });

  // Configure InsuranceFund permissions
  m.call(insuranceFund, "addAuthorizedUser", [liquidationEngine], { id: "insuranceFund_addAuthorizedUser_liquidationEngine" });
  m.call(insuranceFund, "addAuthorizedUser", [market], { id: "insuranceFund_addAuthorizedUser_market" });
  // m.call(insuranceFund, "addAuthorizedUser", [clearingHouse], { id: "insuranceFund_addAuthorizedUser_clearingHouse" });

  // Configure Liquidation permissions
  m.call(securityModule, "addLiquidator", [owner], { id: "securityModule_addLiquidator_owner" });
  
  // // ================================================================
  // // Register and Configure Synthetic Assets
  // // ================================================================
  
  // Create array for oracle configuration
  const oraclePairKeys = [];
  const oraclePairIds = [];
  
  // // Register all synthetic assets
  for (const [symbol, assetInfo] of Object.entries(deployParams.syntheticAssets)) {
    // 1. Register asset in AssetRegistry
    m.call(assetRegistry, "registerAsset", [
      symbol,                   // Symbol
      `${symbol}/USD`,         // Oracle feed key
      assetInfo.decimals       // Decimals
    ], { id: `assetRegistry_registerAsset_${symbol}` });
    
    // 2. Register synthetic token in TokenManager
    m.call(tokenManager, "registerSyntheticToken", [
      symbol,                  // Symbol
      assetInfo.decimals       // Decimals
    ], { id: `tokenManager_registerSyntheticToken_${symbol}` });
    
    // 3. Set risk parameters for the asset
    m.call(riskManager, "setAssetMaxLeverage", [
      symbol, 
      deployParams.maxLeverage
    ], { id: `riskManager_setAssetMaxLeverage_${symbol}` });
    
    m.call(riskManager, "setAssetMaxOI", [
      symbol, 
      assetInfo.maxAmount
    ], { id: `riskManager_setAssetMaxOI_${symbol}` });
    
    m.call(riskManager, "setAssetTradeEnabled", [
      symbol, 
      true
    ], { id: `riskManager_setAssetTradeEnabled_${symbol}` });
    
    // 4. Add to oracle pair configuration arrays
    oraclePairKeys.push(`${symbol}/USD`);
    oraclePairIds.push(assetInfo.oraclePairId);
    
    // 5. Add spot market
    m.call(market, "addMarket", [
      symbol,                         // Asset symbol
      0,                              // MarketType.Spot (0 for Spot, 1 for Perpetual)
      deployParams.maxLeverage,       // Max leverage
      assetInfo.maxAmount,            // Max position size
      deployParams.takerFee,          // Taker fee in basis points
      deployParams.makerFee,          // Maker fee in basis points
      ethers.parseEther("0.001")      // Min order size
    ], { id: `market_addMarket_spot_${symbol}` });
    
    // 6. Add perpetual market for the same asset
    m.call(market, "addMarket", [
      `${symbol}-PERP`,               // Asset symbol with PERP suffix
      1,                              // MarketType.Perpetual (1)
      deployParams.maxLeverage,       // Max leverage
      assetInfo.maxAmount,            // Max position size
      deployParams.takerFee,          // Taker fee in basis points
      deployParams.makerFee,          // Maker fee in basis points
      ethers.parseEther("0.001")      // Min order size
    ], { id: `market_addMarket_perp_${symbol}` });
    
    // 7. Set max skew for this market
    m.call(market, "setMaxSkew", [
      symbol, 
      deployParams.maxSkew
    ], { id: `market_setMaxSkew_${symbol}` });
    
    m.call(market, "setMaxSkew", [
      `${symbol}-PERP`, 
      deployParams.maxSkew
    ], { id: `market_setMaxSkew_${symbol}_PERP` });
  }
  
  // Configure Oracle pair mappings for Supra
  m.call(oracle, "batchSetPairMapping", [
    oraclePairKeys,
    oraclePairIds
  ], { id: "oracle_batchSetPairMapping" });
  
  // // ================================================================
  // // Configure Gas Optimization Parameters
  // // ================================================================
  
  // Configure funding rate parameters for more gas-efficient updates
  m.call(fundingRateManager, "updateFundingParams", [
    8 * 3600,   // 8 hours funding interval
    25,         // 0.25% max rate per interval (scaled by 1e-4)
    1           // 0.01% interest rate per interval (scaled by 1e-4)
  ], { id: "fundingRateManager_updateFundingParams" });
  
  // Set more gas-efficient update parameters
  m.call(fundingRateManager, "updateFundingEMAPeriods", [6], { id: "fundingRateManager_updateFundingEMAPeriods" });
  m.call(fundingRateManager, "updateDampeningFactor", [80], { id: "fundingRateManager_updateDampeningFactor" });
  m.call(fundingRateManager, "updateMaxRateChangePercent", [25], { id: "fundingRateManager_updateMaxRateChangePercent" });
  
  // Configure vault withdrawal parameters for gas efficiency
  m.call(olpvault, "updateWithdrawalParameters", [
    24 * 3600,  // 24 hour delay
    5,          // 0.05% fee for fast withdrawals
    ethers.parseEther("100")  // 100 ETH daily limit
  ], { id: "vault_updateWithdrawalParameters" });
  
  // Set oracle parameters for efficient price feeds
  m.call(oracle, "setTWAPInterval", [3600], { id: "oracle_setTWAPInterval" }); // 1 hour TWAP
  m.call(oracle, "setMaxPricePoints", [6], { id: "oracle_setMaxPricePoints" }); // Keep 6 price points
  m.call(oracle, "setMaxPriceDeviation", [300], { id: "oracle_setMaxPriceDeviation" }); // 3% max deviation
  
  // ================================================================
  // Return All Deployed Contracts
  // ================================================================
  
  return {
    // Core Infrastructure
    securityModule,
    assetRegistry,
    oracle,
    eventEmitter,
    
    // Financial Infrastructure
    olpvault,
    insuranceFund,
    riskManager,
    tokenManager,
    feeManager,
    referralProgram,
    
   // Trading Infrastructure
    collateralManagerV2,
    orderbook,
    fundingRateManager,
    market,
    crossMarginAccount,
    positionManager,
    liquidationEngine,
    orderExecutor,
    clearingHouse,
    omniToken,
    omniStaking,
    feeDistributor
  };
}); 