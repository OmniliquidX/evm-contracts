const { ethers } = require('ethers');
require('dotenv').config();

/**
 * Synthetic Trading Example Script for Omniliquid
 * 
 * This script demonstrates how to interact with the Omniliquid protocol
 * for synthetic token trading on Pharos devnet, including:
 * 
 * 1. Depositing ETH collateral
 * 2. Opening spot and perpetual positions
 * 3. Managing orders and positions
 * 4. Checking balances and profit/loss
 */

// Load contract ABIs
const PositionManager = require('./artifacts/contracts/PositionManager.sol/PositionManager.json').abi;
const Market = require('./artifacts/contracts/Market.sol/Market.json').abi;
const CollateralManager = require('./artifacts/contracts/CollateralManager.sol/CollateralManager.json').abi;
const Oracle = require('./artifacts/contracts/Oracle.sol/Oracle.json').abi;
const AssetRegistry = require('./artifacts/contracts/AssetRegistry.sol/AssetRegistry.json').abi;

// Configuration - replace with your deployed addresses
const CONFIG = {
  rpcUrl: process.env.RPC_URL || 'https://pharos-rpc.dplabs-internal.com',
  privateKey: process.env.PRIVATE_KEY,
  positionManagerAddress: process.env.POSITION_MANAGER_ADDRESS,
  marketAddress: process.env.MARKET_ADDRESS,
  collateralManagerAddress: process.env.COLLATERAL_MANAGER_ADDRESS,
  oracleAddress: process.env.ORACLE_ADDRESS,
  assetRegistryAddress: process.env.ASSET_REGISTRY_ADDRESS,
};

// Helper function to format oracle price (8 decimals)
function formatPrice(price) {
  return ethers.formatUnits(price, 8);
}

