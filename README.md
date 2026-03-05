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

| Automated Action | Handler | Trigger |
|---|---|---|
| **Market Creation** | `createEventHelper` | Cron — Gemini generates unique event ideas, deploys on-chain |
| **Market Resolution** | `resolveEvent` | Cron — detects markets past resolution time, calls Gemini |
| **Liquidity Top-Up** | `marketFactoryBalanceTopUp` | Cron — monitors factory balance, auto-replenishes |
| **Price Sync** | `syncCanonicalPrice` | Cron — CRE reads hub prices and writes canonical sync reports directly to spoke factories |
| **Unsafe Market Arbitrage** | `arbitrateUnsafeMarketHandler` | Cron — corrects price deviations across chains |
| **Dispute Adjudication** | `adjudicateExpiredDisputeWindows` | Cron — auto-finalizes undisputed resolutions |
| **Withdrawal Processing** | `processPendingWithdrawalsHandler` | Cron — batch-processes queued LP withdrawals |
| **Fiat Credit Onboarding** | `fiatCreditHttpHandler` | HTTP — credits user balances from off-chain payments |
| **ETH Deposit Credit** | `ethCreditFromLogsHandler` | EVM Log — detects ETH deposits, credits router balances |

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

### ✦ The Agents Workflow — A Dedicated CRE Deployment for AI Trading

GeoChain doesn't bolt agent support onto the market automation workflow — it runs a **dedicated, independently deployed CRE workflow** (`agents-workflow`) purpose-built for agent trading. This is a first-class architectural separation:

```
┌─────────────────────────────────────────────────────────────────┐
│                     CRE WORKFLOW DEPLOYMENTS                    │
├─────────────────────────────┬───────────────────────────────────┤
│      market-workflow        │        agents-workflow            │
│  (Operational Automation)   │     (Agent Trading Engine)        │
├─────────────────────────────┼───────────────────────────────────┤
│ • Cron: market creation     │ • HTTP: agentPlanTrade            │
│ • Cron: resolution via AI   │ • HTTP: agentSponsorTrade         │
│ • Cron: liquidity top-up    │ • HTTP: agentExecuteTrade         │
│ • Cron: price sync (CRE direct) │ • HTTP: agentRevoke               │
│ • Cron: dispute adjudication│                                   │
│ • HTTP: sponsor/execute     │                                   │
│ • HTTP: fiat credit         │                                   │
│ • Log: ETH deposit credit   │                                   │
└─────────────────────────────┴───────────────────────────────────┘
```

**Why two workflows?** Operational automation (creating markets, resolving them, syncing prices) has different risk profiles, schedules, and authorized keys than agent-initiated trading. Separating them means:
- Independent deployment and upgrade cycles
- Different authorized key sets — market ops keys can't trigger agent trades and vice versa
- Isolated failure domains — an agent workflow misconfiguration can't break market resolution
- Separate config policies (`agentPolicy` vs `sponsorPolicy` vs `executePolicy`)

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
├── market-workflow/                  # Core automation workflow
│   ├── main.ts                       # Workflow graph: cron + HTTP + log triggers
│   ├── handlers/
│   │   ├── cronHandlers/             # resolve, create, topUp, syncPrice, arbitrage, disputes
│   │   ├── httpHandlers/             # sponsor, execute, fiatCredit, revokeSession
│   │   └── eventsHandler/            # ETH deposit log → credit
│   ├── gemini/                       # AI integration: resolveEvent, uniqueEvent, adjudicate
│   ├── firebase/                     # Firestore read/write for state & audit
│   └── payload/                      # ABI encoding for on-chain report payloads
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
| MarketFactory | `0x1dAf6Ecab082971aCF99E50B517cf297B51B6e5C` |
| RouterVault | `0x0d9498795752AeDF56FF3C2579Dd0E91994CadCe` |
| Bridge | `0xcb55019591457b2Ea6fbCd779cAF087a6890a06A` |
| Collateral (USDC) | `0x52539038C1d1C88AA12438e3c13ADC6778B966Fc` |

### Base Sepolia

| Contract | Address |
|---|---|
| MarketFactory | `0x73f6A1a5B211E39AcE6F6AF108d7c6e0F77e3B92` |
| RouterVault | `0x2bE604A2052a6C5e246094151d8962B2E98D8f7c` |
| Bridge | `0x915E3Ee1A09b08038e216B0eCbe736164a246aA3` |
| Collateral (USDC) | `0xB17Ede44C636887ce980D9359A176a088DC46c2f` |

---

## Getting Started

### Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation) (Forge, Anvil)
- Solidity ^0.8.33
- Node.js ≥ 18 / Bun
- [Chainlink CRE CLI](https://docs.chain.link/cre)

### Build & Test

```bash
# Clone
git clone https://github.com/0xHimxa/GeoChain-contrat.git
cd contract

# Install dependencies
forge install

# Build
forge build

# Run tests
forge test              # unit + fuzz
forge test -vv          # with console logs
forge test --gas-report # gas profiling
forge coverage          # coverage report
```

### Deploy

```bash
# Copy environment template
cp .env.example .env
# Fill in PRIVATE_KEY, RPC_URL, COLLATERAL_TOKEN_ADDRESS, etc.

# Deploy MarketFactory (UUPS proxy)
forge script script/deployMarketFactory.s.sol --rpc-url $RPC_URL --broadcast

# Deploy RouterVault
forge script script/deployRouterVault.s.sol --rpc-url $RPC_URL --broadcast

# Deploy Bridge
forge script script/deployBridge.sol --rpc-url $RPC_URL --broadcast
```

### Run CRE Workflows

```bash
cd cre/market-workflow

# Install workflow dependencies
bun install

# Deploy to staging
cre workflow deploy --target staging-settings

# Deploy agents workflow
cd ../agents-workflow
bun install
cre workflow deploy --target staging-settings
```

### Run Frontend

```bash
cd frontend/minimal-sponsor-ui
bun install
bun run dev
```

---

## On-Chain Flow

```
1. MarketFactory.createMarket(question, closeTime, resolutionTime)
   └── MarketDeployer clones PredictionMarket
   └── Factory transfers collateral → market seeds AMM with YES/NO tokens

2. Users interact via RouterVault (gasless) or directly:
   ├── mintCompleteSets() → deposit USDC, receive YES + NO tokens
   ├── swapYesForNo() / swapNoForYes() → AMM trades with CPMM pricing
   ├── addLiquidity() / removeLiquidity() → LP operations
   └── redeem() → burn winning tokens for USDC after resolution

3. Resolution paths:
   ├── CRE Automation → Gemini AI evaluation → signed report → dispute window → finalize
   ├── Owner direct → resolve() with proof URL → dispute window → finalize
   └── Cross-chain → Hub broadcasts via CCIP → spoke accepts canonical resolution

4. Dispute mechanism:
   ├── Any user can dispute during window → propose alternative outcome
   ├── If disputed → owner/CRE adjudicates with evidence
   └── If inconclusive → enters manual Review state

5. Cross-chain pricing:
   ├── Hub computes canonical YES/NO prices from AMM reserves
   ├── Broadcasts via CCIP to all spoke factories
   └── Spokes enforce deviation bands → progressive restrictions → circuit breaker
```

---

## Security Model

| Control | Implementation |
|---|---|
| **Reentrancy** | OpenZeppelin `ReentrancyGuard` on all state-changing functions |
| **Access Control** | `onlyOwner`, `onlyCrossChainController`, `paused` modifiers |
| **Risk Exposure Caps** | Per-address `userRiskExposure` capped at `MAX_RISK_EXPOSURE` (10k USDC) |
| **Deviation Protection** | Multi-band system with direction restrictions, fee surcharges, output caps, and circuit breaker |
| **Agent Delegation** | On-chain permission struct with `actionMask`, `maxAmountPerAction`, `expiresAt` |
| **Session Authorization** | EIP-712 typed data signatures with nonce replay protection |
| **CCIP Security** | `trustedRemoteBySelector`, `processedCcipMessages`, and monotonic nonces |
| **AI Resolution Safety** | Adversarial-resistant prompting, source URL requirement, `INCONCLUSIVE` fallback |
| **Upgradability** | UUPS proxy pattern — factory and router are upgradeable |

---

## Testing

The test suite covers three tiers:

```
test/
├── unit/             # Core function behavior, edge cases, access control
├── statelessFuzz/    # Property-based fuzzing with random inputs
└── statefullFuzz/    # Invariant testing across multi-step sequences
```

```bash
forge test                    # Run all
forge test --match-path test/unit/*       # Unit only
forge test --match-path test/statelessFuzz/*  # Fuzz only
```

---

## Tech Stack

| Layer | Technology |
|---|---|
| Smart Contracts | Solidity 0.8.33, OpenZeppelin (UUPS, ReentrancyGuard, Pausable, ERC-20) |
| Development | Foundry (Forge, Anvil, Cast) |
| Cross-Chain | Chainlink CCIP |
| Automation | Chainlink CRE (Cron, HTTP, Log triggers) |
| AI Resolution | Google Gemini 2.5 Flash with Search Grounding |
| State & Audit | Firebase Firestore |
| Frontend | React + TypeScript + ethers.js |
| Deployment | Arbitrum Sepolia, Base Sepolia |

---

## Further Reading

| Document | Description |
|---|---|
| [SECURITY.md](contract/SECURITY.md) | Threat model, attack vectors, and responsible disclosure |
| [Test README](contract/test/README.md) | Testing patterns, naming conventions, CI notes |
| [Agentic Mode](cre/market-workflow/README-agentic-mode.md) | Full agent delegation architecture walkthrough |
| [Agentic Setup](cre/market-workflow/README-agentic-setup.md) | Step-by-step agent setup guide with code examples |

---

## Team

Built for **Convergence: A Chainlink Hackathon** (2026)

---

<p align="center">
  <sub>GeoChain — Making prediction markets autonomous, cross-chain, and agent-native.</sub>
</p>
