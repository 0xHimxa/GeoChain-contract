<p align="center">
  <h1 align="center">⚙️ Market Workflow — CRE Automation Engine</h1>
  <p align="center">
    <strong>Full lifecycle market automation powered by Chainlink CRE</strong>
  </p>
  <p align="center">
    <a href="#overview">Overview</a> ·
    <a href="#architecture">Architecture</a> ·
    <a href="#handler-reference">Handlers</a> ·
    <a href="#configuration">Configuration</a> ·
    <a href="#getting-started">Getting Started</a>
  </p>
</p>

---

## Overview

The **market-automation-workflow** is a Chainlink CRE (Compute Runtime Environment) workflow that automates the entire prediction market lifecycle — from AI-powered market creation to cross-chain price synchronization, dispute resolution, and withdrawal processing.

It is deployed as a single CRE workflow graph composed of three trigger types:

| Trigger Type | Count | Purpose |
|---|---|---|
| **Cron** | 8 handlers | Periodic automation (every 30s by default) |
| **HTTP** | 4 handlers | Request-response endpoints (sponsor, execute, revoke, fiat credit) |
| **EVM Log** | 1 handler | Reactive on-chain event processing (ETH deposits) |

### Key Capabilities

- **AI-powered market creation** — Gemini generates unique prediction market questions
- **AI-powered resolution** — Gemini evaluates outcomes with Google Search grounding
- **Cross-chain price sync** — Hub→Spoke canonical price broadcasting via CRE reports
- **Automated liquidity management** — Balance monitoring and top-up across factories
- **Price deviation arbitrage** — Detects and corrects unsafe price bands on spoke chains
- **Gasless sponsored operations** — EIP-712 session-based approval/execution pipeline
- **Fiat onramp** — Off-chain payment → on-chain USDC credit conversion
- **ETH deposit credit** — Reactive log handler converts ETH deposits to USDC credits

---

## Architecture

```
                         ┌─────────────────────────────┐
                         │         main.ts              │
                         │    (Workflow Graph Builder)   │
                         └──────────┬──────────────────┘
                ┌───────────────────┼──────────────────────┐
                │                   │                      │
     ┌──────────▼─────────┐ ┌──────▼──────────┐ ┌────────▼────────┐
     │    Cron Triggers    │ │  HTTP Triggers   │ │  Log Triggers   │
     │   (8 handlers)      │ │  (4 handlers)    │ │  (1 handler)    │
     └──────────┬─────────┘ └──────┬──────────┘ └────────┬────────┘
                │                   │                      │
     ┌──────────▼──────────────────▼──────────────────────▼────────┐
     │                     Shared Infrastructure                    │
     ├──────────────┬──────────────┬──────────────┬────────────────┤
     │   gemini/    │  firebase/   │  payload/    │  contractsAbi/ │
     │  AI calls    │ Firestore IO │ ABI encoding │  Contract ABIs │
     └──────────────┴──────────────┴──────────────┴────────────────┘
```

### Directory Structure

```
market-automation-workflow/
├── main.ts                          # Workflow entry point & graph builder
├── config.staging.json              # Staging deployment configuration
├── config.production.json           # Production deployment configuration
├── workflow.yaml                    # CRE CLI target definitions
├── Constant-variable/
│   └── config.ts                    # TypeScript config types & constants
├── handlers/
│   ├── cronHandlers/
│   │   ├── resolve.ts               # AI market resolution via Gemini
│   │   ├── marketCreation.ts        # AI market creation via Gemini + Firestore
│   │   ├── syncPrice.ts             # Hub→Spoke canonical price broadcasting
│   │   ├── topUpMarket.ts           # Factory/bridge/router balance monitoring
│   │   ├── arbitrage.ts             # Cross-chain price deviation correction
│   │   ├── disputeResolution.ts     # Dispute window monitoring & AI adjudication
│   │   ├── marketWithdrawal.ts      # Pending withdrawal batch processing
│   │   └── manualReviewSync.ts      # Manual review market → Firestore sync
│   ├── httpHandlers/
│   │   ├── httpSponsorPolicy.ts     # Gasless operation approval pipeline
│   │   ├── httpExecuteReport.ts     # Approved operation execution & on-chain submission
│   │   ├── httpRevokeSession.ts     # Session termination
│   │   └── httpFiatCredit.ts        # Fiat payment → USDC credit conversion
│   ├── eventsHandler/
│   │   └── ethCreditFromLogs.ts     # ETH deposit log → USDC credit
│   └── utils/
│       ├── sessionValidation.ts     # EIP-712 session signature verification
│       ├── agentAction.ts           # Action type mappings
│       ├── isHub.ts                 # Hub/spoke chain detection
│       └── payloadBuilder.ts        # ABI payload encoding utilities
├── gemini/
│   ├── resolveEvent.ts              # Gemini AI: market outcome evaluation
│   ├── uniqueEvent.ts               # Gemini AI: unique market question generation
│   └── adjudicateDispute.ts         # Gemini AI: disputed resolution adjudication
├── firebase/
│   ├── signUp.ts                    # Firebase anonymous authentication
│   ├── doclist.ts                   # Firestore document listing
│   ├── write.ts                     # Firestore write operations
│   └── sessionStore.ts             # Approval/session/fiat record management
├── contractsAbi/
│   ├── marketFactory.ts             # MarketFactory ABI
│   ├── predictionMarket.ts          # PredictionMarket ABI
│   ├── routerVault.ts               # RouterVault ABI
│   └── erc20.ts                     # ERC-20 ABI
└── payload/                         # JSON payloads for CRE simulation testing
    ├── sponsor.json
    ├── execute.json
    └── ...
```

