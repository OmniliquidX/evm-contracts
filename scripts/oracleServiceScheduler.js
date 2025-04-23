/**
 * Oracle Service Scheduler for Omniliquid
 * 
 * This service runs as a daemon to periodically execute oracle updates
 * using Supra Oracle's REST API.
 */

const { main: updateOracle } = require('./oracleUpdater');
const fs = require('fs');
const dotenv = require('dotenv');

dotenv.config();

// Service configuration
const CONFIG = {
  // Update interval (ms)
  updateInterval: parseInt(process.env.UPDATE_INTERVAL || '60000'), // 1 minute by default
  
  // Log file
  logFile: process.env.LOG_FILE || './oracle-updates.log',
};

// Create a logging system that writes to both console and file
function setupLogging() {
  // Create a write stream to the log file
  const logStream = fs.createWriteStream(CONFIG.logFile, { flags: 'a' });
  
  // Store original console methods
  const originalConsoleLog = console.log;
  const originalConsoleError = console.error;
  const originalConsoleWarn = console.warn;
  
  // Override console.log
  console.log = function(...args) {
    const message = `[${new Date().toISOString()}] INFO: ${args.join(' ')}`;
    originalConsoleLog(message);
    logStream.write(message + '\n');
  };
  
  // Override console.error
  console.error = function(...args) {
    const message = `[${new Date().toISOString()}] ERROR: ${args.join(' ')}`;
    originalConsoleError(message);
    logStream.write(message + '\n');
  };
  
  // Override console.warn
  console.warn = function(...args) {
    const message = `[${new Date().toISOString()}] WARN: ${args.join(' ')}`;
    originalConsoleWarn(message);
    logStream.write(message + '\n');
  };
  
  return logStream;
}

/**
 * Main service function
 */
async function startService() {
  try {
    // Setup logging
    const logStream = setupLogging();
    
    console.log('Starting Oracle Service Scheduler');
    console.log(`Update interval: ${CONFIG.updateInterval}ms`);
    console.log(`Logging to: ${CONFIG.logFile}`);
    
    // Stats tracking
    let updateCount = 0;
    let successCount = 0;
    let failureCount = 0;
    let startTime = Date.now();
    
    // Perform initial update
    console.log('Performing initial update...');
    try {
      await updateOracle();
      successCount++;
      console.log('Initial update completed successfully');
    } catch (error) {
      failureCount++;
      console.error('Initial update failed:', error.message);
    }
    
    updateCount++;
    
    // Schedule regular updates
    console.log(`Scheduling regular updates every ${CONFIG.updateInterval / 1000} seconds`);
    const interval = setInterval(async () => {
      try {
        console.log('Performing scheduled update...');
        await updateOracle();
        successCount++;
        console.log('Scheduled update completed successfully');
      } catch (error) {
        failureCount++;
        console.error('Scheduled update failed:', error.message);
      }
      
      updateCount++;
      
      // Log statistics every 10 updates
      if (updateCount % 10 === 0) {
        const uptime = Math.floor((Date.now() - startTime) / 1000);
        const successRate = ((successCount / updateCount) * 100).toFixed(2);
        
        console.log('------- Service Statistics -------');
        console.log(`Uptime: ${uptime} seconds`);
        console.log(`Total updates: ${updateCount}`);
        console.log(`Successful updates: ${successCount}`);
        console.log(`Failed updates: ${failureCount}`);
        console.log(`Success rate: ${successRate}%`);
        console.log('----------------------------------');
      }
    }, CONFIG.updateInterval);
    
    // Handle graceful shutdown
    function shutdown() {
      console.log('Received shutdown signal. Stopping service...');
      
      // Clear the interval
      clearInterval(interval);
      
      // Log final statistics
      const uptime = Math.floor((Date.now() - startTime) / 1000);
      const successRate = ((successCount / updateCount) * 100).toFixed(2);
      
      console.log('------- Final Service Statistics -------');
      console.log(`Uptime: ${uptime} seconds`);
      console.log(`Total updates: ${updateCount}`);
      console.log(`Successful updates: ${successCount}`);
      console.log(`Failed updates: ${failureCount}`);
      console.log(`Success rate: ${successRate}%`);
      console.log('----------------------------------------');
      
      // Close log stream
      logStream.end();
      
      // Exit process
      process.exit(0);
    }
    
    // Register shutdown handlers
    process.on('SIGINT', shutdown);
    process.on('SIGTERM', shutdown);
    
    console.log('Service started successfully');
  } catch (error) {
    console.error(`Failed to start Oracle Service Scheduler: ${error.message}`);
    process.exit(1);
  }
}

// Run the service
if (require.main === module) {
  startService().catch(error => {
    console.error(`Unhandled error in main process: ${error.message}`);
    process.exit(1);
  });
}

module.exports = {
  startService
};