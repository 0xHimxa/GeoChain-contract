# GeoChain Prediction Market – System Architecture

A decentralized, AMM‑based prediction market optimized for cross‑chain canonical pricing, owner‑administered resolution, and automated workflows driven by Chainlink CRE/CCIP.

## Repository Layout

- `src/`: Solidity contracts. Core tenants live here (`MarketFactory`, `PredictionMarket`, `OutcomeToken`) plus CCIP helpers, shared libraries, and the upgradeable factory variant.
- `lib/`: Forked OpenZeppelin and Foundry standard libraries needed by the contracts (`forge-std`, `openzeppelin-contracts`, `openzeppelin-contracts-upgradeable`).
- `script/`: Foundry scripts for deployment and upgrades plus interface helpers (`ReceiverTemplateUpgradeable`).
- `test/`: Unit (`unit/`), stateless fuzz (`statelessFuzz/`), and future stateful fuzz (`statefullFuzz/`) coverage helpers with README guidance for naming conventions, verbosity flags, and CI expectations.
- `predictionMarket/market-workflow/`: Off-chain automation (Chainlink CRE + Gemini + Firestore) that monitors collaterals, proposes markets/resolution data, and writes CRE reports back to the contracts.

## Core Solidity Components

### MarketFactory (UUPS Upgradeable Hub)
- Upgradeable owner-controlled factory that deploys markets through `MarketDeployer` to stay within the EVM size limit.
- Holds the collateral token (initially a mintable USDC mock for tests) and seeds newly created markets with equal YES/NO reserves.
- Tracks every active market in `activeMarkets`/`marketToIndex` for iteration and arbitrage.
- Maintains cross-chain state: `isHubFactory` distinguishes hub vs. spoke, `trustedRemoteBySelector` + `ccipReceive` handle CCIP messages, and `broadcastCanonicalPrice`/`broadcastResolution` push hub updates to spokes.
- Processes CCIP inbound price/resolution payloads, verifies source selectors, syncs canonical prices on spokes, and routes hub resolutions into local markets (`PredictionMarket.resolveFromHub`).
- Offers maintenance helpers: `arbitrateUnsafeMarket` (capped swaps via AMM math), liquidity top-ups `addLiquidityToFactory`, and `withdrawCollateralFromEvents` after resolution.

### PredictionMarket
- Core AMM market contract; deploys two `OutcomeToken` instances for YES/NO (6 decimals to match USDC) and uses `ReceiverTemplateUpgradeable` for Chainlink CRE reports.
- Market lifecycle: Open → Closed (automatically at `closeTime`) → Review (if owner initially sets INCONCLUSIVE) → Resolved.
- AMM logic: constant product formula `k = yesReserve * noReserve`, swap fees stay in the pool, and LP shares minted/burned with proportional accounting (`AMMLib`).
- Liquidity management: `seedLiquidity`, `addLiquidity`, `removeLiquidity`, `removeLiquidityAndRedeemCollateral`, `withdrawLiquidityCollateral`, and LP share transfers with slippage allowances.
- Complete set mint/redeem with hardcoded fee schedule; tracks `userRiskExposure` to cap per-user collateral in a market and supports exemptions.
- Swap routing respects canonical pricing when enabled (`crossChainController` + `marketFactory.isHubFactory()`), gating trades with deviation bands (Normal/Stress/Unsafe/CircuitBreaker) calculated by `CanonicalPricingModule` and `setDeviationPolicy`.
- Resolution flows: `resolve` (owner, requires proof URL), `manualResolveMarket`, cross-chain `resolveFromHub`, and canonical price callbacks (`syncCanonicalPriceFromHub`). On-chain chainlink automation via `_processReport` (receives `ResolveMarket` from CRE).
- Quote utilities: `getYesForNoQuote`, `getNoForYesQuote`, `getYesPriceProbability`, `getNoPriceProbability` expose deterministic pricing for UIs.
- Protocol treasury: `protocolCollateralFees` accumulates fees; `withdrawProtocolFees` lets the owner or cross-chain controller claim fees after resolution.

### OutcomeToken
- Minimal `ERC20` with `Ownable` to restrict mint/burn to its parent market.
- Fixed 6 decimal places, aligning with USDC collateral.

## Libraries & Modules

- `MarketTypes`: Shared enums (`State`, `Resolution`), constants (`SWAP_FEE_BPS`, `PRICE_PRECISION`, `MAX_RISK_EXPOSURE`), custom events, and errors used across contracts.
- `AMMLib`: Pure math for CPMM swaps, probability queries, and LP share calculations.
- `FeeLib`: Centralized fee deduction helpers used during mint/redeem and swap settlement.
- `CanonicalPricingModule`: Stateless utility that computes deviation bands (Normal → CircuitBreaker), extra fee overlays, max output caps, and direction permissions when operating under hub-provided prices.

