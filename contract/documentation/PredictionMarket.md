# Prediction Market Contract

A modular, upgradeable smart contract for binary outcome prediction markets with AMM-based trading, liquidity provision, and AI-driven resolution via Chainlink CRE.

## Architecture Overview

The PredictionMarket contract is composed through modular inheritance:

```
PredictionMarket
    └── PredictionMarketResolution
            └── PredictionMarketLiquidity
                    └── PredictionMarketBase
                            ├── PausableUpgradeable
                            ├── ReentrancyGuard
                            └── ReceiverTemplateUpgradeable (CRE)
```

## Key Features

### AMM-Based Trading
- **Constant Product AMM**: YES and NO outcome tokens trade against each other
- **Swap Fee**: 4% (400 bps) per trade
- **Price Discovery**: Implied from reserve ratios

### Liquidity Provision
- **LP Shares**: Proportional ownership of YES/NO reserves
- **Initial Seeding**: One-time bootstrap of balanced liquidity
- **Add/Remove Liquidity**: Balanced deposits and withdrawals
- **Complete Sets**: Mint/redeem equal YES+NO pairs

### Canonical Pricing & Safety
- **Deviation Bands**: Normal → Stress → Unsafe → Circuit Breaker
- **Cross-Chain Prices**: Hub-synced canonical prices via CCIP
- **Trade Controls**: Fee uplift and max output caps in stress bands
- **Arbitrage**: Owner-triggered price correction for unsafe markets

### Resolution & Disputes
- **Resolution States**: Open → Closed → Review → Resolved
- **Outcomes**: Yes, No, Inconclusive
- **Dispute Window**: 1 hour (configurable) for challenging proposed resolutions
- **Manual Review**: For inconclusive outcomes requiring human adjudication

## Contract Constants

| Constant | Value | Description |
|----------|-------|-------------|
| `SWAP_FEE_BPS` | 400 | Base swap fee in basis points (4%) |
| `MINT_COMPLETE_SETS_FEE_BPS` | 300 | Fee for minting complete sets (3%) |
| `REDEEM_COMPLETE_SETS_FEE_BPS` | 200 | Fee for redeeming complete sets (2%) |
| `FEE_PRECISION_BPS` | 10,000 | Basis point denominator (100%) |
| `MINIMUM_ADD_LIQUIDITY_SHARE` | 50 | Minimum token amount for addLiquidity |
| `MINIMUM_AMOUNT` | 1e6 | Minimum for complete set operations |
| `MINIMUM_SWAP_AMOUNT` | 970,000 | Minimum swap input amount |
| `PRICE_PRECISION` | 1e6 | Probability/price precision |
| `MAX_RISK_EXPOSURE` | 10,000e6 | Per-user exposure cap |
| `DEFAULT_DISPUTE_WINDOW` | 1 hour | Default dispute duration |

## State Variables

### Market Data
| Variable | Type | Description |
|----------|------|-------------|
| `s_question` | string | Human-readable market question |
| `s_Proof_Url` | string | Resolution proof URI |
| `i_collateral` | IERC20 | Collateral token (e.g., USDC) |
| `yesToken` | OutcomeToken | YES outcome token |
| `noToken` | OutcomeToken | NO outcome token |
| `closeTime` | uint256 | Trading close timestamp |
| `resolutionTime` | uint256 | Earliest resolution timestamp |
| `disputeWindow` | uint256 | Duration for disputes |
| `marketId` | uint256 | Factory-assigned identifier |

### AMM State
| Variable | Type | Description |
|----------|------|-------------|
| `yesReserve` | uint256 | YES token reserve in AMM |
| `noReserve` | uint256 | NO token reserve in AMM |
| `seeded` | bool | Whether initial liquidity is seeded |
| `totalShares` | uint256 | Total LP share supply |
| `lpShares` | mapping | LP shares per account |

### Resolution State
| Variable | Type | Description |
|----------|------|-------------|
| `state` | State | Market lifecycle state |
| `resolution` | Resolution | Final outcome |
| `proposedResolution` | Resolution | Pending outcome |
| `proposedProofUrl` | string | Proof for proposed outcome |
| `disputeDeadline` | uint256 | Dispute window expiry |
| `resolutionDisputed` | bool | Whether proposed outcome was disputed |
| `disputeSubmissions` | DisputeSubmission[] | All dispute submissions |

