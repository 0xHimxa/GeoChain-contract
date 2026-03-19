# GeoChain — Autonomous Cross-Chain Prediction Markets

GeoChain is a prediction market protocol that replaces manual market operations with autonomous on-chain workflows powered by Chainlink CRE, synchronizes market state across chains via dual-path price propagation (CCIP and CRE direct writes), and introduces a bounded agent delegation model that lets AI agents trade on behalf of users without custodial risk. The protocol uses LMSR (Logarithmic Market Scoring Rule) as its pricing engine — with heavy fixed-point arithmetic computed off-chain in CRE and validated on-chain — enabling theoretically sound pricing for prediction markets that constant-product AMMs cannot provide.

---

## Technical Highlights

- **On-chain LMSR pricing engine with off-chain fixed-point arithmetic** — `exp()` and `ln()` have no native EVM opcodes; the CRE handler implements WAD-scaled (1e18) Taylor series expansion with range reduction for `exp()` and Halley's method (cubic-order iteration) for `ln()`, then the contract validates CRE-reported prices sum to 1.0 within tolerance before executing
- **Dual-path cross-chain price synchronization** — canonical prices propagate from hub to spokes via both Chainlink CCIP messages and CRE direct `writeReport` calls, providing redundancy and lower latency for spoke markets
- **4-band canonical deviation policy engine** — `CanonicalPricingModule` classifies hub/spoke price divergence into Normal → Stress → Unsafe → CircuitBreaker bands, progressively applying fee surcharges, output caps, direction restrictions, and full trading halts
- **6-layer agent delegation security model** — defense-in-depth from HTTP key gates through EIP-712 session signatures, one-time Firestore approvals with nonce replay protection, execute policy allowlists, on-chain `_authorizeAgent()` permission/expiry/action-mask/amount-cap checks, and router balance guards
- **Three independently deployed CRE workflows** — operational automation, user operations, and agent trading are isolated by trigger type, authorized key set, and policy scope with independent failure domains
- **AI-powered resolution via Gemini with adversarial resistance** — CRE cron workflows call Google Gemini with search grounding for market resolution, engineered to handle edge cases (cancellation, postponement, contradictory sources) and fall back to manual review rather than force binary outcomes
- **UUPS-upgradeable modular contract architecture** — PredictionMarket, MarketFactory, and RouterVault each use diamond-style module inheritance behind UUPS proxies with OpenZeppelin's ReentrancyGuard and Pausable
- **Cross-chain position bridge** — `PredictionMarketBridge` enables lock/mint/burn/unlock of outcome token claims across chains via CCIP with replay protection and trusted-remote validation

---

## LMSR Migration: From CPMM to Logarithmic Market Scoring Rule

GeoChain migrated from a Constant Product Market Maker (CPMM) to the Logarithmic Market Scoring Rule (LMSR). The CPMM branch is preserved in the repository history. This section explains why LMSR is the correct mechanism for prediction markets and the engineering challenges of implementing it on the EVM.

### Why LMSR Over CPMM

| Dimension | CPMM (x · y = k) | LMSR (C = b · ln(Σ exp(qᵢ/b))) |
|---|---|---|
| **Pricing model** | Price derived from reserve ratio; no concept of probabilities | Price directly represents calibrated probability via softmax |
| **Slippage behavior** | Slippage grows superlinearly with trade size relative to reserves | Slippage controlled by liquidity parameter `b`; predictable for any trade size |
| **Multi-outcome support** | Limited to 2-outcome (YES/NO) pairs per pool | Naturally extends to N outcomes in a single cost function |
| **LP risk** | LPs face impermanent loss; must actively manage positions | Market maker subsidy is bounded: max loss = `b × ln(N)`, known at creation |
| **Suitability for prediction markets** | Prices don't directly map to probabilities; requires external interpretation | Prices are probabilities by construction; theoretically grounded in proper scoring rules |
| **Liquidity bootstrapping** | Requires initial reserve deposits in both tokens | Single collateral deposit funds the market maker; subsidy computed deterministically |

### The LMSR Cost Function

The core LMSR cost function for a market with outcome share vectors **q** and liquidity parameter **b**:

```
C(q) = b × ln( Σᵢ exp(qᵢ / b) )
```

