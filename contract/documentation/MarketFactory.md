# Market Factory Contract

An upgradeable UUPS proxy factory that creates, registers, and manages prediction markets across multiple chains with cross-chain synchronization via Chainlink CCIP.

## Architecture Overview

The MarketFactory contract is composed through modular inheritance:

```
MarketFactory
    └── MarketFactoryOperations
            └── MarketFactoryCcip
                    └── MarketFactoryBase
                            ├── UUPSUpgradeable
                            ├── ReceiverTemplateUpgradeable (CRE)
                            └── IAny2EVMMessageReceiver (CCIP)
```

## Key Features

### Market Creation & Registry
- **Clone Deployment**: Uses minimal proxies for gas-efficient market creation
- **Market Registry**: Tracks all markets by ID and address
- **Active Market List**: Dynamic list for UI/indexer queries
- **Manual Review Queue**: Markets requiring human adjudication

### Cross-Chain Communication (CCIP)
- **Hub-Spoke Model**: Hub broadcasts to all spokes
- **Price Synchronization**: Hub syncs canonical prices to spokes
- **Resolution Broadcasting**: Hub broadcasts outcomes cross-chain
- **Trusted Remotes**: Whitelisted source factories per chain selector

### Operational Actions
- **Report Processing**: CRE-driven action dispatcher
- **Price Correction**: Automated arbitrage for deviation bands
- **Collateral Management**: Factory-level liquidity operations
- **Pending Withdrawals**: Batch processing queue

### Hub/Spoke Identity
- **Hub Factory**: Originates price/resolution broadcasts
- **Spoke Factory**: Receives and applies broadcasts
- **Local Resolution**: Spokes can resolve if not in canonical mode

## State Variables

### Factory Configuration
| Variable | Type | Description |
|----------|------|-------------|
| `collateral` | IERC20 | Shared collateral token for all markets |
| `marketCount` | uint256 | Total markets created |
| `marketDeployer` | MarketDeployer | Clone deployer contract |
| `initailEventLiquidity` | uint256 | Default liquidity for new markets |

### Market Registry
| Variable | Type | Description |
|----------|------|-------------|
| `marketById` | mapping | Market address by ID |
| `marketIdByAddress` | mapping | Market ID by address |
| `activeMarkets` | address[] | List of active markets |
| `isActiveMarket` | mapping | Membership check for active markets |
| `manualReviewMarkets` | address[] | Markets awaiting manual review |
| `isManualReviewMarket` | mapping | Membership check for manual review |

### CCIP Configuration
| Variable | Type | Description |
|----------|------|-------------|
| `ccipRouter` | address | Chainlink CCIP router |
| `ccipFeeToken` | address | Token used for CCIP fees |
| `isHubFactory` | bool | Hub vs spoke identity |
| `ccipNonce` | uint64 | Outbound message nonce |
| `trustedRemoteBySelector` | mapping | Trusted factory by chain selector |
| `s_supportedChainSelector` | mapping | Allowed chain selectors |

### Withdrawal Queue
| Variable | Type | Description |
|----------|------|-------------|
| `pendingWithdrawQueue` | uint256[] | FIFO queue of market IDs |
| `pendingWithdrawHead` | uint256 | Current queue head index |
| `isPendingWithdrawQueued` | mapping | Queued status check |

### Resolution Tracking
| Variable | Type | Description |
|----------|------|-------------|
| `resolutionNonceByMarketId` | mapping | Nonce per market for resolution |
| `directPriceSyncNonceByMarketId` | mapping | Nonce for direct price sync |

## External Functions

### Initialization

#### `initialize(address _collateral, address _forwarder, address _marketDeployer, address _initialOwner)`
Proxy initializer entrypoint.
- **Requirements**: All addresses must be non-zero
- **Effects**: Wires dependencies, sets initial owner

### Market Creation

#### `createMarket(string question, uint256 closeTime, uint256 resolutionTime)`
Creates a new prediction market.
- **Requirements**: Only owner, closeTime < resolutionTime
- **Effects**: Deploys market clone, seeds liquidity, registers market