---

## Handler Reference

### Cron Handlers

All cron handlers execute on the schedule defined in `config.*.json` (default: `*/30 * * * * *` — every 30 seconds).

---

#### `resolveEvent` — AI Market Resolution

**File:** `handlers/cronHandlers/resolve.ts`

Scans active markets on the hub chain, identifies markets past their resolution time, and uses **Google Gemini AI** with search grounding to determine outcomes.

**Flow:**
1. Reads active market list from hub `MarketFactory`
2. Calls `checkResolutionTime()` on each `PredictionMarket`
3. For eligible markets, reads `getDisputeResolutionSnapshot()` to extract the question
4. Sends question + resolution timestamp to Gemini for evaluation
5. Encodes result (`YES=1`, `NO=2`, `INCONCLUSIVE=3`) with proof URL
6. Submits `ResolveMarket` report to the prediction market contract
7. Triggers withdrawal queue processing after resolution attempts

**On-chain action:** `ResolveMarket` → `PredictionMarket._processReport()`

---

#### `createPredictionMarketEvent` — AI Market Creation

**File:** `handlers/cronHandlers/marketCreation.ts`

Generates new prediction market events using Gemini AI, ensuring uniqueness against existing markets stored in Firestore.

**Flow:**
1. Authenticates with Firebase to obtain an ID token
2. Fetches up to 30 existing events from Firestore (deduplication context)
3. Sends existing events to Gemini, requesting a unique new prediction question
4. Persists the generated event to Firestore for audit trail
5. Submits `createMarket` report to **all configured factories** (hub + spokes)

**On-chain action:** `createMarket` → `MarketFactory._processReport()`

> Also exports `createEventHelper` — a deterministic demo handler for smoke testing without Gemini/Firestore dependencies.

---

#### `syncCanonicalPrice` — Cross-Chain Price Sync

**File:** `handlers/cronHandlers/syncPrice.ts`

Reads live YES/NO probabilities from hub-chain markets and publishes canonical prices to all spoke factories.

**Flow:**
1. Reads active markets from hub `MarketFactory`
2. Resolves `marketId` for each active market
3. Reads `getYesPriceProbability()` and `getNoPriceProbability()` from each hub market
4. Encodes price data with 15-minute validity window (`validUntil`)
5. Submits `syncSpokeCanonicalPrice` reports to each spoke factory

**On-chain action:** `syncSpokeCanonicalPrice` → spoke `MarketFactory._processReport()`

---

#### `marketFactoryBalanceTopUp` — Liquidity Top-Up

**File:** `handlers/cronHandlers/topUpMarket.ts`

Monitors collateral balances across all market factories, their bridges, and routers — automatically topping up when balances fall below configured thresholds.

**Flow:**
1. Reads collateral token balances for each factory, bridge, and router
2. Compares against minimum threshold constants
3. Submits `mintCollateralTo` reports for addresses below threshold

**On-chain action:** `mintCollateralTo` → `MarketFactory._processReport()`

---

#### `arbitrateUnsafeMarketHandler` — Price Deviation Arbitrage

**File:** `handlers/cronHandlers/arbitrage.ts`

Scans every active market across all chains, detects unsafe price deviations from canonical values, and submits correction reports.

**Flow:**
1. Iterates over all configured EVM chains
2. Loads active markets from each factory
3. Calls `getDeviationStatus()` on each market to check deviation band
4. Markets in band `2` (unsafe) with valid correction direction get `priceCorrection` reports
5. Each correction is bounded by `ARB_MAX_SPEND_COLLATERAL` and `ARB_MIN_DEVIATION_IMPROVEMENT_BPS`

**On-chain action:** `priceCorrection` → `MarketFactory._processReport()`

