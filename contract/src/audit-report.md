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

- **Cross-Contract Risk Exposure Desync** — `PredictionMarketLiquidity._checkUserExposure` / `PredictionMarketRouterVaultOperations._checkUserExposure` — Code smells: Two parallel exposure tracking systems exist (one in market, one in router), each with its own `userRiskExposure` mapping. A user trading via router has exposure tracked in the router, while direct market calls track in the market. It remains unverified whether a user could bypass exposure caps by mixing direct and router-mediated interactions.

- **`_executeLMSRBuy` Fee Asymmetry Between Direct and Router Path** — `PredictionMarketLiquidity._executeLMSRBuy` / `PredictionMarketRouterVaultOperations._buy` — Code smells: The router `_buy` calculates `actualCost` by deducting fee locally (line 458–463), then passes the full `costDelta` to `executeBuy`. The market's `_executeLMSRBuy` also deducts fee (line 115–120). If both deductions apply, the fee is double-charged. Whether this occurs depends on whether the router's `costDelta` is pre-fee or post-fee — the code paths are unclear and comments conflict.

- **Cross-Chain Resolution Race Condition** — `MarketFactoryCcip.ccipReceive` / `PredictionMarketResolution.resolveFromHub` — Code smells: If a hub-factory broadcasts a resolution and the spoke market is already in `State.Review` with `proposedResolution != Unset` (from a local CRE report), `resolveFromHub` will revert at line 303–306. This means spoke markets with pending local proposals become immune to hub resolution until manually cleaned up.

- **`onlyRouterVaultAndFactory` Modifier Has Nested Conditional Logic** — `PredictionMarketBase.onlyRouterVaultAndFactory` — Code smells: When `msg.sender == marketFactory`, the modifier additionally requires `_trader == address(marketFactory)`, which means only factory self-trades are allowed. The nested `if` inside `else if` is unusual for a modifier and could be misunderstood during maintenance. If a factory-delegated user trade is attempted through this path, it silently reverts with `InvalidArbTrader` instead of a clearer error.

- **Owner-Mintable Collateral Token Assumed** — `MarketFactoryBase._mintCollateralTo` — Code smells: The factory casts collateral to `OutcomeToken` and calls `.mint()`. This only works if the collateral ERC-20 is an `OutcomeToken` owned by the factory. For real USDC or any standard ERC-20, this call would revert. The assumption is undocumented and limits mainnet deployment to synthetic test tokens.

- **`CanonicalPricingModule.swapControls` CircuitBreaker Still Computes maxOut** — `CanonicalPricingModule.swapControls` — Code smells: In the `BAND_CIRCUIT_BREAKER` branch, `allowDirection` is set to `false` but `maxOut` is still computed. Callers checking `maxOut` before `allowDirection` could accidentally admit trades. The factory's `_arbitrateUnsafeMarket` is explicitly exempt from `maxOut` limits at line 321, so this trail may be exploitable if factory calls are made during circuit-breaker state.

- **`_compactPendingWithdrawQueue` Gas DoS With Large Queue** — `MarketFactoryOperations._compactPendingWithdrawQueue` — Code smells: If the queue grows very large before compaction triggers (head >= 50 AND head * 2 >= len), the `delete pendingWithdrawQueue` + re-push loop iterates over all remaining entries. With hundreds of queued markets, this could exceed block gas limits. The deletion pattern (delete + push) also resets array length, potentially conflicting with concurrent calls.

---

> ⚠️ This review was performed by an AI assistant. AI analysis can never verify the complete absence of vulnerabilities and no guarantee of security is given. Team security reviews, bug bounty programs, and on-chain monitoring are strongly recommended. For a consultation regarding your projects' security, visit [https://www.pashov.com](https://www.pashov.com)
