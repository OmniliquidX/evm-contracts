import { HardhatUserConfig } from "hardhat/config";
import "@nomicfoundation/hardhat-toolbox";
import "@nomicfoundation/hardhat-ignition";
import "@nomicfoundation/hardhat-verify";
import * as dotenv from "dotenv";

dotenv.config();

// Load environment variables
const PRIVATE_KEY = process.env.PRIVATE_KEY || "0000000000000000000000000000000000000000000000000000000000000000";


// RPC URLs
const PHAROS_DEVNET = process.env.PHAROS_DEVNET || "https://devnet.dplabs-internal.com";

const config: HardhatUserConfig = {
  solidity: {
    version: "0.8.20",
    settings: {
      optimizer: {
        enabled: true,
        runs: 200,
      },
      viaIR: true,
    },
  },
  networks: {
    // Testnet networks
    pharosDevnet: {
      url: PHAROS_DEVNET,
      accounts: [PRIVATE_KEY],
      chainId: 50002,
      gas: 3000000000,         // Very high gas limit
      gasMultiplier: 1.5,    // Additional buffer
      timeout: 18000000       // 3 minutes timeout
    },
    // Local network
    hardhat: {
      chainId: 31337,
    },
  },
  etherscan: {
    apiKey: {
      pharosDevnet: "abc",
    }, customChains: [
      {
        network: "pharosDevnet",
        chainId: 50002,
        urls: {
          apiURL: "https://pharosscan.xyz/api",
          browserURL: "https://pharosscan.xyz/",
        }
      }
    ],
  },
  sourcify: {
    enabled: true
  },
  paths: {
    sources: "./contracts",
    tests: "./test",
    cache: "./cache",
    artifacts: "./artifacts",
    ignition: "./ignition",
  },
  mocha: {
    timeout: 40000,
  },
};

export default config;