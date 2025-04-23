/**
 * Oracle Updater for Omniliquid with Supra Oracle
 * 
 * This implementation follows the guide provided by Supra.
 */
const PullServiceClient = require('./pullServiceClient');
const { ethers } = require('ethers');
const fs = require('fs');
const dotenv = require('dotenv');

dotenv.config();

// Load Oracle ABI
const oracleAbi = require('./artifacts/contracts/Oracle.sol/Oracle.json').abi;

// Configuration
const config = {
  // REST API server address
  restApiServer: process.env.SUPRA_REST_SERVER || 'https://rpc-testnet-dora-2.supra.com',
  chainType: 'evm',
  
  // Blockchain connection
  rpcUrl: process.env.RPC_URL || 'https://devnet.dplabs-internal.com',
  contractAddress: process.env.ORACLE_ADDRESS,
  walletAddress: process.env.WALLET_ADDRESS,
  privateKey: process.env.PRIVATE_KEY,
  
  // Pair IDs to fetch
  pairIndexes: [0, 1, 10, 5000, 5002, 5500, 5501, 6000, 6001, 6002],
  
  // Gas parameters
  gasPrice: process.env.GAS_PRICE || '5000000000', // 5 Gwei
  
  // For decoding proof data
  oracleProofAbiPath: './resources/oracleProof.json'
};

/**
 * Main function to fetch price data and update the Oracle contract
 */
async function main() {
  try {
    // Create client for Supra Oracle REST API
    const client = new PullServiceClient(config.restApiServer);
    
    // Prepare request
    const request = {
      pair_indexes: config.pairIndexes,
      chain_type: config.chainType
    };
    
    console.log("Requesting proof for price indexes:", request.pair_indexes);
    
    // Fetch the proof
    client.getProof(request)
      .then(response => {
        console.log('Proof received successfully');
        callContract(response);
      })
      .catch(error => {
        console.error('Error fetching proof:', error?.response?.data || error.message);
      });
    
  } catch (error) {
    console.error('Error in main function:', error.message);
  }
}

/**
 * Calls the Oracle contract with the proof data
 * @param {Object} response - Response from the Supra Oracle API
 */
async function callContract(response) {
  try {
    // Connect to provider
    const provider = new ethers.JsonRpcProvider(config.rpcUrl);
    const wallet = new ethers.Wallet(config.privateKey, provider);
    
    // Connect to Oracle contract
    const contract = new ethers.Contract(
      config.contractAddress,
      oracleAbi,
      wallet
    );
    
    const hex = response.proof_bytes;
    console.log(`Received proof data of ${hex.length} bytes`);
    
    // Optional: Decode and log the proof data if oracleProof.json is available
    // try {
    //   if (fs.existsSync(config.oracleProofAbiPath)) {
    //     const OracleProofABI = require(config.oracleProofAbiPath);
        
    //     // Using ethers to decode parameters
    //     const abiCoder = new ethers.AbiCoder();
    //     let proof_data = abiCoder.decode(OracleProofABI, hex);
        
    //     let pairId = [];
    //     let pairPrice = [];
    //     let pairDecimal = [];
    //     let pairTimestamp = [];
        
    //     for (let i = 0; i < proof_data[0].data.length; ++i) {
    //       for (let j = 0; j < proof_data[0].data[i].committee_data.committee_feed.length; j++) {
    //         pairId.push(proof_data[0].data[i].committee_data.committee_feed[j].pair.toString());
    //         pairPrice.push(proof_data[0].data[i].committee_data.committee_feed[j].price.toString());
    //         pairDecimal.push(proof_data[0].data[i].committee_data.committee_feed[j].decimals.toString());
    //         pairTimestamp.push(proof_data[0].data[i].committee_data.committee_feed[j].timestamp.toString());
    //       }
    //     }
        
    //     console.log("Pair indexes:", pairId);
    //     console.log("Pair Prices:", pairPrice);
    //     console.log("Pair Decimals:", pairDecimal);
    //     console.log("Pair Timestamps:", pairTimestamp);
    //   }
    // } catch (error) {
    //   console.warn('Could not decode proof data:', error.message);
    //   console.warn('Continuing with transaction...');
    // }
    
   // Convert hex string to bytes
    const bytes = ethers.toUtf8Bytes(hex);
    console.log(`Converted proof data to bytes: ${bytes.length} bytes`);
    
    // Estimate gas for updating prices
    let gasEstimate;
    try {
      gasEstimate = await contract.updatePrices.estimateGas(bytes, {
        from: wallet.address
      });
      console.log(`Gas estimate: ${gasEstimate.toString()}`);
      
      // Add 20% buffer to gas estimate
      gasEstimate = gasEstimate * 120n / 100n;
    } catch (error) {
      console.warn(`Gas estimation failed: ${error.message}`);
      console.warn('Using default gas limit of 3,000,000');
      gasEstimate = 300000000n;
    }
    
    // Get nonce for transaction
    const nonce = await provider.getTransactionCount(wallet.address);
    console.log(`Nonce for transaction: ${nonce}`);
    
    // Create the transaction
    const tx = await contract.updatePrices(bytes, 
      {
      gasLimit: gasEstimate,
      nonce: nonce
    }
  );
    
    console.log(`Transaction sent: ${tx.hash}`);
    
    // Wait for transaction confirmation
    const receipt = await tx.wait();
    
    console.log(`Transaction confirmed in block ${receipt.blockNumber}`);
    console.log(`Gas used: ${receipt.gasUsed.toString()}`);
    
    // Check for PriceUpdated events
    const priceUpdatedEvents = receipt.logs
      .filter(log => {
        try {
          const parsed = contract.interface.parseLog({
            topics: log.topics,
            data: log.data
          });
          return parsed.name === 'PriceUpdated';
        } catch (e) {
          return false;
        }
      })
      .map(log => {
        const parsed = contract.interface.parseLog({
          topics: log.topics,
          data: log.data
        });
        return {
          asset: parsed.args[0],
          price: parsed.args[1],
          timestamp: parsed.args[2]
        };
      });
    
    if (priceUpdatedEvents.length > 0) {
      console.log(`Updated prices for ${priceUpdatedEvents.length} assets:`);
      priceUpdatedEvents.forEach(event => {
        console.log(`- ${event.asset}: ${ethers.formatUnits(event.price, 8)} @ ${new Date(Number(event.timestamp) * 1000).toISOString()}`);
      });
    } else {
      console.log('No prices were updated');
    }
    
  } catch (error) {
    console.error('Error calling contract:', error.message);
  }
}

// Run main function if executed directly
if (require.main === module) {
  main().catch((error) => {
    console.error('Unhandled error:', error);
    process.exit(1);
  });
}

module.exports = {
  main,
  callContract
};