// Main function
async function main() {
  try {
    console.log('Connecting to Pharos devnet...');
    
    // Set up provider and wallet
    const provider = new ethers.JsonRpcProvider(CONFIG.rpcUrl);
    const wallet = new ethers.Wallet(CONFIG.privateKey, provider);
    const userAddress = wallet.address;
    
    console.log(`Connected with wallet: ${userAddress}`);
    
    // Get ETH balance
    const ethBalance = await provider.getBalance(userAddress);
    console.log(`ETH Balance: ${ethers.formatEther(ethBalance)} ETH`);
    
    // Connect to contracts
    const positionManager = new ethers.Contract(
      CONFIG.positionManagerAddress,
      PositionManager,
      wallet
    );

    console.log('Connected to PositionManager contract', await positionManager.getAddress());

    const assetRegistry = new ethers.Contract(
      CONFIG.assetRegistryAddress,
      AssetRegistry,  
      wallet
    );
    console.log('Connected to AssetRegistry contract', await assetRegistry.getAddress());

    const displayAssets = await assetRegistry.getAllAssets();
    console.log('Assets:', displayAssets);
    
    const market = new ethers.Contract(
      CONFIG.marketAddress,
      Market,
      wallet
    );

    console.log('Connected to Market contract', market.address);
    
    const collateralManager = new ethers.Contract(
      CONFIG.collateralManagerAddress,
      CollateralManager,
      wallet
    );

    console.log('Connected to CollateralManager contract', collateralManager.address);
    
    const oracle = new ethers.Contract(
      CONFIG.oracleAddress,
      Oracle,
      wallet
    );
    
    // Step 1: Deposit ETH collateral
    const depositAmount = ethers.parseEther("0.2"); // 0.5 ETH
    
    console.log(`Depositing ${ethers.formatEther(depositAmount)} ETH as collateral...`);
    
    // Check if we need to deposit
    const existingCollateral = await collateralManager.getAvailableCollateral(userAddress);
    
    if (existingCollateral < depositAmount) {
      // Deposit collateral
      const depositTx = await collateralManager.depositCollateral({
        value: depositAmount,
        gasLimit: 300000
      });
      
      await depositTx.wait();
      console.log(`✅ Collateral deposited successfully`);
    } else {
      console.log(`✅ Already have sufficient collateral: ${ethers.formatEther(existingCollateral)} ETH`);
    }
    
    // Step 2: Get current prices for assets
    console.log("\nFetching current asset prices...");
    
    // const checkPrice = async (symbol) => {
    //   try {
    //     const [price, timestamp] = await oracle.getPrice(`${symbol}/USD`);
    //     const formattedPrice = formatPrice(price);
    //     const date = new Date(Number(timestamp) * 1000);
        
    //     console.log(`- ${symbol}: $${formattedPrice} (Updated: ${date.toLocaleString()})`);
    //     return { symbol, price, timestamp };
    //   } catch (error) {
    //     console.log(`- ${symbol}: Error fetching price - ${error.message}`);
    //     return null;
    //   }
    // };
    
    // Check prices for key assets
    // await checkPrice("BTC");
    // await checkPrice("ETH");
    // await checkPrice("AAPL");
    // const teslaPriceData = await checkPrice("TSLA");
    
    // // Step 3: Open a spot position in TSLA
    // if (teslaPriceData)
      
      // {
      console.log(`\nOpening a spot position in BTC...`);
      
      const collateralAmount = ethers.parseEther("0.3"); // 0.05 ETH as collateral
      const leverage = 1; // 1x for spot
      const isLong = true; // Going long
      
      try {
        const openTx = await positionManager.openLeveragedPosition(
          "BTC",
          collateralAmount,
          leverage,
          isLong,
          { gasLimit: 5000000 }
        );
        
        const receipt = await openTx.wait();
        console.log(`✅ Spot position opened successfully. Gas used: ${receipt.gasUsed}`);
        
        // Find position ID from events
        let positionId = null;
        
        // First, check if the market emitted the event directly
        for (const log of receipt.logs) {
          try {
            const event = market.interface.parseLog({
              topics: log.topics,
              data: log.data
            });
            
            if (event && event.name === 'PositionOpened') {
              positionId = event.args[0]; // First parameter should be position ID
              console.log(`Position ID: ${positionId}`);
              break;
            }
          } catch (e) {
            // Not the event we're looking for
          }
        }
        
        if (positionId) {
          // Step 4: Add stop loss and take profit
          console.log("\nAdding stop loss and take profit orders...");
          
          // Calculate stop loss and take profit prices (10% below and 20% above)
          const currentPrice = teslaPriceData.price;
          const stopLossPrice = currentPrice * 9n / 10n; // 10% below
          const takeProfitPrice = currentPrice * 12n / 10n; // 20% above
          
          // Add stop loss
          const stopLossTx = await positionManager.addStopLoss(
            positionId,
            stopLossPrice,
            { gasLimit: 300000 }
          );
          await stopLossTx.wait();
          console.log(`✅ Stop loss added at $${formatPrice(stopLossPrice)}`);
          
          // Add take profit
          const takeProfitTx = await positionManager.addTakeProfit(
            positionId,
            takeProfitPrice,
            { gasLimit: 300000 }
          );
          await takeProfitTx.wait();
          console.log(`✅ Take profit added at $${formatPrice(takeProfitPrice)}`);
          
          // Step 5: Check position details
          console.log("\nPosition details:");
          const posDetails = await market.getPositionDetails(positionId);
          
          console.log(`- Asset: ${posDetails[1]}`);
          console.log(`- Amount: ${ethers.formatEther(posDetails[2])}`);
          console.log(`- Entry Price: $${formatPrice(posDetails[3])}`);
          console.log(`- Type: ${posDetails[4] ? "Long" : "Short"}`);
          console.log(`- Status: ${posDetails[5] ? "Open" : "Closed"}`);
          
          // Get liquidation price
          try {
            const liquidationPrice = await market.getLiquidationPrice(positionId);
            console.log(`- Liquidation Price: $${formatPrice(liquidationPrice)}`);
          } catch (error) {
            console.log(`- Liquidation Price: Error - ${error.message}`);
          }
          
          // Step 6: Open a perpetual position in ETH
          console.log("\nOpening a perpetual position in ETH...");
          
          const perpCollateral = ethers.parseEther("0.1"); // 0.1 ETH
          const perpLeverage = 5; // 5x leverage
          const perpIsLong = false; // Going short
          
          const perpTx = await positionManager.openLeveragedPosition(
            "ETH-PERP",
            perpCollateral,
            perpLeverage,
            perpIsLong,
            { gasLimit: 600000 }
          );
          
          const perpReceipt = await perpTx.wait();
          console.log(`✅ Perpetual position opened successfully. Gas used: ${perpReceipt.gasUsed}`);
          
          // Step 7: Check collateral balance
          const remainingCollateral = await collateralManager.getAvailableCollateral(userAddress);
          console.log(`\nRemaining available collateral: ${ethers.formatEther(remainingCollateral)} ETH`);
          
          // Step 8: Show how to close a position (commented out for demo)
          console.log("\nTo close positions, use:");
          console.log(`await market.closePosition(${positionId}, { gasLimit: 500000 });`);
        }
      } catch (error) {
        console.error(`❌ Error opening position: ${error.message}`);
        
        // Get a more detailed error if possible
        if (error.data) {
          console.error(`Error data: ${error.data}`);
        }
      }
    // }
    
    console.log("\nScript execution completed.");
  } catch (error) {
    console.error(`❌ Unhandled error: ${error.message}`);
  }
}

// Execute the main function
if (require.main === module) {
  main()
    .then(() => process.exit(0))
    .catch(error => {
      console.error(error);
      process.exit(1);
    });
}

module.exports = {
  main
};