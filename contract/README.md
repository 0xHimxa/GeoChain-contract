# GeoChain Prediction Market Contracts

A full-stack Solidity implementation of a decentralized prediction market built around a constant-product AMM, cross-chain canonical pricing, and Chainlink automation.

## Vision

Users create binary YES/NO markets backed by USDC collateral, trade via an AMM, mint/redeem complete sets, and unlock winnings once the market resolves. The system ships with safety nets (risk caps, deviation bands, manual review) and supports hub/spoke deployments with Chainlink CCIP + CRE automation.

## Key Components

| Piece | Responsibility |
| --- | --- |
| `MarketFactory` | Upgradeable hub/spoke factory that deploys markets via `MarketDeployer`, seeds collateral, tracks `activeMarkets`, and relays canonical price/resolution updates through CCIP. Hub factories broadcast prices/resolutions; spokes trust incoming selectors and enforce canonical gates. |
| `PredictionMarket` | Core market: AMM swaps, LP accounting, complete sets, resolution (owner + Chainlink CRE + cross-chain controller), manual reviews, canonical price enforcement, and protocol fee accumulation. Implements `ReceiverTemplateUpgradeable` so Chainlink CRE forwarders can call `onReport`. |
| `OutcomeToken` | 6-decimal ERC20 whose mint/burn rights are limited to the parent market. |
| `Libraries/Modules` | `AMMLib` for CPMM math, `FeeLib` for standardized fee handling, `MarketTypes` for shared enums/errors/constants, and `CanonicalPricingModule` for deviation fee caps. |
| `predictionMarket/market-workflow` | Off-chain automation that talks to Firestore + Gemini, monitors market factory balances, reports CRE actions (price broadcast, resolution, liquidity top-ups, event creation), and pushes reports through Chainlink CRE/CCIP. |

## Getting Started

### Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation)
- Solidity ^0.8.33
- Node.js (for off-chain workflow tooling)
- A collateral ERC20 (mock USDC for local tests, real USDC for mainnet)

### Setup

```bash
git clone <repo>
cd contract
forge install
```

Copy the sample environment (used by scripts):

```bash
cp .env.example .env
```

### Building

```bash
forge build
```

## Running Tests

```bash
forge test             # unit + fuzz
forge test -vv         # console logs
forge test --gas-report
forge coverage         # coverage report
```

For more guidance, check `test/README.md` (organization, naming, common values, CI notes).

## Deployment & Automation

- `script/deployMarketFactory.s.sol`: deploys a UUPS proxy for `MarketFactory`, initializes collateral, and sets the Chainlink forwarder.
- `script/upgradeMarketFactory.s.sol`: upgrades the proxy; remember to call `initialize` on new implementations if needed or redeploy a fresh proxy.
- Both scripts respect `.env` parameters (`PRIVATE_KEY`, `RPC_URL`, `COLLATERAL_TOKEN_ADDRESS`, `MARKET_FACTORY_PROXY`, `UPGRADE_CALLDATA`).
- The factory can mint test USDC via `addLiquidityToFactory` for staging.

Off-chain workflows under `predictionMarket/market-workflow/`:

1. Authenticate with Firebase and pull pending events.
2. Use Gemini helpers to source new event data and resolution predictions.
3. Call Chainlink CRE workflows (`runtime.report`) with encoded actions (`ResolveMarket`, `CreateMarket`, `AddLiquidityToFactory`, `PriceCorrection`).
4. Automate liquidity top-ups (`marketFactoryBalanceTopUp`), market creation, and price corrections while respecting CRE workflow metadata.

## Typical On-chain Flow

1. Owner calls `MarketFactory.createMarket(...)` → `MarketDeployer` clones `PredictionMarket` → factory transfers collateral → market seeds liquidity and mint YES/NO tokens.
2. Users mint complete sets, swap via `swapYesForNo`/`swapNoForYes`, and add/remove liquidity. The constant-product AMM ensures `k` increases because swap fees stay in reserves.
3. Owner resolves the market (or Chainlink CRE/hub controller). Manual review handles inconclusive outcomes, and resolved liquidity can be withdrawn by LPs.
4. `protocolCollateralFees` accumulates fees from swaps and complete set operations; owner/cross-chain controller can claim via `withdrawProtocolFees` once the market is resolved.
5. Hub factories broadcast canonical prices/resolutions via CCIP to spokes; spokes sync prices/resolutions and limit swaps when deviation between local AMM and hub price exceeds tolerance.

## Cross-Chain & Automation Highlights

- **CCIP**: Factory sends `CanonicalPriceSync` and `ResolutionSync` payloads to trusted selectors; spokes guard messages with `trustedRemoteBySelector`, `processedCcipMessages`, and nonces.
- **Canonical Pricing**: Markets enforce deviation thresholds (`softDeviationBps`, `stressDeviationBps`, `hardDeviationBps`) computed in `CanonicalPricingModule`. In unsafe bands, direction restrictions, extra fees, and max output caps activate; circuit breaker halts trading.
- **Chainlink CRE**: `ReceiverTemplateUpgradeable` verifies reports via forwarder metadata. Markets handle `ResolveMarket` payloads; factories expose hashed actions for `_processReport` so CRE automation can trigger `createMarket`, `broadcast` actions, or `arbitrateUnsafeMarket`.
- **Deviation Management**: `setDeviationPolicy` adjusts thresholds; `getDeviationStatus` exposes band info for UI/automation.

## Security & Risk Controls

- **Access control**: `onlyOwner`, `onlyCrossChainController`, and `paused` modifiers protect sensitive paths.
- **Reentrancy / CEI**: `ReentrancyGuard` and checks-effects-interactions appear in all state-changing functions.
- **Exposure cap**: `userRiskExposure` limits per-address minting to `MAX_RISK_EXPOSURE` (10k USDC); the factory can mark exempt addresses.
- **Manual review**: If owner flags an outcome as `Inconclusive`, markets enter `Review`, requiring a second `manualResolveMarket` call.
- **Protocol fees**: `protocolCollateralFees` is a single on-chain bucket; owner must withdraw after resolution to avoid stranded funds.
- **Automation watchers**: `predictionMarket/market-workflow/main.ts` observes factory balances, uses CRE to top-up liquidity, and tracks Gemini event data to ensure markets resolve with evidence URLs stored on-chain.

## Directory Quick Guide

- `src/`: production contracts plus CCIP modules (`ccip/Client.sol`, `IAny2EVMMessageReceiver.sol`, `IRouterClient.sol`) and modules (`CanonicalPricingModule`).
- `script/interfaces`: `ReceiverTemplate` helpers used by both `MarketFactory` and `PredictionMarket` for CRE reporting.
- `test/`: organizes `unit`, `statelessFuzz`, `statefullFuzz` tests and the shared `README` describing how to use cheatcodes, pranks, and warp.
- `predictionMarket/market-workflow`: Node/TypeScript automation hooking into Firebase + Gemini + Chainlink CRE; consult `predictionMarket/market-workflow/README.md` for workflow keys and scheduling (Cron + `Runner`).

## Further Reading

- `ARCHITECTURE.md`: this live architecture overview.
- `SECURITY.md`: responsible disclosure and threat model.
- `test/README.md`: testing patterns and coverage goals.
- `script/README.md`: deployment flags, environment variables, and upgrade instructions.

---
Need a quick reminder? Ping the team and reference `predictionMarket/market-workflow/README.md` for automation-specific instructions.
