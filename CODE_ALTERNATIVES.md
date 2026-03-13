# Code Review & Alternatives — GeoChain Prediction Market

> Issues found during codebase review, with concrete alternatives and implementation guidance.  
> **This file is separate from the roadmap** — it focuses on what's currently unrealistic or suboptimal and how to fix it.

---

## 1. AMM Model: CPMM → LMSR

### Problem

Your current AMM uses **Constant Product (x·y = k)** via [AMMLib.sol](file:///home/himxa/Desktop/market/contracts/contract/src/libraries/AMMLib.sol):

```solidity
uint256 k = reserveIn * reserveOut;
newReserveIn = reserveIn + amountIn;
uint256 rawNewReserveOut = k / newReserveIn;
```

CPMM was designed for token-swapping (Uniswap), **not prediction markets**. Key issues:

| Problem | Impact |
|---|---|
| **LPs lose money at resolution** | If YES wins, the pool ends up holding mostly worthless NO tokens. LPs absorb the loss. |
| **Prices don't map cleanly to probabilities** | CPMM implied probability = `noReserve / (yesReserve + noReserve)`, which only works when reserves start equal. After asymmetric liquidity adds, the mapping breaks. |
| **No bounded loss guarantee** | Market maker (pool) can lose 100% of one side. |
| **Binary only** | Extending to N outcomes is non-trivial with CPMM. |

### Alternative: LMSR (Logarithmic Market Scoring Rule)

LMSR is the **academically standard AMM for prediction markets**, used by Gnosis, Polymarket (modified), and Augur v1.

#### Core Math

```
Cost function:  C(q) = b × ln(Σ exp(q_i / b))

Price of outcome i:  price_i = exp(q_i / b) / Σ exp(q_j / b)
```

Where:
- `q_i` = outstanding shares of outcome `i`
- `b` = liquidity parameter (controls depth; higher b = deeper liquidity, more market maker loss)
- Cost to buy `Δ` shares of outcome `i`: `C(q + Δe_i) - C(q)`

#### Key Advantages for Your Project

1. **Bounded market maker loss** — Worst case = `b × ln(N)` where N = number of outcomes. You can set this upfront.
2. **Prices always sum to 1** — No need for `CanonicalPricingModule` to fix pricing drift.
3. **Native N-outcome support** — Same formula works for binary and multi-outcome markets.
4. **No LP problem** — No liquidity providers needed. The market maker IS the subsidy.

#### Solidity Implementation Guide

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {UD60x18, ud, ln, exp, wrap, unwrap} from "@prb/math/src/UD60x18.sol";

/// @title LMSRLib
/// @notice Logarithmic Market Scoring Rule for prediction markets.
/// @dev Uses PRBMath for 18-decimal fixed-point exp/ln.
///      All share quantities are stored in 1e18 precision internally.
library LMSRLib {
    /// @notice Computes the LMSR cost function C(q) = b * ln(Σ exp(q_i / b)).
    /// @param shares Array of outstanding shares per outcome.
    /// @param b Liquidity parameter (1e18 precision).
    /// @return cost The total cost value (1e18 precision).
    function costFunction(uint256[] memory shares, uint256 b)
        internal
        pure
        returns (uint256 cost)
    {
        UD60x18 bFixed = ud(b);
        UD60x18 sumExp = ud(0);

        for (uint256 i = 0; i < shares.length; i++) {
            // exp(q_i / b)
            UD60x18 exponent = ud(shares[i]).div(bFixed);
            sumExp = sumExp.add(exp(exponent));
        }

        // b * ln(sumExp)
        cost = unwrap(bFixed.mul(ln(sumExp)));
    }

    /// @notice Returns the price (probability) of outcome `i`.
    /// @dev price_i = exp(q_i / b) / Σ exp(q_j / b)
    function price(uint256[] memory shares, uint256 b, uint256 outcomeIndex)
        internal
        pure
        returns (uint256)
    {
        UD60x18 bFixed = ud(b);
        UD60x18 sumExp = ud(0);

        for (uint256 i = 0; i < shares.length; i++) {
            sumExp = sumExp.add(exp(ud(shares[i]).div(bFixed)));
        }

        UD60x18 outcomeExp = exp(ud(shares[outcomeIndex]).div(bFixed));
        // Returns price in 1e18 precision
        return unwrap(outcomeExp.div(sumExp));
    }

    /// @notice Cost to buy `amount` shares of `outcomeIndex`.
    /// @return tradeCost Cost delta in collateral (1e18 precision).
    function costToBuy(
        uint256[] memory shares,
        uint256 b,
        uint256 outcomeIndex,
        uint256 amount
    ) internal pure returns (uint256 tradeCost) {
        uint256 costBefore = costFunction(shares, b);

        // Create new shares array with increased outcome
        uint256[] memory newShares = new uint256[](shares.length);
        for (uint256 i = 0; i < shares.length; i++) {
            newShares[i] = shares[i];
        }
        newShares[outcomeIndex] += amount;

        uint256 costAfter = costFunction(newShares, b);
        tradeCost = costAfter - costBefore;
    }

    /// @notice Cost to sell `amount` shares of `outcomeIndex`.
    /// @return tradeRefund Refund in collateral (1e18 precision).
    function costToSell(
        uint256[] memory shares,
        uint256 b,
        uint256 outcomeIndex,
        uint256 amount
    ) internal pure returns (uint256 tradeRefund) {
        uint256 costBefore = costFunction(shares, b);

        uint256[] memory newShares = new uint256[](shares.length);
        for (uint256 i = 0; i < shares.length; i++) {
            newShares[i] = shares[i];
        }
        require(newShares[outcomeIndex] >= amount, "Insufficient shares");
        newShares[outcomeIndex] -= amount;

        uint256 costAfter = costFunction(newShares, b);
        tradeRefund = costBefore - costAfter;
    }
}
```

#### Migration Path

1. **Add dependency**: `forge install PaulRBerg/prb-math` and add remapping `@prb/math/=lib/prb-math/`.
2. **Create `LMSRLib.sol`** in `src/libraries/`.
3. **Modify `PredictionMarketBase`**:
   - Replace `yesReserve`/`noReserve` with `uint256[] public outstandingShares` (index 0 = YES, 1 = NO).
   - Add `uint256 public liquidityParam` (the `b` value).
   - Remove `totalShares` and LP share tracking (LMSR doesn't need LPs).
4. **Modify swap functions**: Instead of `getAmountOut`, call `LMSRLib.costToBuy` / `costToSell`.
5. **Keep CanonicalPricingModule** — Use LMSR's `price()` as the local price and compare with canonical price.
6. **Simplify seeding**: Instead of `seedLiquidity`, just set the `b` parameter and initial shares to zero. The market maker subsidy = `b * ln(2)` ≈ `0.693 * b` for binary markets.

#### Choosing `b`

| Market Size | Suggested `b` (USDC precision) | Max MM Loss |
|---|---|---|
| Small (< $1k TVL) | 100e6 (100 USDC) | ~69 USDC |
| Medium ($1k–10k TVL) | 1000e6 (1,000 USDC) | ~693 USDC |
| Large (> $10k TVL) | 5000e6 (5,000 USDC) | ~3,466 USDC |

> **Gas cost note**: LMSR uses `exp` and `ln` which cost ~5k–8k gas each. For a binary market (2 outcomes), total AMM gas overhead is ~20-30k more than CPMM per trade. This is acceptable on L2s (Arbitrum, Base) where gas is cheap (<$0.01/tx).

---

## 2. Single-Source Resolution (Gemini AI) — Centralization Risk

### Problem

In [resolve.ts](file:///home/himxa/Desktop/market/contracts/cre/market-automation-workflow/handlers/cronHandlers/resolve.ts#L174-L178):

```typescript
const geminiResolve = askGemeniResolve(runtime, { question, resolutionTimeUnix, resolutionTimeIso });
const outcome = toOutcomeCode(geminiResolve.result);
```

A single AI model decides market outcomes. Problems:
- Gemini hallucination = wrong resolution = user fund loss.
- Single point of failure — if Gemini API is down, no resolution.
- No verifiability — users have to trust your off-chain Gemini call.

### Alternative: Multi-Source Resolution

```typescript
// Proposed multi-source resolution architecture
const resolveWithQuorum = async (runtime, question, resolutionTime) => {
  // Source 1: Gemini
  const gemini = askGeminiResolve(runtime, { question, resolutionTime });
  
  // Source 2: Alternative AI (Claude, GPT-4, Perplexity)
  const altAI = askAlternativeAI(runtime, { question, resolutionTime });
  
  // Source 3: Chainlink Data Feed (for price markets)
  const chainlinkPrice = getChainlinkPrice(runtime, question);
  
  // Quorum: at least 2 of 3 agree
  const votes = [gemini.result, altAI.result, chainlinkPrice.result];
  const yesCount = votes.filter(v => v === "YES").length;
  const noCount = votes.filter(v => v === "NO").length;
  
  if (yesCount >= 2) return { outcome: 1, confidence: "high" };
  if (noCount >= 2) return { outcome: 2, confidence: "high" };
  
  // No consensus → Inconclusive → goes to manual review
  return { outcome: 3, confidence: "low" };
};
```

For price-based markets ("Will BTC > $100k?"), use **Chainlink Data Feeds** as the primary source. AI should only be used for opinion/event markets where no on-chain oracle exists.

---

## 3. Hardcoded Chain Selectors & Testnet Assumptions

### Problem

In [MarketFactoryBase.sol](file:///home/himxa/Desktop/market/contracts/contract/src/marketFactory/MarketFactoryBase.sol#L249-L252):

```solidity
s_supportedChainSelector[3478487238524512106] = true; // Arbitrum Sepolia
s_supportedChainSelector[11155111] = true;             // Sepolia
s_supportedChainSelector[80002] = true;                // Polygon Amoy
s_supportedChainSelector[84532] = true;                // Base Sepolia
```

Hardcoded testnet selectors in the initializer will break on mainnet. Also, `11155111` looks like a chain ID not a CCIP chain selector (Sepolia's CCIP selector is `16015286601757825753`).

And in [market-users-workflow/main.ts](file:///home/himxa/Desktop/market/contracts/cre/market-users-workflow/main.ts#L11-L16):

```typescript
const toChainId = (chainName: string): number | null => {
  if (chainName.includes("arbitrum")) return 421614;
  if (chainName.includes("base")) return 84532;
  if (chainName === "ethereum-testnet-sepolia") return 11155111;
  return null;
};
```

### Alternative

**Contracts**: Move chain selectors to deployment config:
```solidity
function initialize(
    address _collateral,
    address _forwarder,
    address _marketDeployer,
    address _initialOwner,
    uint64[] calldata _supportedSelectors  // <--- pass in from deployment script
) public virtual initializer {
    for (uint i = 0; i < _supportedSelectors.length; i++) {
        s_supportedChainSelector[_supportedSelectors[i]] = true;
    }
}
```

**CRE Workflows**: Use config-driven chain ID mapping instead of string matching:
```typescript
// In config.ts
export const CHAIN_IDS: Record<string, number> = {
  "arbitrum-sepolia": 421614,
  "arbitrum-one": 42161,
  "base-sepolia": 84532,
  "base": 8453,
  "ethereum-sepolia": 11155111,
  "ethereum": 1,
};
```

---

## 4. Risk Exposure Cap — Too Simple

### Problem

In [MarketTypes.sol](file:///home/himxa/Desktop/market/contracts/contract/src/libraries/MarketTypes.sol#L39):

```solidity
uint256 internal constant MAX_RISK_EXPOSURE = 10000e6; // $10,000 per user
```

A flat per-user cap shared across ALL markets is unrealistic for production:
- A user with $10k exposure on 10 markets = $1k effective per market. Too restrictive.
- A user with $10k on 1 market = too concentrated. Not restrictive enough.

### Alternative

```solidity
// Per-market per-user cap (configurable at market creation)
mapping(address => mapping(address => uint256)) public userMarketExposure;
// Per-market cap (set at creation based on liquidity size)
mapping(address => uint256) public marketMaxExposure;

function _checkExposure(address user, address market, uint256 amount) internal view {
    uint256 currentExposure = userMarketExposure[user][market];
    uint256 marketCap = marketMaxExposure[market];
    require(currentExposure + amount <= marketCap, "Exposure exceeded");
}
```

Also consider VRF-based tiered limits: higher limits for verified users (Worldcoin-verified).

---

## 5. `PredictionMarketBridge` — Missing Fee Denom Check

### Problem

The bridge's `sellWrappedClaimForCollateral` function uses a `buybackBps` to buy back wrapped claims. However, the `setWrappedClaimBuybackBps` function doesn't validate against the actual collateral precision:

If someone sets `buybackBps = 10_001` (>100%), the buyback pays out **more** than the claim is worth.

### Alternative

```solidity
function setWrappedClaimBuybackBps(uint16 buybackBps) external onlyOwner {
    require(buybackBps <= 10_000, "Buyback > 100%");
    require(buybackBps >= 5_000, "Buyback < 50%"); // Minimum fairness
    wrappedClaimBuybackBps = buybackBps;
}
```

---

## 6. Spelling Errors in Public Interfaces

### Problem

Several error names and function names have typos that will be permanent once deployed to mainnet (they're part of the ABI):

| Location | Current | Should Be |
|---|---|---|
| `MarketErrors` | `PredictionMarket__InitailConstantLiquidityNotSetYet` | `PredictionMarket__InitialConstantLiquidityNotSetYet` |
| `MarketErrors` | `PredictionMarket__InitailConstantLiquidityAlreadySet` | `PredictionMarket__InitialConstantLiquidityAlreadySet` |
| `MarketErrors` | `PredictionMarket__FundingInitailAountGreaterThanAmountSent` | `PredictionMarket__FundingInitialAmountGreaterThanAmountSent` |
| `MarketErrors` | `PredictionMarket__SwapYesFoNo_YesExeedBalannce` | `PredictionMarket__SwapYesForNo_YesExceedBalance` |
| `MarketErrors` | `PredictionMarket__SwapNoFoYes_NoExeedBalannce` | `PredictionMarket__SwapNoForYes_NoExceedBalance` |
| `MarketErrors` | `PredictionMarket__RedeemCompletesetLessThanMinAllowed` | `PredictionMarket__RedeemCompleteSetLessThanMinAllowed` |
| `MarketErrors` | `PredictionMarket__MintingCompleteset__AmountLessThanMinimu` | `PredictionMarket__MintingCompleteSet__AmountLessThanMinimum` |
| `MarketErrors` | `PredictionMarket__WithDrawLiquidity_Insufficientfee` | `PredictionMarket__WithdrawLiquidity_InsufficientFee` |
| CRE handler | `resoloveEvent` | `resolveEvent` |
| CRE file | `commad.md` | `command.md` |

> **Fix these before mainnet**. ABIs are immutable once deployed. Typos in error selectors will confuse integrators forever.

---

## 7. Missing Emergency Controls

### Problem

While `PredictionMarket` has `pause()`/`unpause()`, the `RouterVault` does NOT have emergency pause, and the `MarketFactory` does NOT have global pause. If a vulnerability is found in the router, there's no way to stop it.

### Alternative

```solidity
// Add to PredictionMarketRouterVaultBase
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

abstract contract PredictionMarketRouterVaultBase is
    Initializable,
    ReceiverTemplateUpgradeable,
    UUPSUpgradeable,
    ReentrancyGuard,
    PausableUpgradeable  // <-- ADD THIS
{
    // Add to all user-facing functions:
    function depositCollateral(uint256 amount) external nonReentrant whenNotPaused { ... }
    function mintCompleteSets(...) external nonReentrant whenNotPaused { ... }
    // etc.
}
```

Also add a **guardian role** that can pause but NOT unpause (separation of concerns):

```solidity
address public guardian;

function guardianPause() external {
    require(msg.sender == guardian || msg.sender == owner(), "Not authorized");
    _pause();
}

function unpause() external onlyOwner {  // Only owner can unpause
    _unpause();
}
```

---

## 8. CRE Gas Limit — Hardcoded `10000000`

### Problem

Every `writeReport` call uses `gasLimit: "10000000"` (10M gas):

```typescript
gasConfig: { gasLimit: "10000000" }
```

10M is excessive for most operations (creation ~500k, sync ~200k). You're overpaying for gas on every handler invocation.

### Alternative

Define per-action gas limits in config:

```typescript
const GAS_LIMITS: Record<string, string> = {
  createMarket: "800000",
  ResolveMarket: "500000",
  syncSpokeCanonicalPrice: "300000",
  priceCorrection: "1000000",
  processWithdrawals: "2000000",
};

// Use: gasConfig: { gasLimit: GAS_LIMITS[actionType] || "1000000" }
```

---

## 9. Missing Event Emission on State Changes

### Problem

Several state-changing operations don't emit events, making off-chain indexing incomplete:

- `setRiskExempt()` in `PredictionMarketBase` — no event.
- `setDisputeWindow()` in `PredictionMarketResolution` — no event.
- `setMarketDeployer()` in `MarketFactoryBase` — no event.
- `setCcipConfig()` in `MarketFactoryCcip` — some paths missing events.

### Alternative

Add events for every admin configuration change. This is essential for:
- Auditing admin actions.
- Frontend reactivity.
- Governance transparency.

---

## 10. Cron Handler Architecture — All On Same Schedule

### Problem

In [market-automation-workflow/main.ts](file:///home/himxa/Desktop/market/contracts/cre/market-automation-workflow/main.ts#L21-L31):

```typescript
handler(cron.trigger({ schedule: config.schedule }), resoloveEvent),
handler(cron.trigger({ schedule: config.schedule }), marketFactoryBalanceTopUp),
handler(cron.trigger({ schedule: config.schedule }), createPredictionMarketEvent),
handler(cron.trigger({ schedule: config.schedule }), processPendingWithdrawalsHandler),
handler(cron.trigger({ schedule: config.schedule }), syncCanonicalPrice),
handler(cron.trigger({ schedule: config.schedule }), arbitrateUnsafeMarketHandler),
handler(cron.trigger({ schedule: config.schedule }), adjudicateExpiredDisputeWindows),
handler(cron.trigger({ schedule: config.schedule }), syncManualReviewMarketsToFirebase),
```

All 8 handlers fire on the **same schedule**. This is wasteful and creates contention:
- Price sync should run frequently (every 2–5 min).
- Market creation should run rarely (daily or on-demand).
- Resolution needs to run often (every 5–10 min).
- Manual review sync is low priority (every 30 min).

### Alternative

```typescript
const cronWorkflows: Workflow<Config> = [
  // High frequency — every 2 min
  handler(cron.trigger({ schedule: config.priceSyncSchedule }), syncCanonicalPrice),
  handler(cron.trigger({ schedule: config.priceSyncSchedule }), arbitrateUnsafeMarketHandler),
  
  // Medium frequency — every 10 min
  handler(cron.trigger({ schedule: config.resolutionSchedule }), resoloveEvent),
  handler(cron.trigger({ schedule: config.resolutionSchedule }), adjudicateExpiredDisputeWindows),
  handler(cron.trigger({ schedule: config.resolutionSchedule }), processPendingWithdrawalsHandler),
  handler(cron.trigger({ schedule: config.resolutionSchedule }), marketFactoryBalanceTopUp),
  
  // Low frequency — daily
  handler(cron.trigger({ schedule: config.marketCreationSchedule }), createPredictionMarketEvent),
  handler(cron.trigger({ schedule: config.lowPrioritySchedule }), syncManualReviewMarketsToFirebase),
];
```

---

## Summary Priority Matrix

| # | Issue | Severity | Effort | Priority |
|---|---|---|---|---|
| 1 | CPMM → LMSR | 🔴 High | Large (2–3 weeks) | P0 |
| 2 | Single-source AI resolution | 🔴 High | Medium (1 week) | P0 |
| 3 | Hardcoded chain selectors | 🟡 Medium | Small (1 day) | P1 |
| 4 | Flat risk exposure cap | 🟡 Medium | Small (2 days) | P1 |
| 5 | Bridge buyback validation | 🟡 Medium | Trivial | P1 |
| 6 | Spelling errors in ABI | 🟡 Medium | Trivial | P1 |
| 7 | Missing emergency pause | 🔴 High | Small (1 day) | P0 |
| 8 | Hardcoded gas limits | 🟢 Low | Trivial | P2 |
| 9 | Missing events | 🟡 Medium | Small (1 day) | P1 |
| 10 | Same cron schedule | 🟡 Medium | Small (half day) | P1 |