---

#### `adjudicateExpiredDisputeWindows` — Dispute Resolution

**File:** `handlers/cronHandlers/disputeResolution.ts`

Monitors dispute windows for resolved markets and automatically finalizes or adjudicates them.

**Flow:**
1. Loads active markets from the hub factory
2. Reads `getDisputeResolutionSnapshot()` for each market
3. Filters markets in `Resolved` state (state=2) with expired dispute deadlines
4. **Undisputed markets:** submits `FinalizeResolutionAfterDisputeWindow` report
5. **Disputed markets:** sends dispute context to Gemini AI for adjudication, then submits `AdjudicateDisputedResolution` with the AI's determination

**On-chain actions:**
- `FinalizeResolutionAfterDisputeWindow` → `PredictionMarket._processReport()`
- `AdjudicateDisputedResolution` → `PredictionMarket._processReport()`

---

#### `processPendingWithdrawalsHandler` — Withdrawal Processing

**File:** `handlers/cronHandlers/marketWithdrawal.ts`

Batch-processes queued post-resolution withdrawal requests across all configured factories.

**Flow:**
1. Iterates over all configured EVM chains
2. Submits `processPendingWithdrawals` report with configured batch size
3. Tracks success/failure per chain

**On-chain action:** `processPendingWithdrawals` → `MarketFactory._processReport()`

---

#### `syncManualReviewMarketsToFirebase` — Manual Review Sync

**File:** `handlers/cronHandlers/manualReviewSync.ts`

Syncs markets in `Review` state (requiring manual adjudication) to Firestore for dashboard visibility.

**Flow:**
1. Reads `getManualReviewEventList()` from the hub factory
2. For each market, reads dispute resolution snapshot
3. Writes/updates a Firestore document with market metadata (question, state, timestamps)
4. Enables external dashboards to display markets requiring human intervention

---

### HTTP Handlers

HTTP handlers are request-response endpoints protected by ECDSA authorized keys configured in `config.*.json`.

---

#### `sponsorUserOpPolicyHandler` — Gasless Operation Approval

**File:** `handlers/httpHandlers/httpSponsorPolicy.ts`  
**Trigger key set:** `httpTriggerAuthorizedKeys`

Validates and approves gasless operation requests through a multi-layer policy check.

**Validation pipeline:**
1. Policy enabled check
2. Authorized HTTP key verification
3. Chain ID support validation
4. Action allowlist check (8 supported actions)
5. Action → router action type mapping verification
6. Execute policy cross-reference
7. Amount limit enforcement (`maxAmountUsdc`)
8. Slippage limit enforcement (`maxSlippageBps`)
9. Sender address format validation
10. EIP-712 session signature verification
11. Nonce replay protection via Firestore

**On approval:** Creates a short-lived (360s) Firestore approval record for one-time consumption by the execute handler.

**Response:** `SponsorDecision` JSON with `approved`, `reason`, `approvalId`, `approvalExpiresAtUnix`

---

#### `executeReportHttpHandler` — Approved Operation Execution

**File:** `handlers/httpHandlers/httpExecuteReport.ts`  
**Trigger key set:** `httpExecutionAuthorizedKeys`

Consumes a prior sponsor approval and submits the corresponding CRE report on-chain.

**Flow:**
1. Parses and normalizes the execute request (handles legacy field aliases)
2. Validates `approvalId`, `chainId`, `actionType`, `amountUsdc`, `payloadHex`
3. Consumes the matching Firestore approval record exactly once (prevents replay)
4. Routes to the correct receiver (factory vs. router) based on action type
5. Encodes and submits the on-chain report via CRE `writeReport`

**Response:** `ExecuteResponse` JSON with `submitted`, `txHash`, `explorerUrl`

---

#### `revokeSessionHttpHandler` — Session Revocation

**File:** `handlers/httpHandlers/httpRevokeSession.ts`  
**Trigger key set:** `httpTriggerAuthorizedKeys`

Terminates an active user session, invalidating all future sponsor approvals for that session.

---

#### `fiatCreditHttpHandler` — Fiat Payment Credit

**File:** `handlers/httpHandlers/httpFiatCredit.ts`  
**Trigger key set:** `httpFiatCreditAuthorizedKeys`

Credits user router balances from validated off-chain fiat payments.

**Flow:**
1. Validates provider allowlist, chain support, user address, and amount limits
2. Consumes a one-time payment record from Firestore (replay protection)
3. Submits `routerCreditFromFiat` report to the router on the target chain

**Supported providers:** Configurable via `fiatCreditPolicy.allowedProviders` (e.g., `mock`, `stripe`, `google_pay`, `card`)

---

### Event Handlers