## Liquidity, Fees & Risk Controls

1. **Liquidity provisioning**: Markets seed equal YES/NO reserves and assign LP shares 1:1 with collateral. `addLiquidity`/`removeLiquidity` keep ratios using `AMMLib.calculateShares` and enforce minimum share sizes (`MarketConstants.MINIMUM_ADD_LIQUIDITY_SHARE`).
2. **Trading**: Users swap YES ↔ NO via `_swap`; fees (4%) remain inside reserves, benefitting LPs. Price discovery derives from reserve ratios; deviation policy dynamically increases fees and applies output caps when canonical prices diverge.
3. **Complete sets**: Minting/redeeming charges 3%/2% fees, respects `MAX_RISK_EXPOSURE` per address, and uses `FeeLib.deductFee`. `removeLiquidityAndRedeemCollateral` burns matched pairs, takes redemption fees, and refunds leftovers.
4. **Resolution & Redemption**: Owner resolves (or Chainlink CRE / hub) and winners redeem 1:1 collateral (fee applies). Losing tokens become worthless. Manual review handles inconclusive outcomes.
5. **Risk controls**: `userRiskExposure` prevents single entities from dominating (10,000 USDC cap), while `isRiskExempt` can whitelist trusted actors. `DeviationBand` guards ensure harmful arbitrage is disallowed or limited.

## Cross-Chain & Automation Flow

1. **Hub vs Spoke**: The hub factory (`isHubFactory = true`) broadcasts canonical prices/resolutions over CCIP to trusted spoke selectors. Spokes mirror market IDs via `setMarketIdMapping` and trust only configured selectors.
2. **CCIP messaging**: `broadcastCanonicalPrice` and `broadcastResolution` encode payloads (with nonces) and iterate over `s_spokeSelectors`. Incoming CCIP `ccipReceive` enforces trusted sender, replay protection, and dispatches to `PredictionMarket.syncCanonicalPriceFromHub` or `PredictionMarket.resolveFromHub`.
3. **Chainlink CRE**: Both factory and markets inherit `ReceiverTemplateUpgradeable`, so Chainlink CRE forwarders can call `onReport`. Markets decode `ResolveMarket` payloads and trigger `_resolve`; `checkResolutionTime` lets automation know when a market is eligible.
4. **Off-chain workflow**: `predictionMarket/market-workflow/main.ts` ties everything together—authenticates via Firebase, queries Gemini for event/resolution data, top-ups factory collateral, and writes CRE reports to `sendReport`. It also observes CCIP state (collateral balances) and emits automation (e.g., `addLiquidityToFactory`, `createMarket`, `broadCast` actions) via encoded reports.

## Deployment & Maintenance

- Use Foundry scripts: `script/deployMarketFactory.s.sol` for fresh deployments, `script/upgradeMarketFactory.s.sol` for UUPS upgrades. Both require `.env` variables (`PRIVATE_KEY`, `RPC_URL`, `COLLATERAL_TOKEN_ADDRESS`, etc.) documented in `script/README.md`.
- Factory owner mints test USDC via `addLiquidityToFactory` when running locally. `MarketDeployer` clones a `PredictionMarket` implementation and calls `initialize`, which also mints YES/NO tokens.
- Off-chain automation may also call encoded actions (`createMarket`, `priceCorrection`, `addLiquidityToFactory`) through `MarketFactory._processReport`. These hooks are guarded by hashed action identifiers.
- Logging/events: Swap/trade events, liquidity events, canonical/CCIP messaging, and deviation changes emit discrete events tracked by tooling.

## Testing & CI

- Run `forge test` for units, `forge test --match-path test/statelessFuzz/predictionMarket.t.sol` for fuzzing, `forge coverage` or `forge coverage --report lcov` for coverage data.
- Tests reuse `MockERC20` (USDC) with 6 decimals, and the suite is documented inside `test/README.md` including commands for `forge test -vv`, `forge test --gas-report`, etc.
- Continuous integration should run all tests, gas reports, and coverage checks before merging.

## Known Constraints

- Resolution is currently centralized to the owner or hub-controlled cross-chain controller (owner must remain honest). Manual review handles contested outcomes.
- Protocol fees accumulate on contract and must be withdrawn via `withdrawProtocolFees` once the market resolves.
- Canonical price/reward enforcement assumes CCIP messages stay timely; stale prices block trading until refreshed.

**Last Updated**: 2026-02-22
**Version**: 1.1.0
