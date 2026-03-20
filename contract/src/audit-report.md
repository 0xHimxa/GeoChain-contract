# 🔐 Security Review — GeoChain Prediction Market

---

## Scope

|                                  |                                                        |
| -------------------------------- | ------------------------------------------------------ |
| **Mode**                         | ALL — full repository scan                             |
| **Files reviewed**               | `MarketTypes.sol` · `ActionType.sol` · `AMMLib.sol`<br>`LMSRLib.sol` · `FeeLib.sol` · `PredictionMarketBase.sol`<br>`PredictionMarket.sol` · `PredictionMarketLiquidity.sol`<br>`PredictionMarketResolution.sol` · `PredictionMarketRouterVaultBase.sol`<br>`PredictionMarketRouterVaultOperations.sol` · `PredictionMarketRouterVault.sol`<br>`MarketFactoryBase.sol` · `MarketFactoryCcip.sol`<br>`MarketFactoryOperations.sol` · `MarketFactory.sol`<br>`MarketDeployer.sol` · `CanonicalPricingModule.sol`<br>`OutcomeToken.sol` · `PredictionMarketBridge.sol`<br>`BridgeWrappedClaimToken.sol` · `Client.sol`<br>`IAny2EVMMessageReceiver.sol` · `IRouterClient.sol`<br>`MarketDeployer.sol` (imports) · `MarketFactory.sol` (imports) |
| **Confidence threshold (1-100)** | 80                                                     |

---

## Findings

[90] **1. Protocol Fee Withdrawn Before State Reset — Reentrancy-Adjacent Fund Drain**

`PredictionMarket.withdrawProtocolFees` · Confidence: 90

**Description**
`withdrawProtocolFees()` transfers the full `protocolCollateralFees` balance to `msg.sender` before zeroing the storage variable. While `safeTransfer` uses ERC-20 transferring (not native ETH), if the collateral token has callbacks (e.g., ERC-777 hooks), a reentrant call could re-enter and re-read the non-zeroed `protocolCollateralFees`, draining the contract. More critically, even without reentrancy, the pattern violates checks-effects-interactions — the state update should precede the external call.

**Fix**

```diff
  function withdrawProtocolFees() external {
      ...
      uint256 fees = protocolCollateralFees;
+     protocolCollateralFees = 0;
      i_collateral.safeTransfer(msg.sender, fees);
-     protocolCollateralFees = 0;
      emit MarketEvents.WithdrawProtocolFees(msg.sender, fees);
  }
```

---

[90] **2. Inconsistent Encoding — `abi.encodePacked` vs `abi.encode` in ActionType Hashes**

`ActionTypeHashed` · Confidence: 90

**Description**
Some action type hashes use `keccak256(abi.encodePacked(...))` (lines 10–19: `HASHED_RESOLVE_MARKET`, `HASHED_FINALIZE_RESOLUTION_AFTER_DISPUTE_WINDOW`, etc.) while others use `keccak256(abi.encode(...))` (lines 28–59: `hashed_BroadCastPrice`, `hashed_CreateMarket`, etc.). In `PredictionMarketResolution._processReport`, the action string is hashed with `keccak256(abi.encodePacked(actionType))`, but in `MarketFactoryOperations._processReport` and `PredictionMarketRouterVaultOperations._processReport`, it is hashed with `keccak256(abi.encode(actionType))`. This means the dispatchers will **never** match the wrong set of hashes because the encoding is consistent within each contract. However, if any CRE handler sends a report to the wrong contract (e.g., a factory-scoped action to a market contract), the action hash would silently mismatch and revert as `InvalidReport` instead of routing correctly. This inconsistency increases integration fragility and makes debugging harder.

**Fix**

```diff
  // Standardize all action type hashes to use abi.encode consistently:
- bytes32 internal constant HASHED_RESOLVE_MARKET =
-     keccak256(abi.encodePacked("ResolveMarket"));
+ bytes32 internal constant HASHED_RESOLVE_MARKET =
+     keccak256(abi.encode("ResolveMarket"));
  // Apply to all HASHED_ constants in ActionType.sol
```