#### `setMarketDeployer(address _marketDeployer)`
Updates clone deployer address.
- **Requirements**: Only owner

### CCIP Configuration

#### `configureCCIP(address _router, address _feeToken, bool _isHub)`
Configures CCIP infrastructure.
- **Requirements**: Only owner, valid router
- **Effects**: Sets router, fee token, hub/spoke identity

#### `setTrustedRemote(uint64 selector, address factory)`
Sets trusted remote factory for a chain.
- **Requirements**: Only owner, chain supported
- **Effects**: Adds to trusted remotes list

#### `removeTrustedRemote(uint64 selector)`
Removes a trusted remote.
- **Requirements**: Only owner
- **Effects**: Removes from trusted remotes

#### `setSupportedChainSelector(uint64 selector, bool isSupported)`
Enables/disables a chain selector.
- **Requirements**: Only owner

### Cross-Chain Broadcasting

#### `broadcastCanonicalPrice(uint256 marketId, uint256 yesPriceE6, uint256 noPriceE6, uint256 validUntil)`
Broadcasts canonical prices to all spokes.
- **Requirements**: Only owner, isHubFactory
- **Effects**: Sends CCIP message to all trusted remotes

#### `broadcastResolution(uint256 marketId, Resolution outcome, string proofUrl)`
Broadcasts market resolution to all spokes.
- **Requirements**: Only owner, isHubFactory
- **Effects**: Sends CCIP message to all trusted remotes

### Operational Actions

#### `arbitrateUnsafeMarket(uint256 marketId, uint256 maxSpendCollateral, uint256 minDeviationImprovementBps)`
Corrects unsafe price deviation in a market.
- **Requirements**: Only owner, market in Unsafe band
- **Effects**: Executes arbitrage swap to improve deviation

#### `withdrawMarketFactoryCollateralAndFee(uint256 marketId)`
Withdraws LP collateral and protocol fees from a market.
- **Requirements**: Only owner, market resolved
- **Effects**: Transfers collateral and fees to factory

#### `enqueueWithdraw(uint256 marketId)`
Queues a market for deferred withdrawal.
- **Requirements**: Only owner

#### `processPendingWithdrawals(uint256 maxItems)`
Processes batch of pending withdrawals.
- **Requirements**: Only owner, maxItems > 0
- **Effects**: Processes up to maxItems from queue

#### `addLiquidityToFactory()`
Adds factory collateral as liquidity to itself.
- **Requirements**: Only owner, factory has collateral balance
- **Effects**: Mints operational liquidity

### Query Functions

#### `getMarketFactoryCollateralBalance() returns (uint256)`
Returns factory's collateral token balance.

#### `getActiveEventList() returns (address[])`
Returns all active market addresses.

#### `getManualReviewEventList() returns (address[])`
Returns markets awaiting manual review.

#### `getPendingWithdrawCount() returns (uint256)`
Returns number of markets in withdrawal queue.

#### `getPendingWithdrawAt(uint256 indexFromHead) returns (uint256)`
Returns market ID at queue position.

## Report Processing (CRE)

The factory processes CRE reports with action types:

| Action | Payload | Description |
|--------|---------|-------------|
| `createMarket` | `(string question, uint256 closeTime, uint256 resolutionTime)` | Deploys new market |
| `broadCastPrice` | `(uint256 marketId, uint256 yesPriceE6, uint256 noPriceE6, uint256 validUntil)` | Hub→spoke price sync |
| `syncSpokeCanonicalPrice` | `(uint256 marketId, uint256 yesPriceE6, uint256 noPriceE6, uint256 validUntil)` | Direct spoke price update |
| `broadCastResolution` | `(uint256 marketId, Resolution outcome, string proofUrl)` | Hub→spoke resolution |
| `mintCollateralTo` | `(address receiver, uint256 amount)` | Mints collateral to address |
| `addLiquidityToFactory` | `()` | Adds factory liquidity |
| `priceCorrection` | `(uint256 marketId, uint256 maxSpendCollateral, uint256 minDeviationImprovementBps)` | Price arbitrage |
| `WithCollatralAndFee` | `(uint256 marketId)` | Withdraw collateral + fees |
| `processPendingWithdrawals` | `(uint256 maxItems)` | Batch process queue |

