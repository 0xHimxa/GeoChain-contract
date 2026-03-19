# GeoChain — Autonomous Cross-Chain Prediction Markets
 
> **Built by [Himxa](mailto:himxa0x@gmail.com)** — open to smart contract and protocol engineering roles.
 
GeoChain is a prediction market protocol where **no human operator is needed** to run it. Markets are created by AI, priced by LMSR, resolved autonomously, and kept in sync across chains — all on-chain, all the time.
 
Under the hood: Chainlink CRE drives the full market lifecycle, CCIP handles cross-chain state, and a 6-layer agent delegation model lets AI agents trade on users' behalf without ever touching their funds.
 
**[Live on Arbitrum Sepolia + Base Sepolia](#live-deployments)** · Solidity 0.8.33 · Foundry · Chainlink CRE + CCIP · Gemini AI
 
---
 
## Why This Project Is Hard to Build
 
Most prediction market protocols stop at the AMM. GeoChain solves three genuinely difficult problems on top of that:
 
**1. LMSR on the EVM is mathematically hostile.**
The LMSR cost function requires `exp()` and `ln()` — transcendental functions with no native EVM opcodes. Computing them on-chain in Solidity would be gas-prohibitive and precision-dangerous. GeoChain solves this with a hybrid: all fixed-point math runs off-chain in CRE's TypeScript runtime (BigInt at WAD scale, no floating point), while the contract validates that reported prices sum to `1.0 ± 0.1%` before executing any trade. Hard math where it's safe, trust enforcement where it matters.
 
**2. Cross-chain price consistency without a central oracle.**
When the same market exists on multiple chains, prices diverge. GeoChain's `CanonicalPricingModule` classifies hub/spoke divergence into four bands (Normal → Stress → Unsafe → CircuitBreaker) and responds with escalating fee surcharges, output caps, directional restrictions, and full trading halts. A CRE cron automatically executes corrective trades to pull spoke markets back into range — no manual intervention.
 
**3. Agent delegation without custodial risk.**
Letting an AI agent trade on your behalf is useful. Letting it touch your funds is not. GeoChain's RouterVault keeps user collateral locked at all times. Agents are scoped executors with an on-chain permission bitmap, per-action amount caps, expiry timestamps, and action-type allowlists. Even if every off-chain layer is compromised, `_authorizeAgent()` blocks unauthorized actions on-chain.
 
---
 
## Technical Highlights
 
| What | How |
|------|-----|
| **LMSR pricing engine** | Off-chain `exp()` via 20-term Taylor series with range reduction; `ln()` via Halley's method (cubic convergence, ≤8 steps); WAD-scaled (1e18) BigInt throughout; log-sum-exp trick prevents overflow |
| **Dual-path price sync** | Hub→spoke prices propagate via both CCIP messages and CRE `writeReport` calls — redundancy plus lower latency |
| **4-band deviation policy** | Normal / Stress / Unsafe / CircuitBreaker with progressive fee surcharges, output caps, direction locks, and halt |
| **6-layer agent security** | HTTP key gate → EIP-712 session signature → one-time Firestore approval with nonce → execute policy allowlist → on-chain `_authorizeAgent()` → router balance guard |
| **AI market resolution** | Gemini 2.5 Flash with search grounding; handles edge cases (postponement, cancellation, contradictory sources); falls back to manual review rather than forcing a binary outcome |
| **3 isolated CRE workflows** | Automation, user ops, and agent trading deploy independently with separate key sets and failure domains |
| **UUPS-upgradeable contracts** | `PredictionMarket`, `MarketFactory`, `RouterVault` — diamond-style module inheritance behind UUPS proxies with `ReentrancyGuard` and `Pausable` |
| **Cross-chain claim bridge** | Lock/mint/burn/unlock of outcome token positions across chains via CCIP with replay protection and trusted-remote validation |
 
---
 
## LMSR: Why It Replaces CPMM for Prediction Markets
 
GeoChain migrated from a Constant Product Market Maker to LMSR. The CPMM branch is preserved in repository history. Here's why LMSR is the correct mechanism:
 
| Dimension | CPMM (x · y = k) | LMSR (C = b · ln(Σ exp(qᵢ/b))) |
|-----------|-------------------|----------------------------------|
| Pricing model | Price derived from reserve ratio; no concept of probabilities | Price directly represents calibrated probability via softmax |
| Slippage behavior | Grows superlinearly with trade size relative to reserves | Controlled by liquidity parameter `b`; predictable for any trade size |
| Multi-outcome support | Limited to 2-outcome (YES/NO) pairs per pool | Naturally extends to N outcomes in a single cost function |
| LP risk | Impermanent loss; requires active management | Bounded subsidy: max loss = `b × ln(N)`, known at creation |
| Suitability | Prices don't map to probabilities; requires external interpretation | Prices are probabilities by construction; grounded in proper scoring rules |
| Liquidity bootstrapping | Requires initial reserve deposits in both tokens | Single collateral deposit; subsidy computed deterministically |
 
### The LMSR Cost Function
 
```
C(q) = b × ln( Σᵢ exp(qᵢ / b) )
```
 
The price (probability) of outcome `i`:
 
```
pᵢ = ∂C/∂qᵢ = exp(qᵢ / b) / Σⱼ exp(qⱼ / b)
```
 
This is the softmax function — prices are always positive and always sum to 1.0.
 
Cost of buying Δ shares of outcome `i`:
 
```
cost = C(q + Δeᵢ) − C(q)
```
 
Maximum market maker loss for a binary market:
 
```
maxLoss = b × ln(2)
```
 
Computed on-chain via `LMSRLib.maxSubsidyLoss()` and locked as collateral at market creation.
 
### EVM Implementation
 
`exp()` and `ln()` have no native EVM opcodes. Computing them on-chain in `uint256` arithmetic is gas-prohibitive and risks overflow with large share quantities.
 
**GeoChain's hybrid architecture:**
- **Off-chain (CRE — `httpLmsrTrade.ts`):** `exp()` via 20-term Taylor series with range reduction (`exp(x) = 2^k × exp(r)`, `r ∈ [0, ln2)`); `ln()` via Halley's method (third-order convergence, ≤8 steps). All arithmetic in BigInt at WAD scale — no floating-point anywhere in the math path.
- **On-chain (`LMSRLib.sol`):** Validates CRE-reported prices sum to `1e6 ± 0.1%`, enforces monotonic trade nonces to prevent replay, executes token transfers. The contract never computes `exp()` or `ln()` itself.
 
Mathematically correct LMSR pricing with EVM-safe execution.
 
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
│   ├── PredictionMarketRouterVaultBase.sol          # User collateral credits, agent permissions, session management
│   └── PredictionMarketRouterVaultOperations.sol    # All user & agent-delegated actions (mint, redeem, swap, dispute)
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
 
All market lifecycle operations run as autonomous CRE workflows:
 
| Trigger | Handler | What It Does |
|---------|---------|--------------|
| Cron | `resolveEvent` | Detects markets past resolution time → Gemini AI with search grounding → delivers resolution report on-chain |
| Cron | `createPredictionMarketEvent` | Gemini generates unique event ideas → deploys new markets with LMSR initialization |
| Cron | `syncCanonicalPrice` | Reads hub prices → writes `syncSpokeCanonicalPrice` reports directly to each spoke factory |
| Cron | `arbitrateUnsafeMarketHandler` | Detects Unsafe/CircuitBreaker spoke markets → executes corrective LMSR trades |
| Cron | `preCloseLmsrSellHandler` | Unwinds factory-held outcome shares before market close |
| Cron | `adjudicateExpiredDisputeWindows` | Auto-finalizes undisputed resolutions after dispute window expiry |
| Cron | `processPendingWithdrawalsHandler` | Batch-processes queued LP withdrawal requests |
| Cron | `marketFactoryBalanceTopUp` | Monitors collateral balance → auto-replenishes when low |
| HTTP | `sponsorUserOpPolicyHandler` | Validates EIP-712 signatures → creates one-time Firestore approvals for gasless user actions |
| HTTP | `executeReportHttpHandler` | Consumes approvals → ABI-encodes payload → submits on-chain report |
| HTTP | `lmsrTradeHttpHandler` | Full LMSR pipeline: read on-chain state → compute cost/prices off-chain → submit trade report |
| HTTP | `agentPlanTrade / agentExecuteTrade` | Agent-specific trade validation and execution through dedicated policy |
| EVM Log | `ethCreditFromLogsHandler` | Detects ETH deposit events → credits user's router balance |
 
### CCIP (Cross-Chain Interoperability Protocol)
 
**Dual-path price propagation** keeps spoke markets synchronized through two independent channels:
 
- **CCIP messages** — `MarketFactoryCcip.sol` sends/receives structured messages between hub and spoke factories
- **CRE direct reports** — `syncPrice.ts` reads hub state and writes `syncSpokeCanonicalPrice` reports directly to spoke factories
 
This redundancy ensures price sync even if one path experiences latency or downtime.
 
### Hub-Spoke Architecture
 
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
 
Deviation bands protect spoke markets from trading at stale prices:
 
| Band | Deviation | Effect |
|------|-----------|--------|
| Normal | ≤ softDeviationBps | Base fee, unlimited output, both directions |
| Stress | ≤ stressDeviationBps | Extra fee + capped output |
| Unsafe | ≤ hardDeviationBps | 2× extra fee + tighter cap + price-corrective direction only |
| CircuitBreaker | > hardDeviationBps | 5× extra fee + minimal cap + all trading halted |
 
---
 
## Agent Delegation Security Model
 
Users authorize AI agents to trade on their behalf — funds never leave the RouterVault.
 
```
User ──setAgentPermission()──► Router ──_authorizeAgent()──► Execute
        (actionMask,                    (enabled? expired?
         maxAmountPerAction,             action allowed?
         expiresAt)                      amount within cap?)
```
 
**6 independent security layers:**
 
| Layer | Protection | Enforcement Point |
|-------|------------|-------------------|
| 1 | HTTP authorized key gate | CRE trigger configuration |
| 2 | EIP-712 session signature + sponsor policy validation | CRE HTTP handler |
| 3 | One-time Firestore approval with nonce replay protection | CRE state layer |
| 4 | Execute policy action allowlist | CRE execution handler |
| 5 | On-chain `_authorizeAgent()` — permission bitmap, expiry, action mask, per-action amount cap | Smart contract |
| 6 | Router collateral/token credit balance checks | Smart contract |
 
Even if all off-chain layers are compromised, on-chain `_authorizeAgent()` blocks unauthorized actions.
 
**Agent API:**
```
POST /agent/plan     →  Validate intent against agentPolicy (allowed actions, max amount, supported chains)
POST /agent/sponsor  →  Session signature verification + one-time approval creation
POST /agent/execute  →  Consume approval → encode routerAgent payload → submit on-chain report
POST /agent/revoke   →  Terminate agent session
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
 
Why three separate deployments? Independent upgrade cycles, scoped key sets (automation / user-op / agent keys are never shared), isolated failure domains, and clear policy separation across six distinct policies: `sponsorPolicy`, `executePolicy`, `lmsrTradePolicy`, `agentPolicy`, `ethCreditPolicy`, `fiatCreditPolicy`.
 
---
 
## Live Deployments
 
### Arbitrum Sepolia (Hub)
 
| Contract | Address |
|----------|---------|
| MarketFactory | `0xA33Ac22e58d34712928d1D1E4CD5201349DCD023` |
| RouterVault | `0xEeD3dc1B401ebd6C22E00641Cc6663FfC20f40b5` |
| Bridge | `0xcb55019591457b2Ea6fbCd779cAF087a6890a06A` |
| Collateral (USDC) | `0xe34742D957708d2c91CA8827F758b3843d681b3e` |
 
### Base Sepolia (Spoke)
 
| Contract | Address |
|----------|---------|
| MarketFactory | `0xf04E1047F34507C7Cf60fDc811116Bc7b0E923f3` |
| RouterVault | `0xef21B5c764186B9D3faD4D610564816fA7e461d4` |
| Bridge | `0x915E3Ee1A09b08038e216B0eCbe736164a246aA3` |
| Collateral (USDC) | `0x57e91c594f77Fca0cb6760267586772E3A3f054F` |
 
---
 
## Getting Started
 
### Prerequisites
 
| Tool | Version | Install |
|------|---------|---------|
| Foundry (Forge, Anvil, Cast) | Latest | [getfoundry.sh](https://getfoundry.sh) |
| Bun | ≥ 1.0 | [bun.sh](https://bun.sh) |
| Node.js | ≥ 18 | [nodejs.org](https://nodejs.org) |
| Chainlink CRE CLI | Latest | [docs.chain.link/cre](https://docs.chain.link/cre) |
 
### Build & Test Smart Contracts
 
```bash
cd contract
 
# Install Foundry dependencies (OpenZeppelin, forge-std)
forge install
 
# Build (via_ir + optimizer with 200 runs)
forge build
 
# Run tests
forge test              # unit + fuzz + invariant
forge test -vv          # with verbose logs
forge test --gas-report # with gas profiling
 
# Coverage
forge coverage
```
 
### Deploy Locally (Anvil)
 
```bash
# Terminal 1
anvil
 
# Terminal 2
forge script script/deployMarketFactory.s.sol --rpc-url http://127.0.0.1:8545 --broadcast
forge script script/deployRouterVault.s.sol --rpc-url http://127.0.0.1:8545 --broadcast
forge script script/deployBridge.sol --rpc-url http://127.0.0.1:8545 --broadcast
```
 
### Deploy to Testnet
 
```bash
# Arbitrum Sepolia (Hub)
forge script script/deployMarketFactory.s.sol \
  --rpc-url https://sepolia-rollup.arbitrum.io/rpc \
  --private-key $PRIVATE_KEY \
  --broadcast --verify
 
# Base Sepolia (Spoke)
forge script script/deployMarketFactory.s.sol \
  --rpc-url https://sepolia.base.org \
  --private-key $PRIVATE_KEY \
  --broadcast --verify
```
 
### Environment Variables
 
```bash
# contract/.env
PRIVATE_KEY=<deployer-wallet-private-key>
RPC_URL=<arbitrum-sepolia-or-base-sepolia-rpc>
ETHERSCAN_API_KEY=<optional-for-verification>
```
 
### CRE Workflow Secrets
 
| Secret ID | Description | Source |
|-----------|-------------|--------|
| `AI_KEY` | Google Gemini API key | Google AI Studio |
| `FIREBASE_API_KEY` | Firebase Web API key | Firebase Console → Project Settings |
| `FIREBASE_PROJECT_ID` | Firebase project ID | Firebase Console → Project Settings |
 
```bash
cre secrets set AI_KEY <your-gemini-api-key>
cre secrets set FIREBASE_API_KEY <your-firebase-api-key>
cre secrets set FIREBASE_PROJECT_ID <your-firebase-project-id>
```
 
### Deploy CRE Workflows
 
```bash
cd cre/market-automation-workflow && bun install
cre workflow deploy --target staging-settings
 
cd cre/market-users-workflow && bun install
cre workflow deploy --target staging-settings
 
cd cre/agents-workflow && bun install
cre workflow deploy --target staging-settings
```
 
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
 
## Tech Stack
 
| Layer | Technology |
|-------|-----------|
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
 
## Skills Demonstrated
 
| Domain | What's in This Codebase |
|--------|------------------------|
| Smart Contract Engineering | UUPS-upgradeable modular architecture across 3 proxy contracts; `_processReport` dispatcher routing 10+ action types via precomputed `keccak256` hashes; storage-layout-safe migration from CPMM to LMSR with deprecated slot preservation |
| DeFi Protocol Design | LMSR pricing with bounded market-maker subsidy (`b × ln(N)`); complete-set mint/redeem with fee accounting; queued withdrawal system for LP exits |
| Cross-Chain Architecture | Hub-spoke topology with dual-path price sync (CCIP + CRE direct); 4-band deviation policy with progressive circuit breakers; cross-chain claim bridge with replay protection |
| Automated Systems | 3 independently deployed CRE workflows; 15+ handlers across cron, HTTP, and EVM-log triggers; fully autonomous market lifecycle from creation through resolution |
| Mathematical Finance | Off-chain LMSR cost function via log-sum-exp; `exp()` via 20-term Taylor series; `ln()` via Halley's method; WAD-scaled (1e18) fixed-point with no floating-point contamination |
| Security Design | 6-layer agent delegation; EIP-712 typed-data session signatures; one-time approval consumption with nonce replay protection; per-user risk exposure caps (5% of total liquidity); on-chain action-mask bitfield authorization |
| Testing | Unit, stateless fuzz, and stateful invariant tests across all core contracts; Foundry gas profiling and coverage reporting |
 
---
 
## Contact
 
**Built by Himxa** — open to smart contract and protocol engineering roles.
 
📧 [himxa0x@gmail.com](mailto:himxa0x@gmail.com)
 