---

[88] **3. `_executeLMSRBuy` Transfers Collateral After Minting Tokens — State Inconsistency Window**

`PredictionMarketLiquidity._executeLMSRBuy` · Confidence: 88

**Description**
In `_executeLMSRBuy`, outcome tokens are minted to the trader (lines 139–146) **before** collateral is pulled from trader via `safeTransferFrom` (line 149). This creates a window where the trader holds newly minted outcome tokens but has not yet paid. If the collateral's `transferFrom` fails or if there are callback hooks, the minted tokens would need to be recovered. While Solidity 0.8.33 reverts the entire transaction on failure, the ordering still violates the "pull payment before minting" convention and could interact poorly with upgradeable collateral tokens that add hooks.

**Fix**

```diff
  function _executeLMSRBuy(...) internal marketOpen {
      ...
+     // Transfer collateral (inclusive cost) from trader to market FIRST
+     i_collateral.safeTransferFrom(trader, address(this), costDelta);
+
      // Mint outcome tokens to trader and update outstanding shares
      if (outcomeIndex == 0) {
          yesSharesOutstanding += sharesDelta;
          yesToken.mint(trader, sharesDelta);
      } else {
          noSharesOutstanding += sharesDelta;
          noToken.mint(trader, sharesDelta);
      }

-     // Transfer collateral (inclusive cost) from trader to market
-     i_collateral.safeTransferFrom(trader, address(this), costDelta);
      ...
  }
```

---

[85] **4. CRE Has Unilateral Control Over Trade Parameters — No On-Chain Cost Verification**

`PredictionMarketLiquidity._executeLMSRBuy` / `_executeLMSRSell` · Confidence: 85

**Description**
The LMSR cost/refund computation is done entirely off-chain by the CRE. The on-chain contract trusts CRE-reported `costDelta`, `refundDelta`, `sharesDelta`, and new prices with only lightweight validation (price sum ~1e6, nonce matches). There is no on-chain verification that `costDelta` is mathematically consistent with the LMSR formula `C(q+Δe_i) - C(q)`. A compromised or buggy CRE node could report arbitrarily low `costDelta` for large `sharesDelta`, effectively minting shares for free. The only defense is the CRE's cryptographic report signing via the Keystone forwarder, which is external to the contracts themselves.

---

[85] **5. `redeem()` Emits Event and Charges Fee Even for Inconclusive Resolution**

`PredictionMarketResolution.redeem` · Confidence: 85

**Description**
If `resolution == Resolution.Inconclusive`, the `redeem()` function passes the state check (`state == Resolved`), deducts fee into `protocolCollateralFees`, but **neither** `if` branch executes (Yes/No), so no tokens are burned and no collateral is transferred. The user's tokens remain, but the fee is extracted from the accounting. The `Redeemed` event is emitted, misleading off-chain monitors.

**Fix**

```diff
  function redeem(uint256 amount) external nonReentrant whenNotPaused {
      _zeroAmountCheck(amount);
      if (state != State.Resolved) {
          revert MarketErrors.PredictionMarket__NotResolved();
      }
+     if (resolution != Resolution.Yes && resolution != Resolution.No) {
+         revert MarketErrors.PredictionMarket__InvalidFinalOutcome();
+     }

      (uint256 netAmount, uint256 fee) = FeeLib.deductFee(...);
-     protocolCollateralFees += fee;
      if (resolution == Resolution.Yes) {
          yesToken.burn(msg.sender, amount);
+         protocolCollateralFees += fee;
          i_collateral.safeTransfer(msg.sender, netAmount);
      } else if (resolution == Resolution.No) {
          noToken.burn(msg.sender, amount);
+         protocolCollateralFees += fee;
          i_collateral.safeTransfer(msg.sender, netAmount);
      }
      emit MarketEvents.Redeemed(msg.sender, amount);
  }
```

---

[82] **6. `uniqueDisputedOutcomes` Array Overflow — No Bounds Check Before Write**