## Price Correction Algorithm

When a market enters the `Unsafe` deviation band:

1. **Verification**: Confirm market is in Unsafe band
2. **Direction Selection**: Choose allowed swap direction (YES→NO or NO→YES)
3. **Spend Calculation**: Binary search for optimal collateral spend ≤ maxSpend
4. **Execution**: 
   - Mint complete sets with calculated collateral
   - Execute swap in allowed direction
5. **Validation**: Ensure deviation improved by at least minDeviationImprovementBps

## Events

| Event | Parameters |
|-------|------------|
| `MarketCreated` | marketId, market, initialLiquidity |
| `MarketFactory__LiquidityAdded` | amount |
| `CcipConfigUpdated` | router, feeToken, isHubFactory |
| `ChainSelectorSupportUpdated` | chainSelector, isSupported |
| `TrustedRemoteUpdated` | chainSelector, remoteFactory |
| `TrustedRemoteRemoved` | chainSelector |
| `CcipMessageSent` | messageId, destinationChainSelector, messageType |
| `CanonicalPriceMessageReceived` | marketId, yesPriceE6, noPriceE6, nonce |
| `ResolutionMessageReceived` | marketId, outcome, nonce |
| `UnsafeArbitrageExecuted` | market, yesForNo, collateralSpent, deviationBeforeBps, deviationAfterBps |
| `WithdrawDequeued` | marketId |
| `WithdrawRequeued` | marketId |
| `WithdrawSkippedNotResolved` | marketId |
| `WithdrawSkippedNoShares` | marketId |
| `WithdrawProcessed` | marketId |

## Error Codes

| Error | Description |
|-------|-------------|
| `MarketFactory__MarketNotFound()` | Market ID doesn't exist |
| `MarketFactory__MarketAlreadyExist()` | Market already created |
| `MarketFactory__ActionNotRecognized()` | Unknown report action |
| `MarketFactory__MarketNotActive()` | Market not in active list |
| `MarketFactory__MarketInManualReview()` | Market in review state |
| `MarketFactory__InvalidMaxBatch()` | Zero batch size |
| `MarketFactory__ArbZeroAmount()` | Zero arbitrage amount |
| `MarketFactory__ArbNotUnsafe()` | Market not in Unsafe band |
| `MarketFactory__ArbNoDirection()` | No allowed swap direction |
| `MarketFactory__ArbInsufficientImprovement()` | Deviation not improved enough |

## Integration Guide

### Deployment

1. Deploy MarketFactory proxy
2. Initialize with collateral, forwarder, deployer, owner
3. Configure CCIP router and fee token
4. Set hub/spoke identity
5. Add supported chain selectors

### Creating Markets

**Via Owner:**
```solidity
factory.createMarket("Will ETH hit $5000 by 2025?", closeTime, resolutionTime);
```

**Via CRE Report:**
```solidity
// Payload: abi.encode("createMarket", abi.encode(question, closeTime, resolutionTime))
```

### Cross-Chain Sync (Hub)

1. Wait for market resolution on hub
2. Call `broadcastCanonicalPrice()` to sync prices
3. Call `broadcastResolution()` to broadcast outcome
4. Spokes receive via `ccipReceive()`

### Cross-Chain Sync (Spoke)

1. Receive CCIP message in `ccipReceive()`
2. Verify trusted remote sender
3. Process price or resolution action
4. Update market state locally

### Managing Withdrawals

**Immediate:**
```solidity
factory.withdrawMarketFactoryCollateralAndFee(marketId);
```

**Deferred:**
```solidity
factory.enqueueWithdraw(marketId);
// Later...
factory.processPendingWithdrawals(10);
```

### Price Correction

```solidity
factory.arbitrateUnsafeMarket(marketId, maxSpend, minImprovement);
```

This will:
1. Check market is in Unsafe band
2. Execute corrective swap
3. Verify deviation improved
