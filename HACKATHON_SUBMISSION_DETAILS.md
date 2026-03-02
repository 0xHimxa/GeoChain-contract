# GeoChain — Hackathon Submission Details

> **Chainlink Convergence 2026 · Team: 0xHimxa**
> **Repository:** [github.com/0xHimxa/GeoChain-contrat](https://github.com/0xHimxa/GeoChain-contrat)

---

## Project Name

**GeoChain** — Self-Operating Cross-Chain Prediction Markets Powered by Chainlink CRE

---

## One-Line Description

A cross-chain prediction market protocol where one Chainlink CRE workflow replaces five backend services — enabling Web2 onboarding, gasless trading without AA/bundlers, AI-assisted market creation, automated cross-chain price sync, and policy-enforced sponsored execution.

---

## What Problem Does This Project Solve?

### The User Problem

Prediction markets today still gate users behind crypto-native onboarding. Users need a wallet extension, a seed phrase, and existing crypto just to start. Even platforms that offer gasless trading rely on Account Abstraction (ERC-4337) bundler infrastructure — services like Pimlico or Stackup, plus Paymaster contracts — which add latency, cost, and yet another service that can fail. Users are also locked into a single chain with no fiat onramp.

### The Operator Problem

Running a prediction market in production requires far more than smart contracts. Operators need separate backend services for:
- Transaction relaying
- Cron-based market maintenance (resolution, price updates)
- Chain event listening (deposits, credits)
- Cross-chain synchronization (hub→spoke price/resolution relay)
- Database locks and retry logic (prevent double credits, double execution)

Each service has its own deployment, monitoring, and failure mode. When one breaks, markets go stale, prices drift, liquidity runs dry, and users are affected — often silently.

### What GeoChain Solves

1. **No AA/bundler dependency** — CRE sponsors execution directly via `writeReport()`. No bundler service, no Paymaster contract, no UserOp mempool. Three layers of infrastructure eliminated.
2. **Web2 onboarding** — Users sign in with email and password. A browser-local encrypted wallet handles signing. No MetaMask, no seed phrase. Non-custodial under the hood.
3. **One workflow replaces 5–6 backend services** — Market creation, price sync, arbitrage, resolution, liquidity top-ups, withdrawal processing, sponsored execution, fiat credit, and ETH deposit credit — all in one CRE workflow runtime.
4. **Cross-chain consistency** — Hub→spoke canonical price propagation and resolution sync via CRE cron handlers + Chainlink CCIP, with on-chain deviation safety rails.
5. **Multi-source funding with replay protection** — USDC deposits, fiat payments (Google Pay, card), and direct ETH transfers all credit the same unified Router Vault, each with explicit replay protection.

---

## How CRE Is Used in This Project

CRE is the **operational backbone** of GeoChain. It is not an add-on feature — it is the system that makes the entire protocol self-operating. We use all three CRE trigger types (Cron, HTTP, EVM Log) across 13 handlers.

### CRE Workflow Entry Point

| File | Description |
|---|---|
| [**main.ts**](https://github.com/0xHimxa/GeoChain-contrat/blob/main/cre/market-workflow/main.ts) | CRE workflow graph — composes all 13 handlers across cron, HTTP, and EVM log triggers into a single `Runner` |
| [**workflow.yaml**](https://github.com/0xHimxa/GeoChain-contrat/blob/main/cre/market-workflow/workflow.yaml) | CRE workflow settings — staging and production targets |
| [**project.yaml**](https://github.com/0xHimxa/GeoChain-contrat/blob/main/cre/project.yaml) | CRE project settings — RPC configuration for Arbitrum Sepolia and Base Sepolia |
| [**config.staging.json**](https://github.com/0xHimxa/GeoChain-contrat/blob/main/cre/market-workflow/config.staging.json) | Workflow config — schedule, policy rules, chain addresses, authorized keys |

---

### CRE Handler: Sponsored Execution Policy

**What it does:** Validates user trade requests against policy rules (action allowlists, amount/slippage limits, chain whitelist, EIP-712 session signatures). On approval, writes a one-time-consumable record to Firestore.

**Why it matters:** Replaces the AA/bundler stack. No Paymaster, no bundler queue — CRE handles policy enforcement directly.

| File | Key Lines |
|---|---|
| [**httpSponsorPolicy.ts**](https://github.com/0xHimxa/GeoChain-contrat/blob/main/cre/market-workflow/handlers/httpHandlers/httpSponsorPolicy.ts) | Full handler — validates chain/action/actionType mapping ([L114–L128](https://github.com/0xHimxa/GeoChain-contrat/blob/main/cre/market-workflow/handlers/httpHandlers/httpSponsorPolicy.ts#L114-L128)), amount/slippage caps ([L148–L165](https://github.com/0xHimxa/GeoChain-contrat/blob/main/cre/market-workflow/handlers/httpHandlers/httpSponsorPolicy.ts#L148-L165)), session validation ([L172–L184](https://github.com/0xHimxa/GeoChain-contrat/blob/main/cre/market-workflow/handlers/httpHandlers/httpSponsorPolicy.ts#L172-L184)), approval record creation ([L189–L198](https://github.com/0xHimxa/GeoChain-contrat/blob/main/cre/market-workflow/handlers/httpHandlers/httpSponsorPolicy.ts#L189-L198)) |

---

### CRE Handler: Execute Report (Approval Consumption)

**What it does:** Consumes a previously created approval record exactly once, resolves the target receiver (Router or Factory based on action type), and submits the on-chain report via `writeReport()`.

**Why it matters:** This is where CRE replaces the transaction relayer. The `writeReport()` call submits the transaction with BFT consensus — no centralized relayer needed.

| File | Key Lines |
|---|---|
| [**httpExecuteReport.ts**](https://github.com/0xHimxa/GeoChain-contrat/blob/main/cre/market-workflow/handlers/httpHandlers/httpExecuteReport.ts) | Approval consumption ([L176–L190](https://github.com/0xHimxa/GeoChain-contrat/blob/main/cre/market-workflow/handlers/httpHandlers/httpExecuteReport.ts#L176-L190)), receiver resolution for Router vs Factory ([L201–L207](https://github.com/0xHimxa/GeoChain-contrat/blob/main/cre/market-workflow/handlers/httpHandlers/httpExecuteReport.ts#L201-L207)), CRE `runtime.report()` + `writeReport()` ([L230–L247](https://github.com/0xHimxa/GeoChain-contrat/blob/main/cre/market-workflow/handlers/httpHandlers/httpExecuteReport.ts#L230-L247)) |

---

### CRE Handler: Fiat Credit

**What it does:** Validates fiat payment callbacks (provider, chain, amount, user), consumes payment records to prevent replay, and submits `routerCreditFromFiat` reports on-chain.

**Why it matters:** Bridges Web2 payment rails (Google Pay, card, Stripe) into the on-chain Router Vault without a separate payment processing service.

| File | Key Lines |
|---|---|
| [**httpFiatCredit.ts**](https://github.com/0xHimxa/GeoChain-contrat/blob/main/cre/market-workflow/handlers/httpHandlers/httpFiatCredit.ts) | Provider validation ([L118–L125](https://github.com/0xHimxa/GeoChain-contrat/blob/main/cre/market-workflow/handlers/httpHandlers/httpFiatCredit.ts#L118-L125)), Firestore payment consumption ([L187–L202](https://github.com/0xHimxa/GeoChain-contrat/blob/main/cre/market-workflow/handlers/httpHandlers/httpFiatCredit.ts#L187-L202)), CRE report submission ([L204–L219](https://github.com/0xHimxa/GeoChain-contrat/blob/main/cre/market-workflow/handlers/httpHandlers/httpFiatCredit.ts#L204-L219)) |

---

### CRE Handler: Session Revocation

**What it does:** Invalidates active user sessions via EIP-712 signed revocation requests.

| File | Key Lines |
|---|---|
| [**httpRevokeSession.ts**](https://github.com/0xHimxa/GeoChain-contrat/blob/main/cre/market-workflow/handlers/httpHandlers/httpRevokeSession.ts) | Full handler — validates revocation signature and marks session as revoked |

---

### CRE Handler: ETH Deposit Credit (EVM Log Trigger)

**What it does:** Listens for `EthReceived(address,uint256)` events emitted by Router contracts. Converts ETH→USDC using configured rate, generates a deterministic `depositId` from `keccak256(txHash, logIndex)`, and submits `routerCreditFromEth` report.

**Why it matters:** This is a real-time, log-driven funding path with no custom event indexer. CRE's native EVM log trigger replaces a separate listener service.

| File | Key Lines |
|---|---|
| [**ethCreditFromLogs.ts**](https://github.com/0xHimxa/GeoChain-contrat/blob/main/cre/market-workflow/handlers/eventsHandler/ethCreditFromLogs.ts) | Event signature matching ([L72–L75](https://github.com/0xHimxa/GeoChain-contrat/blob/main/cre/market-workflow/handlers/eventsHandler/ethCreditFromLogs.ts#L72-L75)), ETH→USDC conversion ([L105–L113](https://github.com/0xHimxa/GeoChain-contrat/blob/main/cre/market-workflow/handlers/eventsHandler/ethCreditFromLogs.ts#L105-L113)), deterministic depositId ([L129–L132](https://github.com/0xHimxa/GeoChain-contrat/blob/main/cre/market-workflow/handlers/eventsHandler/ethCreditFromLogs.ts#L129-L132)), CRE report submission ([L139–L157](https://github.com/0xHimxa/GeoChain-contrat/blob/main/cre/market-workflow/handlers/eventsHandler/ethCreditFromLogs.ts#L139-L157)) |

---

### CRE Handler: Market Creation (Cron)

**What it does:** Authenticates with Firebase, pulls existing events from Firestore, sends them to Gemini AI to generate a new unique market question, persists the event back to Firestore, then submits `createMarket` reports to ALL configured market factories across chains.

**Why it matters:** Markets are created automatically with AI-sourced questions and deployed to multiple chains in one handler execution — no manual intervention, no deploy scripts.

| File | Key Lines |
|---|---|
| [**marketCreation.ts**](https://github.com/0xHimxa/GeoChain-contrat/blob/main/cre/market-workflow/handlers/cronHandlers/marketCreation.ts) | Firebase auth ([L88–L89](https://github.com/0xHimxa/GeoChain-contrat/blob/main/cre/market-workflow/handlers/cronHandlers/marketCreation.ts#L88-L89)), Gemini AI query ([L100](https://github.com/0xHimxa/GeoChain-contrat/blob/main/cre/market-workflow/handlers/cronHandlers/marketCreation.ts#L100)), Firestore write ([L105](https://github.com/0xHimxa/GeoChain-contrat/blob/main/cre/market-workflow/handlers/cronHandlers/marketCreation.ts#L105)), multi-chain report submission ([L108–L116](https://github.com/0xHimxa/GeoChain-contrat/blob/main/cre/market-workflow/handlers/cronHandlers/marketCreation.ts#L108-L116)), `sendActionReport` helper using `runtime.report()` + `writeReport()` ([L35–L80](https://github.com/0xHimxa/GeoChain-contrat/blob/main/cre/market-workflow/handlers/cronHandlers/marketCreation.ts#L35-L80)) |

---

### CRE Handler: Cross-Chain Price Sync (Cron)

**What it does:** Reads live YES/NO probabilities from hub-chain markets, then propagates canonical prices to every spoke factory via `syncSpokeCanonicalPrice` reports with 15-minute validity windows.

**Why it matters:** Ensures spoke-chain markets always reflect hub-chain truth. Stale updates are rejected on-chain. Replaces a separate cross-chain relay service.

| File | Key Lines |
|---|---|
| [**syncPrice.ts**](https://github.com/0xHimxa/GeoChain-contrat/blob/main/cre/market-workflow/handlers/cronHandlers/syncPrice.ts) | Hub price reads via `callContract()` ([L134–L164](https://github.com/0xHimxa/GeoChain-contrat/blob/main/cre/market-workflow/handlers/cronHandlers/syncPrice.ts#L134-L164)), validity window ([L166](https://github.com/0xHimxa/GeoChain-contrat/blob/main/cre/market-workflow/handlers/cronHandlers/syncPrice.ts#L166)), spoke `writeReport()` loop ([L179–L200](https://github.com/0xHimxa/GeoChain-contrat/blob/main/cre/market-workflow/handlers/cronHandlers/syncPrice.ts#L179-L200)) |

---

### CRE Handler: Arbitrage Correction (Cron)

**What it does:** Scans every active market on every chain, checks deviation status via `getDeviationStatus()`, and submits bounded `priceCorrection` reports for markets in unsafe bands.

**Why it matters:** Auto-corrects price manipulation on spoke chains without human intervention.

| File | Key Lines |
|---|---|
| [**arbitrage.ts**](https://github.com/0xHimxa/GeoChain-contrat/blob/main/cre/market-workflow/handlers/cronHandlers/arbitrage.ts) | Deviation status check ([L104–L118](https://github.com/0xHimxa/GeoChain-contrat/blob/main/cre/market-workflow/handlers/cronHandlers/arbitrage.ts#L104-L118)), unsafe band detection ([L120–L126](https://github.com/0xHimxa/GeoChain-contrat/blob/main/cre/market-workflow/handlers/cronHandlers/arbitrage.ts#L120-L126)), bounded correction report ([L151–L171](https://github.com/0xHimxa/GeoChain-contrat/blob/main/cre/market-workflow/handlers/cronHandlers/arbitrage.ts#L151-L171)) |

---

### CRE Handler: Auto-Resolution (Cron)

**What it does:** Iterates all active markets, calls `checkResolutionTime()` on each, and submits `ResolveMarket` reports for eligible ones. After resolution, triggers withdrawal queue processing.

**Why it matters:** Markets resolve automatically when their time arrives — no operator action needed.

| File | Key Lines |
|---|---|
| [**resolve.ts**](https://github.com/0xHimxa/GeoChain-contrat/blob/main/cre/market-workflow/handlers/cronHandlers/resolve.ts) | Resolution time check via `callContract()` ([L86–L100](https://github.com/0xHimxa/GeoChain-contrat/blob/main/cre/market-workflow/handlers/cronHandlers/resolve.ts#L86-L100)), `ResolveMarket` report submission ([L109–L130](https://github.com/0xHimxa/GeoChain-contrat/blob/main/cre/market-workflow/handlers/cronHandlers/resolve.ts#L109-L130)), withdrawal follow-up ([L149](https://github.com/0xHimxa/GeoChain-contrat/blob/main/cre/market-workflow/handlers/cronHandlers/resolve.ts#L149)) |

---

### CRE Handler: Liquidity Top-Up (Cron)

**What it does:** Reads collateral balances for each market factory, its bridge, and its router. When any balance drops below threshold (50K USDC), submits `mintCollateralTo` reports to restore liquidity.

**Why it matters:** Liquidity never runs dry. Markets don't break because someone forgot to fund a contract.

| File | Key Lines |
|---|---|
| [**topUpMarket.ts**](https://github.com/0xHimxa/GeoChain-contrat/blob/main/cre/market-workflow/handlers/cronHandlers/topUpMarket.ts) | Balance reads for factory/bridge/router ([L76–L192](https://github.com/0xHimxa/GeoChain-contrat/blob/main/cre/market-workflow/handlers/cronHandlers/topUpMarket.ts#L76-L192)), threshold check + `mintCollateralTo` report ([L194–L248](https://github.com/0xHimxa/GeoChain-contrat/blob/main/cre/market-workflow/handlers/cronHandlers/topUpMarket.ts#L194-L248)) |

---

### CRE Handler: Withdrawal Processing (Cron)

**What it does:** Drains post-resolution withdrawal queues in batches after markets are resolved.

| File | Key Lines |
|---|---|
| [**marketWithdrawal.ts**](https://github.com/0xHimxa/GeoChain-contrat/blob/main/cre/market-workflow/handlers/cronHandlers/marketWithdrawal.ts) | Full handler — batch withdrawal processing |

---

## Smart Contracts That Receive CRE Reports

CRE handlers submit reports to these contracts using `writeReport()`. The contracts implement `ReceiverTemplateUpgradeable` to process incoming CRE reports.

| Contract | Chain | Address | CRE Actions Received |
|---|---|---|---|
| [**MarketFactory**](https://github.com/0xHimxa/GeoChain-contrat/blob/main/contract/src/marketFactory/MarketFactoryBase.sol) | Arbitrum Sepolia | `0x145A8D0eD56fd02A8b29b2E81C09F5d66e1918Ec` | `createMarket`, `mintCollateralTo`, `priceCorrection`, `syncSpokeCanonicalPrice` |
| [**MarketFactory**](https://github.com/0xHimxa/GeoChain-contrat/blob/main/contract/src/marketFactory/MarketFactoryBase.sol) | Base Sepolia | `0x54DDeC2F7420b3AF1BB53157f3c533F9Ad598651` | Same as above (spoke) |
| [**PredictionMarket**](https://github.com/0xHimxa/GeoChain-contrat/blob/main/contract/src/predictionMarket/PredictionMarket.sol) | Both | Per-market clone | `ResolveMarket` |
| [**RouterVault**](https://github.com/0xHimxa/GeoChain-contrat/blob/main/contract/src/router/PredictionMarketRouterVaultOperations.sol) | Arbitrum Sepolia | `0x3E6206fa635C74288C807ee3ba90C603a82B94A8` | `routerMintCompleteSets`, `routerSwapYesForNo`, `routerSwapNoForYes`, `routerRedeemCompleteSets`, `routerRedeem`, `routerCreditFromFiat`, `routerCreditFromEth` |
| [**RouterVault**](https://github.com/0xHimxa/GeoChain-contrat/blob/main/contract/src/router/PredictionMarketRouterVaultOperations.sol) | Base Sepolia | `0x1381A3b6d81BA62bb256607Cc2BfBBd5271DD525` | Same as above |

---

## Smart Contract CRE Integration — Exact Code Locations

These are the contract-side functions where CRE reports land and get dispatched. Every CRE `writeReport()` call from the workflow ultimately hits one of these `_processReport` dispatchers.

### MarketFactory — CRE Report Dispatcher

The factory handles 9 CRE action types for market operations, price management, and liquidity.

| File | What | Lines |
|---|---|---|
| [**MarketFactoryOperations.sol**](https://github.com/0xHimxa/GeoChain-contrat/blob/main/contract/src/marketFactory/MarketFactoryOperations.sol) | `_processReport()` — main dispatcher decoding `(string actionType, bytes payload)` and routing by action hash | [L24–L70](https://github.com/0xHimxa/GeoChain-contrat/blob/main/contract/src/marketFactory/MarketFactoryOperations.sol#L24-L70) |
| ↳ Same file | `_arbitrateUnsafeMarket()` — bounded corrective arbitrage triggered by CRE `priceCorrection` reports | [L104–L147](https://github.com/0xHimxa/GeoChain-contrat/blob/main/contract/src/marketFactory/MarketFactoryOperations.sol#L104-L147) |
| ↳ Same file | `_processPendingWithdrawals()` — batch queue processor triggered by CRE `processPendingWithdrawals` reports | [L271–L314](https://github.com/0xHimxa/GeoChain-contrat/blob/main/contract/src/marketFactory/MarketFactoryOperations.sol#L271-L314) |
| [**MarketFactoryBase.sol**](https://github.com/0xHimxa/GeoChain-contrat/blob/main/contract/src/marketFactory/MarketFactoryBase.sol) | `ReceiverTemplateUpgradeable` inheritance — enables CRE report receiving | [L11](https://github.com/0xHimxa/GeoChain-contrat/blob/main/contract/src/marketFactory/MarketFactoryBase.sol#L11), [L30](https://github.com/0xHimxa/GeoChain-contrat/blob/main/contract/src/marketFactory/MarketFactoryBase.sol#L30) |
| ↳ Same file | `__ReceiverTemplateUpgradeable_init()` — initializes CRE forwarder during proxy setup | [L222](https://github.com/0xHimxa/GeoChain-contrat/blob/main/contract/src/marketFactory/MarketFactoryBase.sol#L222) |
| [**MarketFactoryCcip.sol**](https://github.com/0xHimxa/GeoChain-contrat/blob/main/contract/src/marketFactory/MarketFactoryCcip.sol) | `_broadcastCanonicalPrice()` — CCIP sender triggered by CRE `broadCastPrice` reports | Hub factory file |
| ↳ Same file | `_syncSpokeCanonicalPrice()` — applies canonical price from CRE `syncSpokeCanonicalPrice` reports | Spoke factory file |
| ↳ Same file | `_broadcastResolution()` — CCIP sender triggered by CRE `broadCastResolution` reports | Hub factory file |

**CRE actions dispatched in MarketFactory:**

| Action String | CRE Handler Source | What It Does On-Chain |
|---|---|---|
| `broadCastPrice` | `syncPrice.ts` | Hub broadcasts canonical price via CCIP to spokes |
| `syncSpokeCanonicalPrice` | `syncPrice.ts` | Spoke applies received canonical price |
| `broadCastResolution` | `resolve.ts` | Hub broadcasts resolution outcome via CCIP to spokes |
| `createMarket` | `marketCreation.ts` | Deploys new PredictionMarket + seeds liquidity |
| `priceCorrection` | `arbitrage.ts` | Bounded swap to correct unsafe price deviation |
| `addLiquidityToFactory` | `topUpMarket.ts` | Adds liquidity to factory |
| `mintCollateralTo` | `topUpMarket.ts` | Mints USDC to a specified receiver (factory/bridge/router) |
| `withDrawCollatralAndFee` | `resolve.ts` | Withdraws LP collateral + protocol fees from a market |
| `processPendingWithdrawals` | `marketWithdrawal.ts` | Drains withdrawal queue in batches |

---

### PredictionMarket — CRE Report Dispatcher

Each market contract handles one CRE action: `ResolveMarket`.

| File | What | Lines |
|---|---|---|
| [**PredictionMarketResolution.sol**](https://github.com/0xHimxa/GeoChain-contrat/blob/main/contract/src/predictionMarket/PredictionMarketResolution.sol) | `_processReport()` — dispatcher for `ResolveMarket` action, calls `_resolve()` | [L167–L175](https://github.com/0xHimxa/GeoChain-contrat/blob/main/contract/src/predictionMarket/PredictionMarketResolution.sol#L167-L175) |
| ↳ Same file | `_resolve()` — core resolution logic invoked by CRE report | [L27–L54](https://github.com/0xHimxa/GeoChain-contrat/blob/main/contract/src/predictionMarket/PredictionMarketResolution.sol#L27-L54) |
| ↳ Same file | `checkResolutionTime()` — queried by CRE `resolve.ts` handler to determine eligibility | [L179–L181](https://github.com/0xHimxa/GeoChain-contrat/blob/main/contract/src/predictionMarket/PredictionMarketResolution.sol#L179-L181) |
| ↳ Same file | `syncCanonicalPriceFromHub()` — applies hub price with strict nonce ordering (called via CCIP, which is triggered by CRE) | [L146–L163](https://github.com/0xHimxa/GeoChain-contrat/blob/main/contract/src/predictionMarket/PredictionMarketResolution.sol#L146-L163) |
| ↳ Same file | `resolveFromHub()` — cross-chain resolution callback (called via CCIP, which is triggered by CRE) | [L129–L141](https://github.com/0xHimxa/GeoChain-contrat/blob/main/contract/src/predictionMarket/PredictionMarketResolution.sol#L129-L141) |
| [**PredictionMarketBase.sol**](https://github.com/0xHimxa/GeoChain-contrat/blob/main/contract/src/predictionMarket/PredictionMarketBase.sol) | `ReceiverTemplateUpgradeable` inheritance | [L15](https://github.com/0xHimxa/GeoChain-contrat/blob/main/contract/src/predictionMarket/PredictionMarketBase.sol#L15), [L19](https://github.com/0xHimxa/GeoChain-contrat/blob/main/contract/src/predictionMarket/PredictionMarketBase.sol#L19) |
| ↳ Same file | `__ReceiverTemplateUpgradeable_init()` — initializes CRE forwarder | [L147](https://github.com/0xHimxa/GeoChain-contrat/blob/main/contract/src/predictionMarket/PredictionMarketBase.sol#L147) |
| [**PredictionMarket.sol**](https://github.com/0xHimxa/GeoChain-contrat/blob/main/contract/src/predictionMarket/PredictionMarket.sol) | `getDeviationStatus()` — queried by CRE `arbitrage.ts` to check if market needs correction | [L94–L140](https://github.com/0xHimxa/GeoChain-contrat/blob/main/contract/src/predictionMarket/PredictionMarket.sol#L94-L140) |

---

### Router Vault — CRE Report Dispatcher

The router handles 12 CRE action types for all user-facing trading operations and funding credits.

| File | What | Lines |
|---|---|---|
| [**PredictionMarketRouterVaultOperations.sol**](https://github.com/0xHimxa/GeoChain-contrat/blob/main/contract/src/router/PredictionMarketRouterVaultOperations.sol) | `_processReport()` — main dispatcher routing 12 action types | [L344–L391](https://github.com/0xHimxa/GeoChain-contrat/blob/main/contract/src/router/PredictionMarketRouterVaultOperations.sol#L344-L391) |
| ↳ Same file | `_mintCompleteSets()` — mints YES+NO tokens from collateral credits (CRE `routerMintCompleteSets`) | [L146–L178](https://github.com/0xHimxa/GeoChain-contrat/blob/main/contract/src/router/PredictionMarketRouterVaultOperations.sol#L146-L178) |
| ↳ Same file | `_redeemCompleteSets()` — burns YES+NO tokens back to collateral (CRE `routerRedeemCompleteSets`) | [L181–L206](https://github.com/0xHimxa/GeoChain-contrat/blob/main/contract/src/router/PredictionMarketRouterVaultOperations.sol#L181-L206) |
| ↳ Same file | `_redeem()` — redeems winning tokens after resolution (CRE `routerRedeem`) | [L209–L241](https://github.com/0xHimxa/GeoChain-contrat/blob/main/contract/src/router/PredictionMarketRouterVaultOperations.sol#L209-L241) |
| ↳ Same file | `_swapYesForNo()` — AMM swap (CRE `routerSwapYesForNo`) | [L244–L263](https://github.com/0xHimxa/GeoChain-contrat/blob/main/contract/src/router/PredictionMarketRouterVaultOperations.sol#L244-L263) |
| ↳ Same file | `_swapNoForYes()` — AMM swap (CRE `routerSwapNoForYes`) | [L266–L284](https://github.com/0xHimxa/GeoChain-contrat/blob/main/contract/src/router/PredictionMarketRouterVaultOperations.sol#L266-L284) |
| ↳ Same file | `_addLiquidity()` — adds LP from internal credits (CRE `routerAddLiquidity`) | [L288–L312](https://github.com/0xHimxa/GeoChain-contrat/blob/main/contract/src/router/PredictionMarketRouterVaultOperations.sol#L288-L312) |
| ↳ Same file | `_removeLiquidity()` — removes LP to internal credits (CRE `routerRemoveLiquidity`) | [L315–L340](https://github.com/0xHimxa/GeoChain-contrat/blob/main/contract/src/router/PredictionMarketRouterVaultOperations.sol#L315-L340) |
| ↳ Same file | `_creditCollateralFromFiat()` — credits from fiat (CRE `routerCreditFromFiat`) | [L127–L132](https://github.com/0xHimxa/GeoChain-contrat/blob/main/contract/src/router/PredictionMarketRouterVaultOperations.sol#L127-L132) |
| ↳ Same file | `_creditCollateralFromEth()` — credits from ETH with replay protection (CRE `routerCreditFromEth`) | [L135–L143](https://github.com/0xHimxa/GeoChain-contrat/blob/main/contract/src/router/PredictionMarketRouterVaultOperations.sol#L135-L143) |

**CRE actions dispatched in Router Vault:**

| Action String | CRE Handler Source | What It Does On-Chain |
|---|---|---|
| `routerMintCompleteSets` | `httpExecuteReport.ts` | Mints YES+NO tokens from user collateral credits |
| `routerRedeemCompleteSets` | `httpExecuteReport.ts` | Burns YES+NO tokens back to collateral credits |
| `routerRedeem` | `httpExecuteReport.ts` | Redeems winning tokens after resolution |
| `routerSwapYesForNo` | `httpExecuteReport.ts` | Swaps YES→NO through market AMM |
| `routerSwapNoForYes` | `httpExecuteReport.ts` | Swaps NO→YES through market AMM |
| `routerAddLiquidity` | `httpExecuteReport.ts` | Adds LP from internal credits |
| `routerRemoveLiquidity` | `httpExecuteReport.ts` | Removes LP to internal credits |
| `routerCreditFromFiat` | `httpFiatCredit.ts` | Credits user from fiat payment |
| `routerCreditFromEth` | `ethCreditFromLogs.ts` | Credits user from ETH deposit (replay-safe via `depositId`) |
| `routerDepositFor` | `httpExecuteReport.ts` | Deposits collateral for a user |
| `routerWithdrawCollateral` | `httpExecuteReport.ts` | Withdraws collateral credits |
| `routerWithdrawOutcome` | `httpExecuteReport.ts` | Withdraws outcome token credits |

---

## Frontend Integration with CRE

The frontend doesn't call CRE directly — it sends requests to an API bridge that formats payloads for CRE HTTP triggers.

| File | CRE Integration |
|---|---|
| [**App.tsx**](https://github.com/0xHimxa/GeoChain-contrat/blob/main/frontend/minimal-sponsor-ui/src/App.tsx) | Constructs EIP-712 session grants ([L441–L466](https://github.com/0xHimxa/GeoChain-contrat/blob/main/frontend/minimal-sponsor-ui/src/App.tsx#L441-L466)), sponsor intent signatures ([L468–L490](https://github.com/0xHimxa/GeoChain-contrat/blob/main/frontend/minimal-sponsor-ui/src/App.tsx#L468-L490)), submits to sponsor+execute flow ([L492–L513](https://github.com/0xHimxa/GeoChain-contrat/blob/main/frontend/minimal-sponsor-ui/src/App.tsx#L492-L513)) |
| [**server.ts**](https://github.com/0xHimxa/GeoChain-contrat/blob/main/frontend/minimal-sponsor-ui/server.ts) | Formats and writes CRE input payloads: sponsor.json ([L233–L238](https://github.com/0xHimxa/GeoChain-contrat/blob/main/frontend/minimal-sponsor-ui/server.ts#L233-L238)), execute.json ([L240–L243](https://github.com/0xHimxa/GeoChain-contrat/blob/main/frontend/minimal-sponsor-ui/server.ts#L240-L243)), fiat.json ([L245–L248](https://github.com/0xHimxa/GeoChain-contrat/blob/main/frontend/minimal-sponsor-ui/server.ts#L245-L248)) |

---

## CRE External Service Integrations

| Service | How CRE Connects | Files |
|---|---|---|
| **Firebase Auth** | `signUpWorkFlow()` authenticates for Firestore access | [firebase/signUp.ts](https://github.com/0xHimxa/GeoChain-contrat/blob/main/cre/market-workflow/firebase/signUp.ts) |
| **Firestore** | Market events, approval records, payment records, session data | [firebase/doclist.ts](https://github.com/0xHimxa/GeoChain-contrat/blob/main/cre/market-workflow/firebase/doclist.ts), [firebase/write.ts](https://github.com/0xHimxa/GeoChain-contrat/blob/main/cre/market-workflow/firebase/write.ts), [firebase/sessionStore.ts](https://github.com/0xHimxa/GeoChain-contrat/blob/main/cre/market-workflow/firebase/sessionStore.ts) |
| **Gemini AI** | Generates unique market questions from trending events | [gemini/uniqueEvent.ts](https://github.com/0xHimxa/GeoChain-contrat/blob/main/cre/market-workflow/gemini/uniqueEvent.ts) |
| **Arbitrum Sepolia** | Hub chain — market creation, resolution, price source | via `EVMClient` in all handlers |
| **Base Sepolia** | Spoke chain — mirrors markets, receives price/resolution sync | via `EVMClient` in all handlers |

---

## CRE SDK Capabilities Used

| CRE Capability | SDK Import | Usage |
|---|---|---|
| Cron scheduling | `CronCapability` | Triggers 6 market lifecycle handlers every 30 seconds |
| HTTP endpoints | `HTTPCapability` | 4 handlers: sponsor policy, execute, fiat credit, session revoke |
| EVM log listening | `EVMClient.logTrigger()` | 1 handler: ETH deposit credit from `EthReceived` events |
| On-chain reads | `EVMClient.callContract()` | Read market lists, prices, balances, deviation status |
| On-chain writes | `EVMClient.writeReport()` | Submit consensus-signed reports to contracts |
| BFT report signing | `runtime.report()` | Request DON consensus on every report payload |
| Network resolution | `getNetwork()` | Resolve chain selectors for multi-chain operations |
| Calldata encoding | `encodeCallMsg()` | Encode contract call parameters |
| Hex conversion | `bytesToHex()` | Convert byte arrays from chain reads |
| Report preparation | `prepareReportRequest()` | Format report data for consensus signing |
| Transaction status | `TxStatus` | Check for `REVERTED` status on write operations |
| Workflow composition | `handler()`, `Runner` | Compose trigger→handler pairs and start the runtime |
| Configuration | `runtime.config` | Access unified config model (chains, policies, keys) |
| Logging | `runtime.log()` | Unified observability across DON nodes |
| Time | `runtime.now()` | Timestamp for approvals, validity windows |

---

## Tech Stack

| Layer | Technology |
|---|---|
| Smart Contracts | Solidity 0.8.33, Foundry, OpenZeppelin (UUPS, ReentrancyGuard, SafeERC20) |
| CRE Workflow | TypeScript, `@chainlink/cre-sdk`, compiled to WASM |
| Cross-Chain | Chainlink CCIP (hub-spoke price + resolution sync) |
| AI | Google Gemini (market question generation) |
| Database | Firebase / Firestore (events, approvals, payments, sessions) |
| Frontend | React, Vite, TypeScript, TailwindCSS, ethers.js |
| Testnets | Arbitrum Sepolia (hub), Base Sepolia (spoke) |

---

## Deployed Contract Addresses

| Chain | Contract | Address |
|---|---|---|
| Arbitrum Sepolia | MarketFactory (UUPS Proxy) | `0x145A8D0eD56fd02A8b29b2E81C09F5d66e1918Ec` |
| Arbitrum Sepolia | Router Vault | `0x3E6206fa635C74288C807ee3ba90C603a82B94A8` |
| Arbitrum Sepolia | Bridge | `0x0043866570462b0495eC23d780D873aF1afA1711` |
| Arbitrum Sepolia | Collateral (USDC) | `0x28dF0b4CD6d0627134b708CCAfcF230bC272a663` |
| Base Sepolia | MarketFactory (UUPS Proxy) | `0x54DDeC2F7420b3AF1BB53157f3c533F9Ad598651` |
| Base Sepolia | Router Vault | `0x1381A3b6d81BA62bb256607Cc2BfBBd5271DD525` |
| Base Sepolia | Bridge | `0xf898E8b44513F261a13EfF8387eC7b58baB4846e` |
| Base Sepolia | Collateral (USDC) | `0x15a6D5380397644076f13D76B648A45B29e754bc` |