`PredictionMarketResolution.disputeProposedResolution` · Confidence: 82

**Description**
`uniqueDisputedOutcomes` is a fixed-size `Resolution[3]` array, and `uniqueDisputedOutcomesCount` is used to index into it. The Resolution enum has 4 values (Unset, Yes, No, Inconclusive) but the check at line 106–111 excludes Unset and values > Inconclusive, leaving 3 possible dispute outcomes (Yes, No, Inconclusive). This matches the array size of 3 exactly. However, the `uniqueDisputedOutcomeSeen` mapping guards against duplicates, so the count should never exceed 3. If a future code change adds a 4th valid outcome without resizing the array, an out-of-bounds write would corrupt adjacent storage. The absence of an explicit bounds check (`require(uniqueDisputedOutcomesCount < 3)`) makes this fragile.

**Fix**

```diff
  if (!uniqueDisputedOutcomeSeen[uint8(proposedOutcome)]) {
+     require(uniqueDisputedOutcomesCount < 3, "max unique outcomes reached");
      uniqueDisputedOutcomeSeen[uint8(proposedOutcome)] = true;
      uniqueDisputedOutcomes[uniqueDisputedOutcomesCount] = proposedOutcome;
      uniqueDisputedOutcomesCount++;
  }
```

---

[80] **7. `forge-std/console.sol` Import in Production Contract**

`MarketFactoryBase._mintCollateralTo` · Confidence: 80

**Description**
`MarketFactoryBase.sol` imports `forge-std/console.sol` (line 14) and uses `console.log` in the production `_mintCollateralTo` function (line 341). This is a test-only dependency that should not be in production code. If deployed without Forge's VM, the `console.log` call is a no-op at the EVM level but increases deployment gas and bytecode size. It also signals incomplete cleanup before production deployment.

**Fix**

```diff
- import {console} from "forge-std/console.sol";
  ...
  function _mintCollateralTo(address to, uint256 amount) internal {
      if (to == address(0)) revert MarketFactory__ZeroAddress();
      if (amount == 0) revert MarketFactory__InvalidMintAmount();
-     console.log(OutcomeToken(address(collateral)).owner(), "Owner");
      OutcomeToken(address(collateral)).mint(to, amount);
      emit MarketFactory__LiquidityAdded(amount);
  }
```

---

## Findings below threshold (description only)

[75] **8. Router `_creditFromUntrackedCollateral` is View-Only — No State Mutation**

`PredictionMarketRouterVaultOperations._creditFromUntrackedCollateral` · Confidence: 75

**Description**
`_creditFromUntrackedCollateral` validates that untracked collateral exists but does **not** update `collateralCredits` or `totalCollateralCredits`. The callers (`_creditCollateralFromFiat` and `_creditCollateralFromEth`) separately perform the credit update. If a race condition or callback between the view-check and the credit-update causes another credit to land, the untracked calculation would be stale, potentially double-crediting. The function's name implies it does the crediting, but it only validates — a potential source of bugs in future callers.

---

[75] **9. `_executeLMSRSell` Fee Comment Contradiction — "CRE Subtracted Fee" but Fee Is Deducted On-Chain**

`PredictionMarketLiquidity._executeLMSRSell` · Confidence: 75

**Description**
Comment at line 254 says "refundDelta is already inclusive (CRE subtracted fee)" but then fee is calculated and deducted on-chain via `FeeLib.calculateFee`. If the CRE truly pre-subtracted the fee, then on-chain deduction double-charges the fee. If the CRE sends the gross refund, the comment is misleading. The same pattern exists in `_executeLMSRBuy` at line 120. The actual behavior depends on off-chain CRE implementation — but the comment/code disagreement is a trust surface.

---

[75] **10. `redeemCompleteSets` Uses Soft Floor for `yesSharesOutstanding` / `noSharesOutstanding`**

`PredictionMarketLiquidity.redeemCompleteSets` · Confidence: 75