### Canonical Pricing (Cross-Chain)
| Variable | Type | Description |
|----------|------|-------------|
| `canonicalYesPriceE6` | uint256 | Hub-synced YES price (1e6) |
| `canonicalNoPriceE6` | uint256 | Hub-synced NO price (1e6) |
| `canonicalPriceValidUntil` | uint256 | Price snapshot expiry |
| `crossChainController` | address | Authorized cross-chain sender |

### Deviation Policy
| Variable | Type | Description |
|----------|------|-------------|
| `softDeviationBps` | uint16 | Normal band threshold |
| `stressDeviationBps` | uint16 | Stress band threshold |
| `hardDeviationBps` | uint16 | Circuit breaker threshold |
| `stressExtraFeeBps` | uint16 | Extra fee in stress band |
| `stressMaxOutBps` | uint16 | Max output % in stress band |
| `unsafeMaxOutBps` | uint16 | Max output % in unsafe band |

## External Functions

### Liquidity Functions

#### `seedLiquidity(uint256 amount)`
One-time bootstrap of AMM pool.
- **Requirements**: Must be called by owner, amount > 0, contract must be pre-funded
- **Effects**: Sets yesReserve = noReserve = amount, mints initial LP shares to owner

#### `addLiquidity(uint256 yesAmount, uint256 noAmount, uint256 minShares)`
Adds balanced liquidity and mints LP shares.
- **Requirements**: Both amounts >= 50, user must hold YES/NO tokens
- **Effects**: Updates reserves, mints LP shares proportionally

#### `removeLiquidity(uint256 shares, uint256 minYesOut, uint256 minNoOut)`
Burns LP shares and returns proportional YES/NO.
- **Requirements**: Shares > 0, user must have sufficient shares
- **Effects**: Updates reserves, transfers YES/NO tokens

#### `removeLiquidityAndRedeemCollateral(uint256 shares, uint256 minCollateralOut)`
Removes liquidity and redeems matched pairs to collateral.
- **Requirements**: Market must be open
- **Effects**: Withdraws proportional tokens, redeems complete sets minus fee

#### `withdrawLiquidityCollateral(uint256 shares)`
Post-resolution LP settlement (winning side only).
- **Requirements**: Market must be resolved with Yes/No outcome
- **Effects**: Transfers collateral from winning reserve

### Trading Functions

#### `swapYesForNo(uint256 yesIn, uint256 minNoOut)`
Swaps YES tokens for NO tokens.
- **Requirements**: Market open, seeded, amount >= minimum
- **Effects**: Transfers YES, outputs NO minus fee

#### `swapNoForYes(uint256 noIn, uint256 minYesOut)`
Swaps NO tokens for YES tokens.
- **Requirements**: Market open, seeded, amount >= minimum
- **Effects**: Transfers NO, outputs YES minus fee

#### `mintCompleteSets(uint256 amount)`
Deposits collateral to mint equal YES+NO tokens.
- **Requirements**: Amount >= 1e6, user must have collateral
- **Effects**: Transfers collateral, mints YES+NO tokens (minus 3% fee)

#### `redeemCompleteSets(uint256 amount)`
Burns YES+NO tokens for collateral.
- **Requirements**: User must hold equal YES and NO amounts
- **Effects**: Burns tokens, transfers collateral (minus 2% fee)

### Resolution Functions

#### `redeem(uint256 amount)`
Claims winnings after market resolution.
- **Requirements**: Market resolved, user holds winning tokens
- **Effects**: Burns winning tokens, transfers collateral

#### `setCanonicalPrice(uint256 yesPriceE6, uint256 noPriceE6, uint64 nonce, uint256 validUntil)`
Sets hub-synced canonical prices.
- **Requirements**: Only cross-chain controller can call
- **Effects**: Updates canonical prices for deviation calculations

### Query Functions

#### `getYesPriceProbability() returns (uint256)`
Returns YES outcome probability (1e6 precision).
- **Source**: Canonical price (if in canonical mode) or AMM-implied price

#### `getNoPriceProbability() returns (uint256)`
Returns NO outcome probability (1e6 precision).

#### `getYesForNoQuote(uint256 yesIn) returns (uint256 netOut, uint256 fee)`
Quotes output for YES→NO swap.

#### `getNoForYesQuote(uint256 noIn) returns (uint256 netOut, uint256 fee)`
Quotes output for NO→YES swap.

#### `getDeviationStatus() returns (...)`
Returns current deviation diagnostics including band, fees, and direction permissions.