The price (probability) of outcome *i* is the partial derivative:

```
pᵢ = ∂C/∂qᵢ = exp(qᵢ / b) / Σⱼ exp(qⱼ / b)
```

This is identical to the softmax function — prices are always positive and always sum to 1.0.

The cost of buying `Δ` shares of outcome *i* is:

```
cost = C(q + Δeᵢ) − C(q)
```

The maximum subsidy loss (market maker's worst case) for a binary market:

```
maxLoss = b × ln(2)
```

This is computed on-chain via `LMSRLib.maxSubsidyLoss()` and locked as collateral at market creation.

### EVM Implementation Challenge

The LMSR cost function requires `exp()` and `ln()` — transcendental functions that have **no native EVM opcodes**. Computing them on-chain with Solidity's integer arithmetic would be gas-prohibitive and precision-dangerous (overflow risk with large share quantities in uint256).

GeoChain solves this with a **hybrid architecture**:

- **Off-chain (CRE handler — `httpLmsrTrade.ts`)**: Implements `exp()` via a 20-term Taylor series with range reduction (`exp(x) = 2^k × exp(r)` where `r ∈ [0, ln2)`) and `ln()` via Halley's method (third-order iteration, ≤8 steps). All arithmetic uses BigInt at WAD scale (1e18) — no floating-point anywhere in the math path. The log-sum-exp trick prevents overflow by shifting exponents before summing.
- **On-chain (Solidity — `LMSRLib.sol`)**: Validates that CRE-reported prices sum to `1e6 ± 0.1%` tolerance, enforces monotonic trade nonces to prevent replay, and executes token transfers. The contract never computes `exp()` or `ln()` itself.

This gives mathematically correct LMSR pricing with EVM-safe execution — the hard math runs in CRE's runtime where BigInt is native, while the contract enforces invariants that make the system trustworthy.

---

## Protocol Architecture

### Smart Contracts

```
contract/src/
├── predictionMarket/
│   ├── PredictionMarket.sol              # Main entry — inherits all modules
│   ├── PredictionMarketBase.sol          # State, modifiers, LMSR initialization, canonical pricing controls
│   ├── PredictionMarketLiquidity.sol     # LMSR buy/sell execution, complete-set mint/redeem, risk exposure caps
│   └── PredictionMarketResolution.sol    # Resolution, disputes, CRE report processing, cross-chain resolution sync
├── marketFactory/
│   ├── MarketFactory.sol                 # UUPS proxy entry point
│   ├── MarketFactoryBase.sol             # Market registry, collateral management, queued withdrawals
│   ├── MarketFactoryCcip.sol             # CCIP send/receive for hub-spoke price and resolution sync
│   └── MarketFactoryOperations.sol       # CRE _processReport dispatcher — routes 10+ action types
├── router/
│   ├── PredictionMarketRouterVault.sol   # Proxy entry
│   ├── PredictionMarketRouterVaultBase.sol  # User collateral credits, agent permissions, session management
│   └── PredictionMarketRouterVaultOperations.sol  # All user & agent-delegated actions (mint, redeem, swap, dispute)
├── Bridge/
│   ├── PredictionMarketBridge.sol        # Cross-chain claim lock/mint/burn/unlock via CCIP
│   └── BridgeWrappedClaimToken.sol       # ERC-20 wrapped claim tokens for bridged positions
├── libraries/
│   ├── LMSRLib.sol                       # LMSR validation: price sum check, nonce ordering, max subsidy computation
│   ├── AMMLib.sol                        # Legacy CPMM math (retained on CPMM branch)
│   ├── ActionType.sol                    # Precomputed keccak256 hashes for all CRE report action types
│   ├── FeeLib.sol                        # Standardized fee deduction (buy/sell/mint/redeem)
│   └── MarketTypes.sol                   # Shared enums (State, Resolution), constants, events, errors
├── modules/
│   └── CanonicalPricingModule.sol        # 4-band deviation policy engine for cross-chain price consistency
└── token/
    └── OutcomeToken.sol                  # ERC-20 YES/NO tokens (mint/burn controlled by market contract)
```

### CRE Workflows

```
cre/
├── market-automation-workflow/           # Cron-triggered operational automation
│   ├── main.ts                           # 9 cron handlers: resolve, create, topUp, syncPrice, 
│   │                                     #   arbitrage, disputes, withdrawals, manualReviewSync, preCloseLmsrSell
│   ├── handlers/cronHandlers/
│   │   ├── resolve.ts                    # AI resolution via Gemini with search grounding
│   │   ├── syncPrice.ts                  # Hub→spoke canonical price sync via CRE direct writeReport
│   │   ├── arbitrage.ts                  # Automated unsafe-band price correction trades
│   │   ├── preCloseLmsrSell.ts           # Pre-close factory share unwinding via LMSR sell
│   │   └── ...                           # marketCreation, topUp, disputeResolution, withdrawals
│   ├── gemini/                           # Gemini AI integration: resolve, uniqueEvent, adjudicate
│   └── firebase/                         # Firestore read/write for state & audit trail
│
├── market-users-workflow/                # HTTP + EVM-log triggered user operations
│   ├── main.ts                           # Handlers: sponsor, execute, revoke, fiatCredit, lmsrTrade, ethCredit
│   ├── handlers/
│   │   ├── httpHandlers/
│   │   │   ├── httpSponsorPolicy.ts      # EIP-712 session signature validation, approval creation
│   │   │   ├── httpExecuteReport.ts      # Approval consumption, ABI encoding, on-chain report delivery
│   │   │   ├── httpLmsrTrade.ts          # Full LMSR math engine: BigInt exp/ln, cost/price computation
│   │   │   └── ...                       # revokeSession, fiatCredit
│   │   └── eventsHandler/
│   │       └── ethCreditFromLogs.ts      # EVM log → router balance credit for ETH deposits
│   └── firebase/                         # Session/approval storage with replay protection
│
└── agents-workflow/                      # Dedicated agent trading engine
    ├── main.ts                           # HTTP triggers: plan, sponsor, execute, revoke
    └── handlers/httpHandlers/            # Agent-specific validation, policy enforcement, execution
```

---

## Chainlink Integration

### CRE (Compute Runtime Environment)

CRE is the core automation engine. All market lifecycle operations — from creation through resolution — run as autonomous CRE workflows.

| Trigger Type | Handler | What It Does |
|---|---|---|
| **Cron** | `resolveEvent` | Detects markets past resolution time → calls Gemini AI with search grounding → delivers resolution report on-chain |
| **Cron** | `createPredictionMarketEvent` | Gemini generates unique event ideas → deploys new markets on-chain with LMSR initialization |
| **Cron** | `syncCanonicalPrice` | Reads hub market prices → writes `syncSpokeCanonicalPrice` reports directly to each spoke factory |
| **Cron** | `arbitrateUnsafeMarketHandler` | Detects spoke markets in Unsafe/CircuitBreaker bands → executes corrective LMSR trades |
| **Cron** | `preCloseLmsrSellHandler` | Unwinds factory-held outcome shares before market close via LMSR sell reports |
| **Cron** | `adjudicateExpiredDisputeWindows` | Auto-finalizes undisputed resolutions after dispute window expiry |
| **Cron** | `processPendingWithdrawalsHandler` | Batch-processes queued LP withdrawal requests |
| **Cron** | `marketFactoryBalanceTopUp` | Monitors factory collateral balance → auto-replenishes when low |
| **HTTP** | `sponsorUserOpPolicyHandler` | Validates EIP-712 signatures → creates one-time Firestore approvals for gasless user actions |
| **HTTP** | `executeReportHttpHandler` | Consumes approvals → ABI-encodes payload → submits on-chain report |
| **HTTP** | `lmsrTradeHttpHandler` | Full LMSR trade pipeline: read on-chain state → compute cost/prices off-chain → submit trade report |
| **HTTP** | `agentPlanTrade` / `agentExecuteTrade` | Agent-specific trade validation and execution through dedicated policy |
| **EVM Log** | `ethCreditFromLogsHandler` | Detects ETH deposit events → credits user's router balance in collateral equivalent |

### CCIP (Cross-Chain Interoperability Protocol)

Hub-spoke canonical price sync, resolution broadcast, and cross-chain claim bridge messaging.

**Dual-path price propagation**: Prices reach spoke factories through two independent paths:
1. **CCIP messages** — `MarketFactoryCcip.sol` sends/receives structured CCIP messages between hub and spoke factories
2. **CRE direct reports** — `syncPrice.ts` reads hub state and writes `syncSpokeCanonicalPrice` reports directly to spoke factories via `writeReport`

This redundancy ensures spoke markets stay synchronized even if one path experiences latency.

### ReceiverTemplateUpgradeable

All three core contracts (`MarketFactory`, `PredictionMarket`, `RouterVault`) inherit `ReceiverTemplateUpgradeable` to securely receive and verify CRE-delivered reports via `_processReport()`.

---

## Hub-Spoke Cross-Chain Architecture

```
                    ┌──────────────────┐
                    │   Hub Factory    │
                    │ (Arbitrum Sepolia)│
                    └────────┬─────────┘
             CCIP CanonicalPriceSync
             CRE  syncSpokeCanonicalPrice
             CCIP ResolutionBroadcast
          ┌──────────┴──────────┐
┌─────────┴─────────┐ ┌────────┴──────────┐
│  Spoke Factory    │ │  Spoke Factory     │
│  (Base Sepolia)   │ │  (Future Chains)   │
└───────────────────┘ └────────────────────┘
```

**Deviation bands** protect spoke markets from trading at stale prices. When the local LMSR YES price diverges from the hub canonical YES price:

| Band | Deviation | Effect |
|---|---|---|
| **Normal** | ≤ `softDeviationBps` | Base fee, unlimited output, both directions |
| **Stress** | ≤ `stressDeviationBps` | Extra fee + capped output |
| **Unsafe** | ≤ `hardDeviationBps` | 2× extra fee + tighter cap + only price-corrective direction allowed |
| **CircuitBreaker** | > `hardDeviationBps` | 5× extra fee + minimal cap + **all trading halted** |

The `arbitrateUnsafeMarketHandler` CRE cron automatically executes corrective trades to bring spoke prices back into the Normal band.

---

## Agent Delegation Security Model

GeoChain implements native on-chain agent delegation with 6 independent security layers. Users authorize AI agents to trade on their behalf without surrendering custody — funds remain in the RouterVault at all times.

```
User ──setAgentPermission()──► Router ──_authorizeAgent()──► Execute
        (actionMask,                    (enabled? expired?
         maxAmountPerAction,             action allowed?
         expiresAt)                      amount within cap?)
```

### Defense-in-Depth Layers

| Layer | Protection | Enforcement Point |
|---|---|---|
| 1 | HTTP authorized key gate | CRE trigger configuration |
| 2 | EIP-712 session signature + sponsor policy validation | CRE HTTP handler |
| 3 | One-time Firestore approval with nonce replay protection | CRE state layer |
| 4 | Execute policy action allowlist | CRE execution handler |
| 5 | On-chain `_authorizeAgent()` — permission bitmap, expiry, action mask, per-action amount cap | Smart contract |
| 6 | Router collateral/token credit balance checks | Smart contract |

**Key design principle**: Funds never leave the RouterVault. The agent is a scoped executor, not a custodian. Even if all off-chain layers are compromised, on-chain `_authorizeAgent()` blocks unauthorized actions.

### Agent API Flow

```
POST /agent/plan     →  Validate intent against agentPolicy (allowed actions, max amount, supported chains)
POST /agent/sponsor  →  Session signature verification + one-time approval creation
POST /agent/execute  →  Consume approval → encode routerAgent payload → submit on-chain report
POST /agent/revoke   →  Terminate agent session (single revocation path for both agent and non-agent)
```

---

## Three Isolated CRE Workflow Deployments

```
┌────────────────────────────┬────────────────────────────┬────────────────────────────────┐
│ market-automation-workflow │   market-users-workflow    │        agents-workflow         │
│  (Operational Automation)  │   (User Ops + Credits)     │     (Agent Trading Engine)     │
├────────────────────────────┼────────────────────────────┼────────────────────────────────┤
│ • Cron: market creation    │ • HTTP: sponsorUserOpPolicy│ • HTTP: agentPlanTrade         │
│ • Cron: resolution via AI  │ • HTTP: executeReport      │ • HTTP: agentSponsorTrade      │
│ • Cron: liquidity top-up   │ • HTTP: revokeSession      │ • HTTP: agentExecuteTrade      │
│ • Cron: price sync         │ • HTTP: fiatCredit         │ • HTTP: agentRevoke            │
│ • Cron: arbitrage          │ • HTTP: lmsrTrade          │                                │
│ • Cron: dispute adjudicate │ • Log: ethCreditFromLogs   │                                │
│ • Cron: withdrawal process │                            │                                │
│ • Cron: pre-close LMSR sell│                            │                                │
│ • Cron: manual review sync │                            │                                │
└────────────────────────────┴────────────────────────────┴────────────────────────────────┘
```

**Why three workflows?**
- Independent deployment and upgrade cycles
- Different authorized key sets — automation keys, user-op keys, and agent keys are scoped separately
- Isolated failure domains — an HTTP/signature issue cannot break cron-based market automation
- Clear policy separation (`sponsorPolicy`, `executePolicy`, `lmsrTradePolicy`, `agentPolicy`, `ethCreditPolicy`, `fiatCreditPolicy`)

---

## Live Deployments

### Arbitrum Sepolia (Hub)

| Contract | Address |
|---|---|
| MarketFactory | `0xA33Ac22e58d34712928d1D1E4CD5201349DCD023` |
| RouterVault | `0xEeD3dc1B401ebd6C22E00641Cc6663FfC20f40b5` |
| Bridge | `0xcb55019591457b2Ea6fbCd779cAF087a6890a06A` |
| Collateral (USDC) | `0xe34742D957708d2c91CA8827F758b3843d681b3e` |

### Base Sepolia (Spoke)

| Contract | Address |
|---|---|
| MarketFactory | `0xf04E1047F34507C7Cf60fDc811116Bc7b0E923f3` |
| RouterVault | `0xef21B5c764186B9D3faD4D610564816fA7e461d4` |
| Bridge | `0x915E3Ee1A09b08038e216B0eCbe736164a246aA3` |
| Collateral (USDC) | `0x57e91c594f77Fca0cb6760267586772E3A3f054F` |

---

## Getting Started

### Prerequisites

| Tool | Version | Install |
|---|---|---|
| **Foundry** (Forge, Anvil, Cast) | Latest | [getfoundry.sh](https://book.getfoundry.sh/getting-started/installation) |
| **Bun** | ≥ 1.0 | [bun.sh](https://bun.sh) |
| **Node.js** | ≥ 18 | [nodejs.org](https://nodejs.org) |
| **Chainlink CRE CLI** | Latest | [docs.chain.link/cre](https://docs.chain.link/cre) |

### Build & Test Smart Contracts

```bash
cd contract

# Install Foundry dependencies (OpenZeppelin, forge-std)
forge install

# Build contracts (via_ir + optimizer with 200 runs)
forge build

# Run the full test suite
forge test              # unit + fuzz + invariant tests
forge test -vv          # with verbose console logs
forge test --gas-report # with gas profiling

# Generate coverage report
forge coverage
```

### Deploy Contracts (Local Anvil)

```bash
# Terminal 1: Start local chain
anvil

# Terminal 2: Deploy MarketFactory (creates mock USDC, deploys behind UUPS proxy)
forge script script/deployMarketFactory.s.sol --rpc-url http://127.0.0.1:8545 --broadcast

# Deploy RouterVault
forge script script/deployRouterVault.s.sol --rpc-url http://127.0.0.1:8545 --broadcast

# Deploy Bridge
forge script script/deployBridge.sol --rpc-url http://127.0.0.1:8545 --broadcast
```

### Deploy Contracts (Testnet)

```bash
# Arbitrum Sepolia
forge script script/deployMarketFactory.s.sol \
  --rpc-url https://sepolia-rollup.arbitrum.io/rpc \
  --private-key $PRIVATE_KEY \
  --broadcast --verify

# Base Sepolia
forge script script/deployMarketFactory.s.sol \
  --rpc-url https://sepolia.base.org \
  --private-key $PRIVATE_KEY \
  --broadcast --verify
```

### Environment Variables

#### Smart Contracts (Foundry)

```bash
# contract/.env (for testnet deploys only)
PRIVATE_KEY=<your-deployer-wallet-private-key>
RPC_URL=<arbitrum-sepolia-or-base-sepolia-rpc-url>
ETHERSCAN_API_KEY=<optional-for-verification>
```

#### CRE Workflow Secrets

| Secret ID | Description | Source |
|---|---|---|
| `AI_KEY` | Google Gemini API key | [Google AI Studio](https://aistudio.google.com/apikey) |
| `FIREBASE_API_KEY` | Firebase Web API key | Firebase Console → Project Settings |
| `FIREBASE_PROJECT_ID` | Firebase project ID | Firebase Console → Project Settings |

```bash
cre secrets set AI_KEY <your-gemini-api-key>
cre secrets set FIREBASE_API_KEY <your-firebase-api-key>
cre secrets set FIREBASE_PROJECT_ID <your-firebase-project-id>
```

### Deploy CRE Workflows

```bash
# Market automation workflow
cd cre/market-automation-workflow
bun install
# Edit config.staging.json with your deployed contract addresses
cre workflow deploy --target staging-settings

# User operations workflow
cd cre/market-users-workflow
bun install
cre workflow deploy --target staging-settings

# Agent trading workflow
cd cre/agents-workflow
bun install
cre workflow deploy --target staging-settings
```

---

## Tech Stack

| Layer | Technology |
|---|---|
| Smart Contracts | Solidity 0.8.33, OpenZeppelin (UUPS, ReentrancyGuard, Pausable, ERC-20) |
| Development | Foundry (Forge, Anvil, Cast) |
| Cross-Chain | Chainlink CCIP |
| Automation | Chainlink CRE (Cron, HTTP, EVM Log triggers) |
| AI Resolution | Google Gemini 2.5 Flash with Search Grounding |
| State & Audit | Firebase Firestore |
| Off-chain Math | TypeScript BigInt (WAD = 1e18 fixed-point) |
| Runtime | Bun |
| Deployment | Arbitrum Sepolia (hub), Base Sepolia (spoke) |

---

## Test Suite

```
contract/test/
├── unit/
│   ├── PredictionMarket.t.sol              # Market lifecycle, LMSR execution, resolution
│   ├── MarketFactory.t.sol                 # Factory operations, market registry, CRE report dispatch
│   ├── PredictionMarketRouterVault.t.sol   # Router vault, agent delegation, credit accounting
│   └── PredictionMarketBridge.t.sol        # Cross-chain bridge lock/mint/burn/unlock
├── statelessFuzz/                          # Property-based fuzz testing
├── statefullFuzz/                          # Invariant/stateful fuzz testing
└── utils/                                  # Shared test utilities
```

---

## Skills Demonstrated

| Domain | Implementation in This Codebase |
|---|---|
| **Smart Contract Engineering** | UUPS-upgradeable modular architecture across 3 proxy contracts; `_processReport` dispatcher routing 10+ action types via precomputed `keccak256` hashes; storage-layout-safe migration from CPMM to LMSR with deprecated slot preservation |
| **DeFi Protocol Design** | LMSR pricing engine with bounded market-maker subsidy (`b × ln(N)`); complete-set mint/redeem with fee accounting; queued withdrawal system for LP exits |
| **Cross-Chain Architecture** | Hub-spoke topology with dual-path price sync (CCIP + CRE direct); 4-band deviation policy engine with progressive circuit breakers; cross-chain claim bridge with replay protection |
| **Automated Systems** | 3 independently deployed CRE workflows with 15+ handlers across cron, HTTP, and EVM-log triggers; fully autonomous market lifecycle from creation through resolution |
| **Mathematical Finance** | Off-chain LMSR cost function via log-sum-exp trick in BigInt; `exp()` via 20-term Taylor series with range reduction; `ln()` via Halley's method; WAD-scaled (1e18) fixed-point arithmetic with no floating-point contamination |
| **Security Design** | 6-layer agent delegation model; EIP-712 typed-data session signatures; one-time approval consumption with nonce replay protection; per-user risk exposure caps (5% of total liquidity); on-chain action-mask bitfield authorization |
| **Testing** | Unit tests for all core contracts; stateless fuzz testing with randomized inputs; stateful invariant testing; Foundry gas profiling and coverage reporting |

---

## Contact

Built by **[Your Name]** — open to smart contract and protocol engineering roles. Reach out via **[your preferred contact]**.