**Description**
Lines 420–421 use ternary floor-at-zero pattern: `yesSharesOutstanding = yesSharesOutstanding > amount ? yesSharesOutstanding - amount : 0`. This means if somehow `yesSharesOutstanding < amount` (should not happen if accounting is correct), the subtraction is silently swallowed to zero instead of reverting. This hides potential accounting bugs where shares outstanding diverges from minted token supply.

---

[75] **11. Router Agent Revoke Via Report Can Be Called By Anyone With CRE Access**

`PredictionMarketRouterVaultOperations._dispatchRouterAgentAction` · Confidence: 75

**Description**
The `HASHED_AGENT_REVOKE_PERMISSION` dispatch at line 855 calls `_revokeAgentPermission(user, agent)` after decoding `(user, agent)` from the report payload. There is no authorization check — no `_authorizeAgent` call and no verification that the report sender has authority over `user`'s permissions. Any CRE report reaching the forwarder could revoke any user's agent delegation. The only defense is CRE report signing, which is external to contract logic.

---

[70] **12. `MarketDeployer.deployPredictionMarket` Passes `address(this)` as `_initialOwner`**

`MarketDeployer.deployPredictionMarket` · Confidence: 70

**Description**
The deployer passes `address(this)` (the MarketDeployer) as `_initialOwner` to `PredictionMarket.initialize()`, then immediately calls `setOutcomeTokens` and `transferOwnership(msg.sender)`. This means the MarketDeployer is the initial owner during the atomic deployment transaction. If `transferOwnership` fails for any reason, the MarketDeployer permanently owns the market. This is safe in practice because the entire call reverts on failure, but it adds an unnecessary intermediary ownership step.

---

Findings List

| # | Confidence | Title |
|---|---|---|
| 1 | [90] | Protocol Fee Withdrawn Before State Reset — Reentrancy-Adjacent Fund Drain |
| 2 | [90] | Inconsistent Encoding — `abi.encodePacked` vs `abi.encode` in ActionType Hashes |
| 3 | [88] | `_executeLMSRBuy` Transfers Collateral After Minting Tokens — State Inconsistency Window |
| 4 | [85] | CRE Has Unilateral Control Over Trade Parameters — No On-Chain Cost Verification |
| 5 | [85] | `redeem()` Emits Event and Charges Fee Even for Inconclusive Resolution |
| 6 | [82] | `uniqueDisputedOutcomes` Array Overflow — No Bounds Check Before Write |
| 7 | [80] | `forge-std/console.sol` Import in Production Contract |
| 8 | [75] | Router `_creditFromUntrackedCollateral` is View-Only — No State Mutation |
| 9 | [75] | `_executeLMSRSell` Fee Comment Contradiction |
| 10 | [75] | `redeemCompleteSets` Uses Soft Floor for Outstanding Shares |
| 11 | [75] | Router Agent Revoke Via Report Can Be Called By Anyone With CRE Access |
| 12 | [70] | `MarketDeployer.deployPredictionMarket` Passes `address(this)` as `_initialOwner` |

---

## Leads

_Vulnerability trails with concrete code smells where the full exploit path could not be completed in one analysis pass. These are not false positives — they are high-signal leads for manual review. Not scored._

---

### LEAD-1 · Cross-Contract Risk Exposure Desync