#### `getSyncSnapshot() returns (State, uint256 yesPriceE6, uint256 noPriceE6)`
Returns market state and prices in one call.

### Admin Functions

#### `setDeviationPolicy(uint16 _soft, uint16 _stress, uint16 _hard, uint16 _stressFee, uint16 _stressMax, uint16 _unsafeMax)`
Updates canonical pricing safety parameters.
- **Requirements**: soft < stress < hard, all values <= 10000

#### `pause() / unpause()`
Pauses/unpauses market trading.

#### `withdrawProtocolFees()`
Withdraws accumulated protocol fees.
- **Requirements**: Only owner or cross-chain controller, market resolved

#### `setOutcomeTokens(address yesTokenAddress, address noTokenAddress)`
Wires pre-deployed outcome tokens.
- **Requirements**: Must be called once by owner before market activation

#### `setRiskExempt(address account, bool exempt)`
Sets risk exposure exemption.

## Events

| Event | Parameters |
|-------|------------|
| `Trade` | user, yesForNo, amountIn, amountOut |
| `Resolved` | outcome |
| `ResolutionProposed` | outcome, disputeDeadline, proofUrl |
| `ResolutionDisputed` | disputer, proposedOutcome |
| `Redeemed` | user, amount |
| `CompleteSetsMinted` | user, amount |
| `CompleteSetsRedeemed` | user, amount |
| `LiquiditySeeded` | amount |
| `LiquidityAdded` | user, yesAmount, noAmount, shares |
| `LiquidityRemoved` | user, yesAmount, noAmount, shares |
| `SharesTransferred` | from, to, shares |
| `DeviationPolicyUpdated` | soft, stress, hard, stressFee, stressMax, unsafeMax |
| `WithdrawProtocolFees` | owner, amount |

## Error Codes

| Error | Description |
|-------|-------------|
| `PredictionMarket__CloseTimeGreaterThanResolutionTime()` | closeTime must be before resolutionTime |
| `PredictionMarket__InitailConstantLiquidityNotSetYet()` | Market not yet seeded |
| `PredictionMarket__InitailConstantLiquidityAlreadySet()` | Liquidity already seeded |
| `PredictionMarket__AddLiquidity_YesAndNoCantBeZero()` | Cannot add zero liquidity |
| `PredictionMarket__AmountCantBeZero()` | Zero amount not allowed |
| `PredictionMarket__AmountLessThanMinAllwed()` | Below minimum swap amount |
| `PredictionMarket__SwapingExceedSlippage()` | Slippage exceeded |
| `PredictionMarket__AlreadyResolved()` | Market already resolved |
| `PredictionMarket__Isclosed()` | Market closed |
| `PredictionMarket__IsPaused()` | Market paused |
| `PredictionMarket__IsUnderManualReview()` | Market in review state |
| `PredictionMarket__RiskExposureExceeded()` | User exposure cap hit |
| `PredictionMarket__NotOwner_Or_CrossChainController()` | Unauthorized caller |
| `PredictionMarket__StateNeedToResolvedToWithdrawLiquidity()` | Must be resolved first |
| `PredictionMarket__DeviationPolicyInvalid()` | Invalid deviation parameters |
| `PredictionMarket__TradeDirectionNotAllowedInUnsafeBand()` | Swap direction disabled |
| `PredictionMarket__TradeSizeExceedsBandLimit()` | Trade exceeds band cap |

## Integration Guide

### Creating a Market
1. Factory calls `initialize()` with question, timestamps, collateral
2. Owner calls `setOutcomeTokens()` with YES/NO token addresses
3. Factory or owner funds contract with collateral
4. Owner calls `seedLiquidity()` to bootstrap AMM
5. Market is now tradable

### Trading Flow
1. User acquires collateral (e.g., USDC)
2. User calls `mintCompleteSets()` to get YES+NO tokens
3. User calls `swapYesForNo()` or `swapNoForYes()` to trade
4. Or user holds tokens until resolution

### Resolution Flow
1. After resolutionTime, owner or CRE calls resolve functions
2. If no dispute, resolution auto-finalizes after dispute window
3. If disputed, owner adjudicates or manual review required
4. Winners redeem tokens via `redeem()`

### Cross-Chain (Hub-Spoke)
1. Hub factory broadcasts canonical prices via CCIP
2. Spoke markets update via `setCanonicalPrice()`
3. Deviation controls apply based on canonical vs AMM price
4. Hub broadcasts resolution to spokes
