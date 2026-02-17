# Deployment Scripts

This directory contains deployment scripts for the GeoChain Prediction Market contracts.

## Scripts

### deployMarketFactory.s.sol

Deploys the `MarketFactory` contract with specified collateral token.

## Prerequisites

1. **Foundry** installed
2. **Environment variables** configured (see `.env.example`)
3. **Collateral token** deployed (e.g., USDC)
4. **Funded account** with native gas tokens

## Environment Setup

Create a `.env` file in the project root:

```bash
cp .env.example .env
```

Required variables:
```
PRIVATE_KEY=your_private_key_here
RPC_URL=https://eth-mainnet.alchemyapi.io/v2/YOUR_KEY
ETHERSCAN_API_KEY=your_etherscan_api_key
COLLATERAL_TOKEN_ADDRESS=0x... # USDC or other ERC20 address
```

> [!WARNING]
> Never commit `.env` file to git. It contains sensitive information.

## Deployment Commands

### Local Deployment (Anvil)

```bash
# Start local node
anvil

# Deploy (in another terminal)
forge script script/deployMarketFactory.s.sol --rpc-url http://localhost:8545 --broadcast
```

### Testnet Deployment

#### Sepolia

```bash
forge script script/deployMarketFactory.s.sol \
    --rpc-url $RPC_URL \
    --broadcast \
    --verify \
    -vvvv
```

#### Goerli

```bash
forge script script/deployMarketFactory.s.sol \
    --rpc-url $GOERLI_RPC_URL \
    --broadcast \
    --verify \
    -vvvv
```

### Mainnet Deployment

> [!CAUTION]
> Mainnet deployment is permanent and irreversible. Double-check all parameters.

```bash
# Dry run first (simulation)
forge script script/deployMarketFactory.s.sol \
    --rpc-url $MAINNET_RPC_URL \
    -vvvv

# Actual deployment
forge script script/deployMarketFactory.s.sol \
    --rpc-url $MAINNET_RPC_URL \
    --broadcast \
    --verify \
    --legacy \
    -vvvv
```

## Script Flags Explained

- `--rpc-url`: RPC endpoint URL
- `--broadcast`: Actually send transactions (omit for simulation)
- `--verify`: Verify contracts on Etherscan
- `--legacy`: Use legacy transaction type (for some L2s)
- `-vvvv`: Maximum verbosity for debugging

## Post-Deployment

### 1. Verify Deployment

After deployment, verify the contract on Etherscan:

```bash
forge verify-contract \
    --chain-id 1 \
    --compiler-version v0.8.20 \
    --optimizer-runs 200 \
    CONTRACT_ADDRESS \
    src/MarketFactory.sol:MarketFactory \
    --constructor-args $(cast abi-encode "constructor(address)" COLLATERAL_ADDRESS)
```

### 2. Create First Market

```solidity
// Example: Create a market
MarketFactory factory = MarketFactory(DEPLOYED_ADDRESS);

// Approve USDC spending
IERC20(usdc).approve(address(factory), 10000e6);

// Create market
address market = factory.createMarket(
    "Will ETH be above $5000 on Dec 31, 2024?",
    1704067200,  // closeTime (Unix timestamp)
    1704153600,  // resolutionTime (Unix timestamp)
    10000e6      // initialLiquidity (10,000 USDC)
);
```

### 3. Save Deployment Addresses

Record deployed addresses in a file:

```json
{
  "network": "mainnet",
  "timestamp": "2024-01-01T00:00:00Z",
  "deployer": "0x...",
  "contracts": {
    "MarketFactory": "0x...",
    "collateralToken": "0x..." 
  }
}
```

## Testing Deployment Locally

Before deploying to live networks, test the deployment script locally:

```bash
# Start anvil
anvil

# Run deployment script
forge script script/deployMarketFactory.s.sol \
    --rpc-url http://localhost:8545 \
    --broadcast

# Interact with deployed contracts
cast call DEPLOYED_ADDRESS "collateral()" --rpc-url http://localhost:8545
```

## Common Issues

### "Insufficient funds"

Your account doesn't have enough native tokens for gas. Fund it from a faucet or exchange.

### "Nonce too low"

Reset your account nonce or wait for pending transactions to confirm.

### "Contract verification failed"

- Check compiler version matches
- Verify constructor arguments are correct
- Ensure source code is identical

### "Transaction underpriced"

Increase gas price:
```bash
--with-gas-price 50000000000  # 50 gwei
```

## Security Checklist

Before deploying to mainnet:

- [ ] All tests pass (`forge test`)
- [ ] Static analysis clean (`aderyn ./src`)
- [ ] Contracts professionally audited
- [ ] Multi-sig wallet prepared for ownership
- [ ] Deployment parameters reviewed
- [ ] Gas price is reasonable
- [ ] Emergency procedures documented
- [ ] Team notified of deployment

## Network Configurations

### Mainnet
- Chain ID: 1
- RPC: `https://eth-mainnet.alchemyapi.io/v2/YOUR_KEY`
- Explorer: `https://etherscan.io`

### Sepolia
- Chain ID: 11155111
- RPC: `https://eth-sepolia.g.alchemy.com/v2/YOUR_KEY`
- Explorer: `https://sepolia.etherscan.io`
- Faucet: `https://sepoliafaucet.com`

### Goerli (Deprecated)
- Chain ID: 5
- RPC: `https://eth-goerli.alchemyapi.io/v2/YOUR_KEY`
- Explorer: `https://goerli.etherscan.io`

### Arbitrum One
- Chain ID: 42161
- RPC: `https://arb1.arbitrum.io/rpc`
- Explorer: `https://arbiscan.io`

### Optimism
- Chain ID: 10
- RPC: `https://mainnet.optimism.io`
- Explorer: `https://optimistic.etherscan.io`

## Gas Estimation

Approximate gas costs (at 20 gwei):

- **MarketFactory deployment**: ~1,500,000 gas (~0.03 ETH)
- **PredictionMarket deployment**: ~3,500,000 gas (~0.07 ETH)
- **Create market**: ~3,800,000 gas (~0.076 ETH)

Total for factory + first market: ~0.18 ETH

## Upgradability Note

Current contracts are **NOT upgradeable**. Once deployed, they cannot be modified.

For future upgradability, consider:
- UUPS proxy pattern
- Transparent proxy pattern
- Multi-sig governance

---

**Need Help?** Open an issue or consult the [Foundry Book](https://book.getfoundry.sh/).