#### `ethCreditFromLogsHandler` — ETH Deposit Credit

**File:** `handlers/eventsHandler/ethCreditFromLogs.ts`  
**Trigger:** EVM log — `EthReceived(address,uint256)` event from router contracts

Automatically converts ETH deposits into USDC router credits.

**Flow:**
1. Validates event signature matches `EthReceived`
2. Maps emitting router address to chain config
3. Checks chain support via `ethCreditPolicy`
4. Extracts sender address from indexed topic
5. Converts WEI to USDC using configured `ethToUsdcRateE6`
6. Derives deterministic `depositId` from `keccak256(txHash, logIndex)`
7. Submits `routerCreditFromEth` report

**On-chain action:** `routerCreditFromEth` → `RouterVault._processReport()`

---

## Configuration

### `config.staging.json` Reference

| Key | Type | Description |
|---|---|---|
| `schedule` | `string` | Cron expression for all periodic handlers (default: `*/30 * * * * *`) |
| `httpTriggerAuthorizedKeys` | `AuthKey[]` | ECDSA keys for sponsor/revoke endpoints |
| `httpExecutionAuthorizedKeys` | `AuthKey[]` | ECDSA keys for execute endpoint |
| `httpFiatCreditAuthorizedKeys` | `AuthKey[]` | ECDSA keys for fiat credit endpoint |
| `sponsorPolicy` | `object` | Allowed actions, chain IDs, amount/slippage limits, session config |
| `executePolicy` | `object` | Whitelist of allowed on-chain action types |
| `agentPolicy` | `object` | Agent-specific policy (shared with agents-workflow) |
| `ethCreditPolicy` | `object` | ETH deposit credit enable flag, supported chains, max amount |
| `fiatCreditPolicy` | `object` | Fiat credit enable flag, supported chains, providers, max amount |
| `evms[]` | `EvmConfig[]` | Per-chain: factory address, router address, collateral token, gas limit |

### Required Secrets

Register via `cre secrets set`:

| Secret | Description |
|---|---|
| `AI_KEY` | Google Gemini API key |
| `FIREBASE_API_KEY` | Firebase Web API key |
| `FIREBASE_PROJECT_ID` | Firebase project ID |

---

## Getting Started

### Prerequisites

- [Bun](https://bun.sh) ≥ 1.0
- [Chainlink CRE CLI](https://docs.chain.link/cre)
- Deployed smart contracts (MarketFactory, RouterVault) on target chains

### Install

```bash
cd cre/market-automation-workflow
bun install
```

### Configure

1. Copy and edit `config.staging.json` with your deployed contract addresses
2. Set authorized ECDSA keys for each endpoint group
3. Register secrets:

```bash
cre secrets set AI_KEY <your-gemini-api-key>
cre secrets set FIREBASE_API_KEY <your-firebase-api-key>
cre secrets set FIREBASE_PROJECT_ID <your-firebase-project-id>
```

### Simulate

```bash
# Simulate all cron handlers
cre workflow simulate ./ --target staging-settings --non-interactive --broadcast

# Simulate specific HTTP handler by trigger index
cre workflow simulate ./ \
  --target staging-settings \
  --non-interactive \
  --trigger-index 1 \
  --http-payload "$(cat payload/sponsor.json)" \
  --broadcast
```

### Deploy

```bash
cre workflow deploy --target staging-settings
```

---

## Trigger Index Map

When simulating specific handlers, use `--trigger-index` to target individual triggers:

| Index | Handler | Type |
|---|---|---|
| 0 | `resolveEvent` | Cron |
| 1 | `marketFactoryBalanceTopUp` | Cron |
| 2 | `createPredictionMarketEvent` | Cron |
| 3 | `processPendingWithdrawalsHandler` | Cron |
| 4 | `syncCanonicalPrice` | Cron |
| 5 | `arbitrateUnsafeMarketHandler` | Cron |
| 6 | `adjudicateExpiredDisputeWindows` | Cron |
| 7 | `syncManualReviewMarketsToFirebase` | Cron |
| 8 | `sponsorUserOpPolicyHandler` | HTTP |
| 9 | `revokeSessionHttpHandler` | HTTP |
| 10 | `executeReportHttpHandler` | HTTP |
| 11 | `fiatCreditHttpHandler` | HTTP |
| 12+ | `ethCreditFromLogsHandler` | EVM Log (per chain) |

> **Note:** Indices 8+ only register when their corresponding authorized keys are configured. Log handler indices depend on the number of configured EVM chains with `ethCreditPolicy` enabled.

---

## Related Documentation

- [Agents Workflow README](../agents-workflow/README.md) — Dedicated agent trading CRE workflow
- [Project README](../../README.md) — Full project documentation
