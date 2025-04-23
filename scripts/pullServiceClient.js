const axios = require('axios');

/**
 * Supra Oracle Pull Service Client
 * Client for interacting with Supra Oracle REST API
 */
class PullServiceClient {
  constructor(baseURL) {
    this.client = axios.create({
      baseURL: baseURL,
    });
  }
  
  async getProof(request) {
    try {
      const response = await this.client.post('/get_proof', request);
      return response.data;
    } catch (error) {
      throw error;
    }
  }
}

module.exports = PullServiceClient;