**Files:** [PredictionMarketLiquidity.sol](file:///home/himxa/Desktop/market/contracts/contract/src/predictionMarket/PredictionMarketLiquidity.sol#L164-L185) · [PredictionMarketRouterVaultOperations.sol](file:///home/himxa/Desktop/market/contracts/contract/src/router/PredictionMarketRouterVaultOperations.sol#L573-L589)

**The two exposure systems:**

| Component | Mapping | Cap Derivation |
|---|---|---|
| Market (direct) | `PredictionMarketBase.userRiskExposure[trader]` | `liquidityParam × MAX_EXPOSURE_BPS / MAX_EXPOSURE_PRECISION` |
| Router (delegated) | `PredictionMarketRouterVaultBase.userRiskExposure[user]` | Same formula, but reads `liquidityParam` from the market via `IPredictionMarketLike(market).liquidityParam()` |

**Code smell trace:**

1. When the router calls `market.executeBuy(address(this), ...)`, the market sees `trader = address(router)`. The router is set `isRiskExempt[router] = true` in the market during `_createMarket` (MarketFactoryBase L440), so the **market** skips exposure tracking entirely.

2. The **router** then tracks its own `userRiskExposure[user]` (RouterVaultOperations L500–502):
    ```solidity
    if (!isRiskExempt[user]) {
        uint256 exposure = userRiskExposure[user];
        userRiskExposure[user] = exposure + actualCost;
    }
    ```

3. If the same `user` also calls `market.mintCompleteSets()` directly (not via the router), the **market** tracks `userRiskExposure[user]` (PredictionMarketLiquidity L355):
    ```solidity
    if (!isRiskExempt[msg.sender]) {
        userRiskExposure[msg.sender] += amount;
    }
    ```

4. **Result:** Neither system knows about the other's tracking. A user with `$X` cap could accumulate `$X` exposure via the router AND `$X` exposure via direct calls, reaching `$2X` total real exposure.

**Why it matters:** The MAX_EXPOSURE_BPS cap (500 BPS = 5%) exists to limit concentration risk. Doubling it defeats the protection.

**Mitigating factor:** Direct `mintCompleteSets` requires the user to hold collateral tokens and approve the market. The router path requires prior `depositCollateral`. In practice, most users are expected to go through the router only — but the contract does not enforce this.

---

### LEAD-2 · Fee Double-Charge Risk Between Router and Market Paths

**Files:** [PredictionMarketRouterVaultOperations.sol](file:///home/himxa/Desktop/market/contracts/contract/src/router/PredictionMarketRouterVaultOperations.sol#L443-L506) · [PredictionMarketLiquidity.sol](file:///home/himxa/Desktop/market/contracts/contract/src/predictionMarket/PredictionMarketLiquidity.sol#L89-L161)

**Code smell trace:**

1. **Router `_buy` (RouterVaultOperations L456–463)** calculates fee locally before calling market:
    ```solidity
    uint256 fee = FeeLib.calculateFee(
        costDelta, MarketConstants.LMSR_TRADE_FEE_BPS, MarketConstants.FEE_PRECISION_BPS
    );
    uint256 actualCost = costDelta - fee;
    _checkUserExposure(user, market, actualCost);
    ```
    Then passes the full `costDelta` to `market.executeBuy(address(this), ..., costDelta, ...)`.

2. **Market `_executeLMSRBuy` (PredictionMarketLiquidity L114–120)** also calculates fee:
    ```solidity
    uint256 fee = FeeLib.calculateFee(
        costDelta, effectiveFeeBps, MarketConstants.FEE_PRECISION_BPS
    );
    uint256 actualCost = costDelta - fee;
    ```
    And adds the computed fee to `protocolCollateralFees += fee`.

3. **Result:** The market deducts fee from `costDelta` and keeps it. The router also computed (`costDelta - fee`) for its own exposure tracking but doesn't deduct it from what's sent — it sends the full `costDelta` to the market. So the market's fee deduction is the only actual one. The router's local calculation is for bookkeeping only.

4. **The real smell:** The router deducts `costDelta` from `collateralCredits[user]` (L470) and from `totalCollateralCredits` (L471). The market then pulls `costDelta` from the router's actual token balance. So the user pays `costDelta` total, the market keeps `fee` from that, and `actualCost` goes into the pool. The router's exposure tracks `actualCost`. **No double-charge actually occurs** — but the confusing parallel fee calculations with conflicting comments ("CRE sends cost with fee already subtracted" at L114 vs router sending pre-fee `costDelta`) make this extremely fragile for future maintainers.

**Why it matters:** Any future refactor that changes one fee path without the other will silently break economics.

---

### LEAD-3 · Cross-Chain Resolution Race Condition

**Files:** [PredictionMarketResolution.sol](file:///home/himxa/Desktop/market/contracts/contract/src/predictionMarket/PredictionMarketResolution.sol#L289-L310) · [MarketFactoryCcip.sol](file:///home/himxa/Desktop/market/contracts/contract/src/marketFactory/MarketFactoryCcip.sol#L275-L313)

**Code smell trace:**

1. A spoke market receives a local CRE report calling `_resolve(Resolution.Yes, "proof.url")`. This sets:
    ```solidity
    proposedResolution = Resolution.Yes;  // != Unset
    state = State.Review;
    disputeDeadline = block.timestamp + disputeWindow;
    ```

2. While in `State.Review` with `proposedResolution != Unset`, the hub factory broadcasts a resolution via CCIP. The spoke factory calls `market.resolveFromHub(Resolution.No, "hub-proof.url")`.

3. `resolveFromHub` hits the guard at [L302–306](file:///home/himxa/Desktop/market/contracts/contract/src/predictionMarket/PredictionMarketResolution.sol#L302-L306):
    ```solidity
    if (
        state == State.Resolved ||
        (state == State.Review && proposedResolution != Resolution.Unset)
    ) {
        revert MarketErrors.PredictionMarket__AlreadyResolved();
    }
    ```
    **The hub resolution reverts.** The spoke market is "stuck" in its local Review state.

4. **No recovery path exists** unless:
    - The dispute window expires and `finalizeResolution()` is called, OR
    - The owner calls `adjudicateDisputedResolution()` manually.
    In either case, the local proposed resolution (possibly wrong) takes precedence over the hub's authoritative one.

**Why it matters:** The hub-spoke model assumes the hub is authoritative for resolution. This guard inverts that assumption — a stale or incorrect local CRE resolution proposal can block the hub's correct resolution from ever landing.

**Possible fix:** `resolveFromHub` should override local proposals rather than reverting:
```solidity
// If hub says "resolved", force it regardless of local Review state
if (state == State.Resolved) {
    revert MarketErrors.PredictionMarket__AlreadyResolved();
}
// Allow hub to override local Review proposals — hub is authoritative
_finalizeResolution(_outcome, proofUrl, true, false);
```

---

### LEAD-4 · `onlyRouterVaultAndFactory` Modifier Has Nested Conditional Logic

**File:** [PredictionMarketBase.sol](file:///home/himxa/Desktop/market/contracts/contract/src/predictionMarket/PredictionMarketBase.sol#L386-L400)

**Code smell trace:**

The modifier source (L386–400):
```solidity
modifier onlyRouterVaultAndFactory(address _trader) {
    if (msg.sender == routerVault) {
        _;
    } else if (msg.sender == address(marketFactory)) {
        if (_trader != address(marketFactory)) {
            revert PredictionMarket__InvalidArbTrader();
        }
        _;
    } else {
        revert PredictionMarket__OnlyRouterVaultAndFactory();
    }
}
```

**Three specific smells:**

1. **Nested `if` inside `else if` in a modifier** — the `_trader` check only applies to factory calls. When the router vault calls, `_trader` is **never validated** — the modifier skips directly to `_;`. This is by design (the router passes `address(this)` and handles user mapping separately), but a reader unfamiliar with this would assume `_trader` is always validated.

2. **The error `InvalidArbTrader` is misleading** — it fires when `msg.sender == marketFactory` but `_trader != marketFactory`. The error name suggests the trader is invalid for arbitrage, but this modifier also guards `executeBuy` and `executeSell` (which are used for regular LMSR trades, not just arbitrage). A factory calling `executeBuy(someUserAddress, ...)` would hit this error with no useful guidance.

3. **Asymmetric `_;` placement** — both the router and factory paths execute `_;` but in different nesting depths. If a developer adds shared post-condition logic after `_;`, it would only run for whichever branch was taken — and Solidity modifiers with multiple `_;` placements can cause confused control flow.

**Why it matters:** Modifiers should be simple guards. This one encodes business logic (factory can only self-trade, router can trade for anyone) inside a modifier. A future maintainer could easily introduce a factory action that calls `executeBuy(userAddress, ...)` expecting it to work like the router path.

---

### LEAD-5 · Owner-Mintable Collateral Token Assumed

**File:** [MarketFactoryBase.sol](file:///home/himxa/Desktop/market/contracts/contract/src/marketFactory/MarketFactoryBase.sol#L338-L344)

**Code smell trace:**

```solidity
function _mintCollateralTo(address to, uint256 amount) internal {
    if (to == address(0)) revert MarketFactory__ZeroAddress();
    if (amount == 0) revert MarketFactory__InvalidMintAmount();
    console.log(OutcomeToken(address(collateral)).owner(), "Owner");
    OutcomeToken(address(collateral)).mint(to, amount);
    emit MarketFactory__LiquidityAdded(amount);
}
```

**Multiple smells:**

1. **Unsafe cast: `OutcomeToken(address(collateral))`** — The `collateral` is declared as `IERC20` at L49. Casting it to `OutcomeToken` assumes it has `.owner()` and `.mint()` functions. If `collateral` is USDC, USDT, or any standard ERC-20, the `.mint()` call will **revert** (function selector not found). The `.owner()` call would also revert.

2. **No interface check or `try/catch`** — There is no runtime check (e.g., ERC-165 `supportsInterface`) to verify the collateral actually implements `OutcomeToken`'s interface before calling.

3. **Called by report-driven `_processReport`** — The action `hashed_AddLiquidityToFactory` dispatches to `_addLiquidityToFactory()` → `_mintCollateralTo(address(this), Amount_Funding_Factory)`. If CRE sends this report and collateral is real USDC, the entire report processing reverts.

4. **Also called by external `mintCollateralTo(address, uint256)`** — The owner can call this directly. If the owner sets up the factory with USDC as collateral and later calls `addLiquidityToFactory()`, it will revert with an undecipherable low-level error.

**Why it matters:** This effectively hardcodes the assumption that the "collateral" is a synthetic mintable token owned by the factory. This is undocumented and any deployment guide that specifies real stablecoin as collateral will fail at runtime. Anyone auditing the constructor/initializer would see `_collateral` as a generic address and not realize the mint constraint.

---

### LEAD-6 · CircuitBreaker Still Computes and Returns `maxOut`

**File:** [CanonicalPricingModule.sol](file:///home/himxa/Desktop/market/contracts/contract/src/modules/CanonicalPricingModule.sol#L63-L112)

**Code smell trace:**

In `swapControls`, the `BAND_CIRCUIT_BREAKER` branch (L102–111):
```solidity
} else if (bandId == BAND_CIRCUIT_BREAKER) {
    effectiveFeeBps +=
        uint256(p.stressExtraFeeBps) * CIRCUIT_BREAKER_FEE_MULTIPLIER;
    uint256 reducedCircuitMaxOutBps = _reducedMaxOutBps(
        p.unsafeMaxOutBps,
        CIRCUIT_BREAKER_MAX_OUT_DIVISOR
    );
    maxOut = (p.reserveOut * reducedCircuitMaxOutBps) / p.feePrecisionBps;
    allowDirection = false;  // <-- trading should be halted
}
```

**The smell:** `allowDirection = false` means no trade direction is allowed. But `maxOut` is still set to a non-zero computed value. Callers that test `maxOut > 0` before `allowDirection == true` would incorrectly conclude trading is permitted within that cap.

**Trace to factory `_arbitrateUnsafeMarket`:**

The factory's `_arbitrateUnsafeMarket` (MarketFactoryOperations L170–242) checks:
```solidity
if (uint8(band) != 2 && uint8(band) != 3)
    revert MarketFactory__ArbNotUnsafe();
```
Band `3` is `CIRCUIT_BREAKER`. So the factory **explicitly allows** arbitrage during circuit-breaker state. Then it calls `ctx.market.executeBuy(address(this), ...)` which goes through `_resolveLMSRTradeControls`.

In `_resolveLMSRTradeControls`, when it calls `CanonicalPricingModule.swapControls`, the factory is `isRiskExempt[address(factory)] = true` so it skips `maxOut` checks. But the returned `effectiveFeeBps` (with 5× multiplier) IS applied. So the factory pays a huge fee during circuit-breaker arbitrage.

**Inconsistency in `deviationStatus` (L124–179):** The sister function `deviationStatus` also returns `allowYesForNo` and `allowNoForYes` for the circuit-breaker band:
```solidity
} else if (bandId == BAND_CIRCUIT_BREAKER) {
    allowYesForNo = localYesPriceE6Value > p.canonicalYesPriceE6;
    allowNoForYes = localYesPriceE6Value < p.canonicalYesPriceE6;
```
Here, direction IS allowed for circuit breaker in `deviationStatus` but NOT in `swapControls`. The factory uses `getDeviationStatus()` (which calls `deviationStatus`) to decide if arbitrage direction is valid, but the actual trade goes through `swapControls` where `allowDirection = false`. The factory bypasses `allowDirection` via `isRiskExempt`, but a future caller might not, creating a mismatch.

---

### LEAD-7 · `_compactPendingWithdrawQueue` Gas DoS With Large Queue

**File:** [MarketFactoryOperations.sol](file:///home/himxa/Desktop/market/contracts/contract/src/marketFactory/MarketFactoryOperations.sol#L427-L445)

**Code smell trace:**

```solidity
function _compactPendingWithdrawQueue() internal {
    uint256 head = pendingWithdrawHead;
    uint256 len = pendingWithdrawQueue.length;
    if (head < 50 || head * 2 < len) {
        return;  // Compaction not yet needed
    }

    uint256 remaining = len - head;
    uint256[] memory tmp = new uint256[](remaining);
    for (uint256 i = 0; i < remaining; i++) {
        tmp[i] = pendingWithdrawQueue[head + i];
    }

    delete pendingWithdrawQueue;  // SSTORE to zero for each slot
    for (uint256 j = 0; j < remaining; j++) {
        pendingWithdrawQueue.push(tmp[j]);  // SSTORE new value
    }
    pendingWithdrawHead = 0;
}
```

**Multiple smells:**

1. **`delete pendingWithdrawQueue`** zeroes every storage slot of the dynamic array. For an array of `N` elements, this is `N` SSTORE operations at ~5,000 gas each (cold) or ~2,900 (warm). With 500 historical markets: `500 × 5,000 = 2,500,000 gas` just for deletion.

2. **Re-push loop** then writes `remaining` new entries at ~20,000 gas each (new slot). With 250 remaining: `250 × 20,000 = 5,000,000 gas`.

3. **Combined:** The `_compactPendingWithdrawQueue` call alone could cost **7,500,000+ gas** for a moderately sized queue. This is called at the end of every `_processPendingWithdrawals` invocation (L402).

4. **Trigger condition (`head >= 50 && head * 2 >= len`)** means compaction fires when ≥50 items were consumed AND consumed items ≥ half of total. This could trigger mid-batch during `processPendingWithdrawals(100)`, causing the entire transaction to consume the gas budget on compaction rather than actual withdrawals.

5. **`_processPendingWithdrawals` requeues unresolved markets** via `_enqueueWithdraw(marketId)` (L388), which pushes to the same array during iteration. If compaction has not yet run, the queue grows unboundedly. If compaction runs after requeuing, the newly pushed items are in the old array that `delete` is about to zero — but since `delete` happens before re-pushing, this is safe. However, if `_processPendingWithdrawals` is called again before compaction, stale queue state could cause skipped markets.

**Why it matters:** An attacker could create many small markets (if factory creation is permissionless via CRE reports) to grow the queue past the point where `_compactPendingWithdrawQueue` exceeds block gas limits, permanently bricking the withdrawal batch processor.

---

> ⚠️ This review was performed by an AI assistant. AI analysis can never verify the complete absence of vulnerabilities and no guarantee of security is given. Team security reviews, bug bounty programs, and on-chain monitoring are strongly recommended. For a consultation regarding your projects' security, visit [https://www.pashov.com](https://www.pashov.com)
