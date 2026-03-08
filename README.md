<p align="center">
  <h1 align="center">🌐 GeoChain — Autonomous Prediction Markets</h1>
  <p align="center">
    <strong>AI-Powered · Cross-Chain · Agent-Native Prediction Markets built on Chainlink CRE</strong>
  </p>
  <p align="center">
    <a href="#the-problem">Problem</a> ·
    <a href="#how-it-was-done-before">Prior Art</a> ·
    <a href="#how-geochain-changes-everything">Our Approach</a> ·
    <a href="#architecture">Architecture</a> ·
    <a href="#getting-started">Getting Started</a> ·
    <a href="#deployed-contracts">Contracts</a>
  </p>
</p>

> **Submitted to [Convergence: A Chainlink Hackathon](https://chain.link/hackathon) — February 6 – March 8, 2026**
>
> Tracks: **Prediction Markets · DeFi · AI Agents**

---

## The Problem

Prediction markets promise the "wisdom of crowds" — but today's platforms are broken in ways that prevent them from reaching their potential.

### 1. Centralized Resolution & Oracle Manipulation

Polymarket — the largest prediction market by volume — relies on **UMA's optimistic oracle** for resolution. In late 2025, whale investors exploited the oracle bonding mechanism to force a false market resolution, profiting from an outcome that contradicted reality. In early 2026, the platform was forced into **centralized intervention** on a market, contradicting the very immutability promises of smart contracts.

The root problem: resolution depends on a single oracle path with weak dispute incentives, creating a single point of failure that deep-pocketed actors can exploit.

### 2. Single-Chain Liquidity Silos

Every major prediction market (Polymarket on Polygon, Augur on Ethereum, Azuro on Gnosis) locks liquidity on a single chain. Users on other chains must bridge, swap, and manage gas across ecosystems just to participate. The result:

- **Fragmented liquidity** across chains
- **High friction** prevents casual participation
- **No canonical pricing** — the same event can trade at different prices on different deployments with no mechanism to sync them

### 3. Manual Market Operations at Every Step

Creating markets, seeding liquidity, monitoring positions, resolving outcomes, syncing prices, topping up factory balances — every operational step requires a human operator watching dashboards and sending transactions manually. This doesn't scale, and it introduces delays that harm market efficiency.

### 4. No Agent-Native Infrastructure

The rise of AI trading agents creates a new class of market participant, but no prediction market platform today provides **native, on-chain infrastructure** for agent delegation. Users who want an AI agent to trade on their behalf must hand over private keys or trust custodial services — neither is acceptable.

### 5. No Cross-Chain Position Portability

Once you hold outcome tokens (YES/NO) on one chain, they're stuck there. There is no standardized way to bridge prediction market claims cross-chain, meaning users can't move their positions to chains with better liquidity, lower fees, or different DeFi composability.

---

## How It Was Done Before

| Aspect | Polymarket | Augur v2 | Azuro |
|---|---|---|---|
| **Resolution** | UMA optimistic oracle — single-path, bond-based disputes | Decentralized reporting + dispute rounds, but extremely slow (days to weeks) | Centralized data provider oracles |
| **Chains** | Polygon only | Ethereum mainnet only | Gnosis Chain only |
| **Market Creation** | Centralized team curates and creates markets manually | Permissionless but required substantial ETH bonds | Protocol-controlled, bookmaker model |
| **Automation** | None on-chain; backend servers handle indexing | Keepers for finalization, but no lifecycle automation | Centralized backend |
| **Agent Support** | None — users trade directly or via API wrappers with full key access | None | None |
| **Cross-Chain Claims** | None | None | None |
| **Price Consistency** | Single deployment — not applicable | Single deployment | Single deployment |
| **Dispute Mechanism** | Bond escalation (exploitable by whales) | Multi-round fork mechanism (complex, slow) | None (trust the oracle) |

**The common pattern**: every platform treats prediction markets as static, single-chain, human-operated contracts with no automation layer and no agent infrastructure.

---

## How GeoChain Changes Everything

GeoChain is a **full-stack autonomous prediction market protocol** that rethinks every layer — from who creates markets to how they resolve, how prices stay consistent across chains, and how AI agents participate safely.

### ✦ AI-Powered Resolution via Chainlink CRE + Gemini

Instead of relying on a single oracle with weak dispute bonds, GeoChain uses **Chainlink Runtime Environment (CRE)** workflows that call **Google Gemini AI** with Google Search grounding to determine event outcomes:

- Gemini AI acts as a **deterministic, adversarial-resistant resolution engine** — it's prompt-engineered to resist manipulation, handle edge cases (event cancellation, postponement, contradictory sources), and require source URLs for every determination
- The CRE workflow runs on Chainlink's decentralized infrastructure, ensuring the AI call and on-chain report delivery are **verifiable and tamper-proof**
- Results are stored in **Firebase Firestore** for a complete audit trail
- If evidence is inconclusive, the market enters a `Review` state for **manual adjudication** — never a forced binary outcome

```
Event ends → CRE cron detects resolution time → Gemini AI evaluates with search grounding
→ Signed report delivered on-chain → Dispute window opens → Resolution finalizes
```

### ✦ Full Lifecycle Automation (Not Just Resolution)

GeoChain doesn't just automate resolution — it automates the **entire market lifecycle** through CRE workflows:

| Automated Action | Workflow | Handler | Trigger |
|---|---|---|---|
| **Market Creation** | `market-automation-workflow` | `createPredictionMarketEvent` | Cron — Gemini generates unique event ideas, deploys on-chain |
| **Market Resolution** | `market-automation-workflow` | `resoloveEvent` | Cron — detects markets past resolution time, calls Gemini |
| **Liquidity Top-Up** | `market-automation-workflow` | `marketFactoryBalanceTopUp` | Cron — monitors factory balance, auto-replenishes |
| **Price Sync** | `market-automation-workflow` | `syncCanonicalPrice` | Cron — CRE reads hub prices and writes canonical sync reports directly to spoke factories |
| **Unsafe Market Arbitrage** | `market-automation-workflow` | `arbitrateUnsafeMarketHandler` | Cron — corrects price deviations across chains |
| **Dispute Adjudication** | `market-automation-workflow` | `adjudicateExpiredDisputeWindows` | Cron — auto-finalizes undisputed resolutions |
| **Withdrawal Processing** | `market-automation-workflow` | `processPendingWithdrawalsHandler` | Cron — batch-processes queued LP withdrawals |
| **Gasless User Operations** | `market-users-workflow` | `sponsorUserOpPolicyHandler` + `executeReportHttpHandler` | HTTP — validates signatures, creates approvals, and submits user actions |
| **Fiat Credit Onboarding** | `market-users-workflow` | `fiatCreditHttpHandler` | HTTP — credits user balances from off-chain payments |
| **ETH Deposit Credit** | `market-users-workflow` | `ethCreditFromLogsHandler` | EVM Log — detects ETH deposits, credits router balances |

Every operation previously requiring a human operator is now an autonomous CRE workflow.

### ✦ Hub-Spoke Cross-Chain Architecture via CCIP

GeoChain deploys as a **hub-spoke topology** across multiple chains:

```
                    ┌──────────────────┐
                    │   Hub Factory    │
                    │ (Arbitrum Sepolia)│
                    └────────┬─────────┘
                 CCIP CanonicalPriceSync
                 CCIP ResolutionSync
              ┌──────────┴──────────┐
    ┌─────────┴─────────┐ ┌────────┴──────────┐
    │  Spoke Factory    │ │  Spoke Factory     │
    │  (Base Sepolia)   │ │  (Future Chains)   │
    └───────────────────┘ └────────────────────┘
```

- **Hub factories** are the source of truth — they broadcast canonical prices and resolution outcomes via Chainlink CCIP
- **Spoke factories** accept CCIP messages from trusted remotes and enforce canonical pricing on local AMMs
- **Deviation bands** (`softDeviationBps`, `stressDeviationBps`, `hardDeviationBps`) protect spoke markets — when local AMM prices deviate too far from hub canonical prices, the system progressively applies:
  - Direction restrictions (only allow price-correcting trades)
  - Extra swap fees
  - Max output caps
  - Full **circuit breaker** halt at extreme deviation

### ✦ Agent-Native Trading Infrastructure (6-Layer Security)

GeoChain is the first prediction market with **native on-chain agent delegation**. Users can authorize an AI agent to trade on their behalf without surrendering custody:

```
User ──setAgentPermission()──► Router ──_authorizeAgent()──► Execute
        (actionMask,                    (enabled? expired?
         maxAmountPerAction,             action allowed?
         expiresAt)                      amount within cap?)
```

**The 6 security layers (defense-in-depth):**

| Layer | Protection | Where |
|---|---|---|
| 1 | HTTP authorized keys | CRE trigger gate |
| 2 | Sponsor policy + EIP-712 session signatures | CRE handler |
| 3 | Firestore one-time approval + nonce replay protection | CRE state |
| 4 | Execute policy action allowlist | CRE handler |
| 5 | On-chain `_authorizeAgent()` — permission, expiry, action mask, amount cap | Smart contract |
| 6 | Router market/risk balance checks | Smart contract |

Key design principle: **funds never leave the router**. The agent is an executor with scoped permission, not a custodian. Even if all off-chain layers are compromised, on-chain `_authorizeAgent()` still blocks unauthorized actions.

The agent API flow:
```
POST /agent/plan     →  Validate intent, normalize parameters
POST /agent/sponsor  →  Session signature verification, approval creation
POST /agent/execute  →  Consume approval, encode payload, submit on-chain
POST /agent/revoke   →  Terminate agent session
```

### ✦ Three Dedicated CRE Workflows

GeoChain now runs **three independently deployed CRE workflows** so operational automation, human user operations, and AI agent trading are isolated by trigger type, key set, and policy scope:

```
┌──────────────────────────────────────────────────────────────────────────────────────────┐
│                                 CRE WORKFLOW DEPLOYMENTS                                 │
├────────────────────────────┬────────────────────────────┬────────────────────────────────┤
│ market-automation-workflow │   market-users-workflow    │        agents-workflow         │
│  (Operational Automation)  │   (User Ops + Credits)     │     (Agent Trading Engine)     │
├────────────────────────────┼────────────────────────────┼────────────────────────────────┤
│ • Cron: market creation    │ • HTTP: sponsorUserOpPolicy│ • HTTP: agentPlanTrade         │
│ • Cron: resolution via AI  │ • HTTP: executeReport      │ • HTTP: agentSponsorTrade      │
│ • Cron: liquidity top-up   │ • HTTP: revokeSession      │ • HTTP: agentExecuteTrade      │
│ • Cron: price sync         │ • HTTP: fiatCredit         │ • HTTP: agentRevoke            │
│ • Cron: arbitrage          │ • Log: ethCreditFromLogs   │                                │
│ • Cron: dispute adjudicate │                            │                                │
│ • Cron: withdrawal process │                            │                                │
│ • Cron: manual review sync │                            │                                │
└────────────────────────────┴────────────────────────────┴────────────────────────────────┘
```

**Why three workflows?** These responsibilities now have materially different risk profiles and trigger surfaces:
- Independent deployment and upgrade cycles
- Different authorized key sets — automation keys, user-op keys, and agent keys are scoped separately
- Isolated failure domains — an HTTP/signature issue can't break cron-based market automation
- Clearer policy separation (`sponsorPolicy`, `executePolicy`, `fiatCreditPolicy`, `ethCreditPolicy`, `agentPolicy`)

#### The 4 Agent Handlers

| Handler | Purpose | What It Does |
|---|---|---|
| **`agentPlanTrade`** | Intent validation | Validates action, chain, addresses, amount against `agentPolicy` (allowed actions, max amount, max slippage, supported chains). Produces a deterministic plan object. Rejects ambiguous or out-of-policy requests before any state is created. |
| **`agentSponsorTrade`** | Authorization bridge | Converts the agent plan into the standard sponsor format and routes it through `sponsorUserOpPolicyHandler` — reusing the same session-signature, nonce replay, and approval creation logic used by human-initiated trades. No second security path. |
| **`agentExecuteTrade`** | Payload encoding + submission | Maps the agent action to its `routerAgent...` action type, ABI-encodes the payload via `buildAgentPayloadHex`, and delegates to `executeReportHttpHandler` which consumes the one-time approval and submits the on-chain report. |
| **`agentRevoke`** | Session termination | Delegates to the canonical session-revoke handler, ensuring a single revocation validation path that prevents policy drift between agent and non-agent revocation. |

#### Agent Frontend (`AgentApp.tsx`)

The frontend provides a complete UI for the agent trading flow:
- **Wallet setup**: browser-local session key generation for gasless operation
- **Permission management**: UI to set `actionMask` (bitfield checkboxes for each action), `maxAmountPerAction`, and `expiresAt` by calling `setAgentPermission()` on-chain
- **Trade execution**: step-through UI for Plan → Sponsor → Execute with live status
- **Session revocation**: one-click agent permission revocation

### ✦ Cross-Chain Position Bridge

GeoChain introduces a **PredictionMarketBridge** contract that enables cross-chain portability of outcome token claims:

- **Lock & Bridge**: Lock YES/NO outcome tokens on the source chain → CCIP message → mint wrapped claim tokens on the destination chain
- **Burn & Unlock**: Burn wrapped claims on the destination chain → CCIP message → unlock original tokens on the source chain
- **Collateral Buyback**: Sell wrapped claim tokens directly for collateral on the destination chain (with configurable buyback ratio)
- Replay protection, trusted-remote checks, and winning-side validation are enforced in both directions

### ✦ Gasless Participation via Sponsored Operations

The Router Vault contract + CRE HTTP handlers enable a **fully gasless user experience**:

- Users sign EIP-712 typed data off-chain (no gas)
- CRE validates the signature, creates an approval, and submits the transaction on-chain
- Session-based authorization with per-request nonce replay protection
- Supports: minting, swapping, redeeming, adding/removing liquidity, disputes — all gasless

---

## Architecture

### Smart Contracts

```
contract/src/
├── predictionMarket/
│   ├── PredictionMarket.sol          # Main entry — inherits all modules
│   ├── PredictionMarketBase.sol      # State, modifiers, canonical pricing controls
│   ├── PredictionMarketLiquidity.sol # AMM swaps, LP accounting, complete sets
│   └── PredictionMarketResolution.sol# Resolution, disputes, CRE report processing
├── marketFactory/
│   ├── MarketFactory.sol             # UUPS proxy entry point
│   ├── MarketFactoryBase.sol         # Market registry, collateral management
│   ├── MarketFactoryCcip.sol         # CCIP send/receive for hub-spoke sync
│   └── MarketFactoryOperations.sol   # CRE _processReport dispatcher
├── router/
│   ├── PredictionMarketRouterVault.sol          # Proxy entry
│   ├── PredictionMarketRouterVaultBase.sol      # User credits, agent permissions
│   └── PredictionMarketRouterVaultOperations.sol# All user & agent-delegated actions
├── Bridge/
│   ├── PredictionMarketBridge.sol    # Cross-chain claim lock/mint/burn/unlock
│   └── BridgeWrappedClaimToken.sol   # ERC-20 wrapped claim tokens
├── libraries/
│   ├── AMMLib.sol                    # Constant-product AMM math
│   ├── FeeLib.sol                    # Standardized fee calculations
│   └── MarketTypes.sol               # Shared enums, errors, constants
├── modules/
│   └── CanonicalPricingModule.sol    # Deviation band logic & swap controls
└── token/
    └── OutcomeToken.sol              # ERC-20 YES/NO tokens (mint/burn by market)
```

### CRE Workflows

```
cre/
├── market-automation-workflow/       # Cron automation workflow
│   ├── main.ts                       # Workflow graph: market lifecycle cron triggers
│   ├── handlers/
│   │   └── cronHandlers/             # resolve, create, topUp, syncPrice, arbitrage, disputes
│   ├── gemini/                       # AI integration: resolveEvent, uniqueEvent, adjudicate
│   ├── firebase/                     # Firestore read/write for state & audit
│   └── payload/                      # ABI encoding for on-chain report payloads
│
├── market-users-workflow/            # User HTTP + deposit-credit workflow
│   ├── main.ts                       # Workflow graph: sponsor, execute, revoke, fiat, log credit
│   ├── handlers/
│   │   ├── httpHandlers/             # sponsor, execute, revokeSession, fiatCredit
│   │   └── eventsHandler/            # ETH deposit log → credit
│   ├── firebase/                     # Firestore auth and approval/session storage
│   └── payload/                      # JSON payloads for CRE simulation
│
└── agents-workflow/                  # Dedicated agent trading workflow
    ├── main.ts                       # HTTP triggers: plan, sponsor, execute, revoke
    └── handlers/httpHandlers/        # Agent-specific request validation & execution
```

### Frontend

```
frontend/minimal-sponsor-ui/
├── src/
│   ├── App.tsx         # User-facing UI: view markets, trade, deposit, redeem
│   ├── AgentApp.tsx    # Agent delegation UI: set permissions, plan/sponsor/execute trades
│   ├── chain.ts        # Multi-chain config, contract ABIs, market snapshot loading
│   ├── api.ts          # CRE HTTP endpoint wrappers (sponsor, execute, fiatCredit)
│   ├── api-agent.ts    # Agent-specific API calls (plan, sponsor, execute, revoke)
│   └── keyVault.ts     # Browser-local session key generation and management
```

---

## Chainlink Integration Summary

| Chainlink Service | How GeoChain Uses It |
|---|---|
| **CRE (Runtime Environment)** | Core automation engine — runs all cron, HTTP, and log-triggered workflows for market lifecycle management, agent execution, and AI resolution |
| **CCIP (Cross-Chain Interoperability)** | Hub-spoke canonical price sync, resolution broadcast, and cross-chain claim bridge messaging |
| **ReceiverTemplateUpgradeable** | On-chain report verification — both `MarketFactory` and `PredictionMarket` implement `_processReport` to consume CRE-delivered reports securely |

---

## Deployed Contracts

### Arbitrum Sepolia

| Contract | Address |
|---|---|
| MarketFactory | `0xA33Ac22e58d34712928d1D1E4CD5201349DCD023` |
| RouterVault | `0xEeD3dc1B401ebd6C22E00641Cc6663FfC20f40b5` |
| Bridge | `0xcb55019591457b2Ea6fbCd779cAF087a6890a06A` |
| Collateral (USDC) | `0xe34742D957708d2c91CA8827F758b3843d681b3e` |

### Base Sepolia

| Contract | Address |
|---|---|
| MarketFactory | `0xf04E1047F34507C7Cf60fDc811116Bc7b0E923f3` |
| RouterVault | `0xef21B5c764186B9D3faD4D610564816fA7e461d4` |
| Bridge | `0x915E3Ee1A09b08038e216B0eCbe736164a246aA3` |
| Collateral (USDC) | `0x57e91c594f77Fca0cb6760267586772E3A3f054F` |

---



## 7) Complete Setup & Run Guide

### Prerequisites

| Tool | Version | Install |
|---|---|---|
| **Foundry** (Forge, Anvil, Cast) | Latest | [getfoundry.sh](https://book.getfoundry.sh/getting-started/installation) |
| **Bun** | ≥ 1.0 | [bun.sh](https://bun.sh) |
| **Node.js** | ≥ 18 | [nodejs.org](https://nodejs.org) |
| **Chainlink CRE CLI** | Latest | [docs.chain.link/cre](https://docs.chain.link/cre) |
| **Git** | Latest | System package manager |

### Environment Variables & Secret Keys

GeoChain requires several secret keys depending on which part of the stack you're running:

#### Smart Contracts (Foundry)

For deploying to live testnets (not needed for local Anvil):

```bash
# Create a .env in the contract/ directory
PRIVATE_KEY=<your-deployer-wallet-private-key>
RPC_URL=<arbitrum-sepolia-or-base-sepolia-rpc-url>
ETHERSCAN_API_KEY=<optional-for-verification>
```

> **Note**: The deployment scripts (`deployMarketFactory.s.sol`, `deployRouterVault.s.sol`) use hardcoded Anvil accounts by default for local testing. For testnet deployment, update the `initialOwner` and `forwarder` addresses in the scripts to your own addresses.

#### CRE Workflows (Chainlink Runtime Environment)

CRE workflows use `runtime.getSecret()` to access secrets configured in the CRE platform. The following secrets must be registered:

| Secret ID | Description | Where to Get It |
|---|---|---|
| `AI_KEY` | Google Gemini API key for AI resolution, market creation, and dispute adjudication | [Google AI Studio](https://aistudio.google.com/apikey) |
| `FIREBASE_API_KEY` | Firebase Web API key for Firestore authentication | Firebase Console → Project Settings → General |
| `FIREBASE_PROJECT_ID` | Firebase project ID for Firestore read/write | Firebase Console → Project Settings → General |

These are registered via the CRE CLI when deploying workflows:
```bash
cre secrets set AI_KEY <your-gemini-api-key>
cre secrets set FIREBASE_API_KEY <your-firebase-api-key>
cre secrets set FIREBASE_PROJECT_ID <your-firebase-project-id>
```

#### CRE Workflow Configuration

Each workflow has a `config.staging.json` that defines:

| Config Key | Purpose |
|---|---|
| `schedule` | Cron schedule for automated handlers (default: `*/30 * * * * *` = every 30 seconds) |
| `httpTriggerAuthorizedKeys` | ECDSA public keys authorized to call sponsor/revoke HTTP endpoints |
| `httpExecutionAuthorizedKeys` | ECDSA public keys authorized to call execute HTTP endpoints |
| `httpFiatCreditAuthorizedKeys` | ECDSA public keys authorized to call fiat credit endpoints |
| `httpAgentAuthorizedKeys` | (agents-workflow only) ECDSA public keys for agent trading endpoints |
| `sponsorPolicy` | Controls allowed actions, max amounts, slippage, session duration for sponsored operations |
| `executePolicy` | Whitelist of allowed action types for on-chain report execution |
| `agentPolicy` | Agent-specific policy: allowed actions, max amount, slippage defaults |
| `ethCreditPolicy` | Controls which chains support ETH deposit → USDC credit conversion |
| `fiatCreditPolicy` | Controls allowed fiat payment providers and supported chains |
| `evms[]` | Per-chain config: `marketFactoryAddress`, `routerReceiverAddress`, `collateralTokenAddress`, `chainName`, `reportGasLimit` |

To customize, edit `cre/market-automation-workflow/config.staging.json`, `cre/market-users-workflow/config.staging.json`, and `cre/agents-workflow/config.staging.json` with your deployed contract addresses and authorized keys.

#### Firebase Setup

1. Create a Firebase project at [console.firebase.google.com](https://console.firebase.google.com)
2. Enable **Firestore Database** (start in test mode for development)
3. Enable **Anonymous Authentication** (used by CRE workflows for Firestore access)
4. Copy your **Web API Key** and **Project ID** from Project Settings

#### Frontend

The frontend uses a `VITE_API_BASE_URL` environment variable (defaults to `http://localhost:5173`):

```bash
# Optional: create frontend/minimal-sponsor-ui/.env
VITE_API_BASE_URL=http://localhost:5173
```

Contract addresses are hardcoded in `frontend/minimal-sponsor-ui/src/chain.ts` — update these if you deploy your own contracts.

---

### Step-by-Step: Build & Run Locally

#### 1. Clone the Repository

```bash
git clone https://github.com/0xHimxa/GeoChain-contrat.git
cd GeoChain-contrat
```

#### 2. Build & Test Smart Contracts

```bash
cd contract

# Install Foundry dependencies (OpenZeppelin, forge-std)
forge install

# Build contracts (uses via_ir + optimizer with 200 runs)
forge build

# Run the full test suite
forge test              # unit + fuzz + invariant tests
forge test -vv          # with verbose console logs
forge test --gas-report # with gas profiling

# Generate coverage report
forge coverage
```

#### 3. Deploy Smart Contracts (Local Anvil)

```bash
# Terminal 1: Start a local Anvil chain
anvil

# Terminal 2: Deploy MarketFactory (creates mock USDC, deploys factory behind UUPS proxy)
forge script script/deployMarketFactory.s.sol --rpc-url http://127.0.0.1:8545 --broadcast

# Deploy RouterVault (update addresses in script to match your deployment)
forge script script/deployRouterVault.s.sol --rpc-url http://127.0.0.1:8545 --broadcast

# Deploy Bridge (update addresses in script to match your deployment)
forge script script/deployBridge.sol --rpc-url http://127.0.0.1:8545 --broadcast
```

> **Important**: The deploy scripts use hardcoded Anvil default accounts:
> - Account #0 (`0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266`) = factory owner
> - Account #1 (`0x70997970C51812dc3A010C7d01b50e0d17dc79C8`) = workflow forwarder placeholder
>
> For testnet deployment, update these addresses and use `--private-key` or `--account` flags.

#### 4. Deploy Smart Contracts (Testnet)

```bash
# Deploy to Arbitrum Sepolia
forge script script/deployMarketFactory.s.sol \
  --rpc-url https://sepolia-rollup.arbitrum.io/rpc \
  --private-key $PRIVATE_KEY \
  --broadcast \
  --verify

# Deploy to Base Sepolia
forge script script/deployMarketFactory.s.sol \
  --rpc-url https://sepolia.base.org \
  --private-key $PRIVATE_KEY \
  --broadcast \
  --verify
```

#### 5. Set Up & Deploy CRE Market Automation Workflow

```bash
cd cre/market-automation-workflow

# Install dependencies (runs cre-setup postinstall hook automatically)
bun install

# Edit config.staging.json with your deployed contract addresses
# Update: marketFactoryAddress, routerReceiverAddress, collateralTokenAddress per chain
# Update: httpTriggerAuthorizedKeys with your ECDSA public key

# Register secrets with CRE
cre secrets set AI_KEY <your-gemini-api-key>
cre secrets set FIREBASE_API_KEY <your-firebase-api-key>
cre secrets set FIREBASE_PROJECT_ID <your-firebase-project-id>

# Simulate workflow locally (test specific trigger by index)
cre workflow simulate ./  --target staging-settings --non-interactive --broadcast

# Simulate sponsor HTTP handler (trigger index 1)
cre workflow simulate ./ \
  --target staging-settings \
  --non-interactive \
  --trigger-index 1 \
  --http-payload "$(cat payload/sponsor.json)" \
  --broadcast

# Simulate execute HTTP handler (trigger index 3)
cre workflow simulate ./ \
  --target staging-settings \
  --non-interactive \
  --trigger-index 3 \
  --http-payload "$(cat payload/execute.json)" \
  --broadcast

# Deploy to CRE staging
cre workflow deploy --target staging-settings
```

#### 6. Set Up & Deploy CRE User Workflow

```bash
cd cre/market-users-workflow

# Install dependencies
bun install

# Edit config.staging.json with your deployed contract addresses
# Update: httpTriggerAuthorizedKeys, httpExecutionAuthorizedKeys, and httpFiatCreditAuthorizedKeys

# Simulate sponsor HTTP handler
cre workflow simulate ./ \
  --target staging-settings \
  --non-interactive \
  --trigger-index 0 \
  --http-payload "$(cat payload/sponser.json)" \
  --broadcast

# Deploy to CRE staging
cre workflow deploy --target staging-settings
```

#### 7. Set Up & Deploy CRE Agents Workflow

```bash
cd cre/agents-workflow

# Install dependencies
bun install

# Edit config.staging.json with your addresses
# Make sure httpAgentAuthorizedKeys is set for agent HTTP endpoints

# Deploy to CRE staging
cre workflow deploy --target staging-settings
```

#### 8. Run the Frontend (User Trading UI)

```bash
cd frontend/minimal-sponsor-ui

# Install dependencies
bun install

# Terminal 1: Start the backend server (mock API on port 5173)
bun run dev

# Terminal 2: Start the Vite frontend dev server (port 5174)
bun run frontend:dev

# Open http://localhost:5174 in your browser
```

#### 9. Run the Frontend (Agent Trading UI)

```bash
cd frontend/minimal-sponsor-ui

# Terminal 1: Start the agent backend server
bun run dev:agent

# Terminal 2: Start the Vite frontend for agent UI
bun run frontend:dev:agent

# Opens http://localhost:5174/agent.html automatically
```

---

### Deployed Contract Addresses

#### Arbitrum Sepolia (Hub)

| Contract | Address |
|---|---|
| MarketFactory | `0xA33Ac22e58d34712928d1D1E4CD5201349DCD023` |
| RouterVault | `0xEeD3dc1B401ebd6C22E00641Cc6663FfC20f40b5` |
| Bridge | `0xcb55019591457b2Ea6fbCd779cAF087a6890a06A` |
| Collateral (USDC) | `0xe34742D957708d2c91CA8827F758b3843d681b3e` |

#### Base Sepolia (Spoke)

| Contract | Address |
|---|---|
| MarketFactory | `0xf04E1047F34507C7Cf60fDc811116Bc7b0E923f3` |
| RouterVault | `0xef21B5c764186B9D3faD4D610564816fA7e461d4` |
| Bridge | `0x915E3Ee1A09b08038e216B0eCbe736164a246aA3` |
| Collateral (USDC) | `0x57e91c594f77Fca0cb6760267586772E3A3f054F` |

---

### Tech Stack Summary

| Layer | Technology |
|---|---|
| Smart Contracts | Solidity 0.8.33, OpenZeppelin (UUPS, ReentrancyGuard, Pausable, ERC-20) |
| Development | Foundry (Forge, Anvil, Cast) |
| Cross-Chain | Chainlink CCIP |
| Automation | Chainlink CRE (Cron, HTTP, Log triggers) |
| AI Resolution | Google Gemini 2.5 Flash with Search Grounding |
| State & Audit | Firebase Firestore |
| Frontend | React + TypeScript + ethers.js + Vite |
| Styling | TailwindCSS 3 |
| Deployment | Arbitrum Sepolia (hub), Base Sepolia (spoke) |
| Runtime | Bun |

---

### Project Structure

```
GeoChain-contrat/
├── contract/                          # Smart contracts (Foundry)
│   ├── src/
│   │   ├── predictionMarket/          # Market modules (Base, Liquidity, Resolution)
│   │   ├── marketFactory/             # Factory modules (Base, CCIP, Operations)
│   │   ├── router/                    # RouterVault (user credits, agent permissions)
│   │   ├── Bridge/                    # CCIP cross-chain claim bridge
│   │   ├── libraries/                 # AMMLib, FeeLib, MarketTypes
│   │   ├── modules/                   # CanonicalPricingModule
│   │   └── token/                     # OutcomeToken (ERC-20 YES/NO)
│   ├── script/                        # Foundry deployment scripts
│   ├── test/                          # unit/, statelessFuzz/, statefullFuzz/
│   └── foundry.toml                   # Foundry config (via_ir, optimizer, remappings)
├── cre/
│   ├── market-automation-workflow/    # Cron automation CRE workflow
│   │   ├── main.ts                    # Workflow graph entry point
│   │   ├── handlers/cronHandlers/     # resolve, create, topUp, sync, arbitrage, disputes
│   │   ├── gemini/                    # AI: resolveEvent, uniqueEvent, adjudicate
│   │   ├── firebase/                  # Firestore: auth, read/write, review sync
│   │   ├── payload/                   # JSON payloads for CRE simulation
│   │   ├── config.staging.json        # Staging config (addresses, policies, keys)
│   │   └── Constant-variable/config.ts # TypeScript config types
│   ├── market-users-workflow/         # User HTTP/log CRE workflow
│   │   ├── main.ts                    # Sponsor, execute, revoke, fiat, ETH-credit graph
│   │   ├── handlers/
│   │   │   ├── httpHandlers/          # sponsor, execute, revoke, fiatCredit
│   │   │   └── eventsHandler/         # ETH deposit log → credit
│   │   ├── firebase/                  # Firestore: auth and approvals/session store
│   │   └── config.staging.json        # User workflow config
│   └── agents-workflow/               # Dedicated agent trading CRE workflow
│       ├── main.ts                    # HTTP triggers: plan, sponsor, execute, revoke
│       ├── handlers/httpHandlers/     # Agent request handlers
│       ├── firebase/                  # Agent session/approval store
│       └── config.staging.json        # Agent workflow config
├── frontend/
│   └── minimal-sponsor-ui/
│       ├── src/
│       │   ├── App.tsx                # User trading UI
│       │   ├── AgentApp.tsx           # Agent delegation UI
│       │   ├── chain.ts              # Multi-chain config, ABIs, market loading
│       │   ├── api.ts                # CRE HTTP endpoint wrappers
│       │   ├── api-agent.ts          # Agent API calls
│       │   └── keyVault.ts           # Browser-local session key management
│       ├── server.ts                  # Backend API server (Bun)
│       ├── server-agent.ts           # Agent backend server (Bun)
│       ├── vite.config.ts            # Vite config (port 5174)
│       └── vite.agent.config.ts      # Vite config for agent UI
├── demo-site/                         # Static demo landing page
├── README.md                          # Full technical README
└── HACKATHON_SUBMISSION_README.md     # This file
```


---

## Team

Built for **Convergence: A Chainlink Hackathon** (2026)

---

<p align="center">
  <sub>GeoChain — Making prediction markets autonomous, cross-chain, and agent-native.</sub>
</p>
