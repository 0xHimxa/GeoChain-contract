# GeoChain Prediction Market Contracts

A decentralized prediction market protocol built on Ethereum, allowing users to create, trade, and resolve binary outcome markets using an automated market maker (AMM) mechanism.

## 📋 Overview

This project implements a fully decentralized prediction market where users can:
- Create binary (YES/NO) prediction markets
- Provide liquidity to earn fees
- Trade outcome tokens using a constant product AMM
- Mint and redeem complete sets
- Resolve markets and redeem winning positions

The protocol uses USDC (or any ERC20 token) as collateral and implements a constant product formula (x * y = k) for automated market making.

## 🏗️ Architecture

### Core Contracts

- **MarketFactory.sol**: Deploys and tracks new prediction markets with initial liquidity
- **PredictionMarket.sol**: Main market contract implementing AMM logic, liquidity provision, and resolution
- **OutcomeToken.sol**: ERC20 tokens representing YES and NO outcomes (6 decimals)

See [ARCHITECTURE.md](./ARCHITECTURE.md) for detailed technical documentation.

## 🚀 Getting Started

### Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation) installed
- Solidity ^0.8.20
- Git

### Installation

```bash
# Clone the repository
git clone <repository-url>
cd contracts

# Install dependencies
forge install

# Build contracts
forge build
```

### Running Tests

```bash
# Run all tests
forge test

# Run tests with verbosity
forge test -vv

# Run specific test file
forge test --match-path test/unit/PredictionMarket.t.sol

# Run fuzz tests
forge test --match-path test/statelessFuzz/predictionMarket.t.sol

# Generate gas report
forge test --gas-report

# Generate coverage report
forge coverage
```

## 📝 Usage

### Creating a Market

```solidity
// Deploy factory with USDC as collateral
MarketFactory factory = new MarketFactory(usdcAddress);

// Create a market (owner only)
address market = factory.createMarket(
    "Will ETH be above $5000 on Dec 31, 2024?",
    closeTime,      // When trading closes
    resolutionTime, // When market can be resolved
    1000e6          // Initial liquidity (1000 USDC)
);
```

### Trading on a Market

```solidity
PredictionMarket market = PredictionMarket(marketAddress);

// Mint complete sets (1 USDC → 1 YES + 1 NO token, minus fee)
usdc.approve(address(market), 100e6);
market.mintCompleteSets(100e6);

// Swap YES for NO tokens
yesToken.approve(address(market), amount);
market.swapYesForNo(amount, minNoOut);

// Add liquidity
market.addLiquidity(yesAmount, noAmount, minShares);

// Redeem complete sets back to collateral
market.redeemCompleteSets(amount);
```

### Resolving a Market

```solidity
// After resolutionTime, owner can resolve (owner only)
market.resolve(true); // true for YES, false for NO

// Winners redeem their tokens 1:1 for collateral
market.redeem(winningTokenBalance);
```

## 💡 Key Features

### Automated Market Maker (AMM)
- Constant product formula: `k = yesReserve * noReserve`
- 4% swap fee that benefits liquidity providers
- Slippage protection on all trades

### Liquidity Provision
- Earn fees by providing YES and NO tokens
- Proportional LP shares
- Add or remove liquidity at any time (before market closes)

### Fee Structure
- **Swap Fee**: 4% (stays in pool for LPs)
- **Mint Complete Sets Fee**: 3%
- **Redeem Complete Sets Fee**: 2%

### Security Features
- ReentrancyGuard on all state-changing functions
- Pausable for emergency stops
- Owner-controlled resolution
- Time-based market lifecycle (Open → Closed → Resolved)

## 🔒 Security

This codebase has been analyzed with [Aderyn](https://github.com/Cyfrin/aderyn) static analysis tool. See [report.md](./report.md) for the complete security analysis.

### Key Security Considerations

1. **Reentrancy Protection**: All external calls are protected with `nonReentrant` modifier
2. **Access Control**: Critical functions are owner-only
3. **Time Locks**: Markets can only be resolved after `resolutionTime`
4. **Slippage Protection**: All trades include minimum output parameters

See [SECURITY.md](./SECURITY.md) for responsible disclosure policy and detailed security information.

## 📊 Contract Deployment

### Environment Setup

1. Copy `.env.example` to `.env`:
```bash
cp .env.example .env
```

2. Fill in your environment variables:
```
PRIVATE_KEY=your_private_key
RPC_URL=https://eth-mainnet.alchemyapi.io/v2/your_key
ETHERSCAN_API_KEY=your_etherscan_key
COLLATERAL_TOKEN_ADDRESS=0x... # USDC or other ERC20
```

### Deploy to Network

```bash
# Deploy to testnet
forge script script/deployMarketFactory.s.sol --rpc-url $RPC_URL --broadcast --verify

# Deploy to mainnet (use with caution!)
forge script script/deployMarketFactory.s.sol --rpc-url $RPC_URL --broadcast --verify --legacy
```

See [script/README.md](./script/README.md) for detailed deployment instructions.

## 🧪 Testing

The test suite is organized into:
- **Unit Tests** (`test/unit/`): Test individual contract functions
- **Stateless Fuzz Tests** (`test/statelessFuzz/`): Property-based testing
- **Stateful Fuzz Tests** (`test/statefullFuzz/`): Invariant testing (coming soon)

See [test/README.md](./test/README.md) for detailed testing documentation.

## 🤝 Contributing

We welcome contributions! Please see [CONTRIBUTING.md](./CONTRIBUTING.md) for guidelines.

### Development Workflow

1. Create a feature branch
2. Write tests for new functionality
3. Ensure all tests pass: `forge test`
4. Run static analysis: `aderyn ./src`
5. Submit a pull request

## 📄 License

This project is licensed under the MIT License - see the LICENSE file for details.

## 🔗 Links

- **Documentation**: [ARCHITECTURE.md](./ARCHITECTURE.md)
- **Security**: [SECURITY.md](./SECURITY.md)
- **Contributing**: [CONTRIBUTING.md](./CONTRIBUTING.md)
- **Audit Report**: [report.md](./report.md)

## ⚠️ Disclaimer

This software is provided "as is", without warranty of any kind. Use at your own risk. This code has not been professionally audited and should not be used in production without thorough security review.

## 📞 Support

For questions, issues, or feedback, please open an issue on GitHub.

---

Built with ❤️ by 0xHimxa
