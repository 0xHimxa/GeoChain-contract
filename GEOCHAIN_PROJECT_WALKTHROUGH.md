# GeoChain: Cross-Chain Prediction Markets Powered by Chainlink CRE

> **Chainlink Convergence Hackathon 2026 — Full Project Walkthrough**

---

## The Problem: Why Prediction Markets Are Broken Today

Prediction markets are one of the most powerful tools for real-time information discovery. But despite billions in volume across platforms like Polymarket and Kalshi, the experience is fundamentally broken for most users and operators.

### For Users

| Pain Point | What Happens Today |
|---|---|
| **Wallet fatigue** | Every trade requires 2–3 separate wallet signatures (approve → deposit → swap). Users abandon markets because interacting is exhausting. |
| **Chain lock-in** | Your funds are stuck on one chain. If a market lives on Arbitrum and your money is on Base, you're out of luck. |
| **No fiat onramp** | Most platforms require users to already hold crypto. This excludes 99% of potential participants. |
| **Opaque resolution** | Markets resolve through centralized admin actions with no transparency about *why* an outcome was chosen. |

### For Operators

| Pain Point | What Happens Today |
|---|---|
| **Manual market management** | Operators manually create markets, set prices, and trigger resolutions — often with deploy scripts and ad-hoc cron jobs. |
| **Price inconsistency across chains** | Cross-chain deployments have no canonical source of truth. Prices drift independently on each chain, creating arbitrage gaps and user confusion. |
| **Liquidity black holes** | When factory or router contracts run dry, trading halts until someone manually tops up — which can take hours. |
| **Five backend services** | Traditional architectures require separate services for auth, relaying, cron jobs, event listening, and cross-chain sync. Each one is a failure point. |

---

## Our Solution: GeoChain

**GeoChain is a cross-chain prediction market protocol where Chainlink CRE replaces five backend services with one orchestrated workflow runtime.**

Users trade with zero gas signatures. Markets create themselves. Prices stay synchronized. Liquidity never runs dry. And every action is policy-enforced and replay-protected.

### Three Layers, One System

```
┌─────────────────────────────────────────────────────────────────┐
│                        FRONTEND (React)                        │
│   Session wallet · Multi-chain · Fiat/ETH/USDC onramps        │
│   Zero-gas sponsored trading · Real-time market discovery      │
└────────────────────────┬───────────────────────────────────────┘
                         │ HTTP triggers
┌────────────────────────▼───────────────────────────────────────┐
│                CRE WORKFLOW (Chainlink Runtime)                │
│   Policy enforcement · Sponsored execution · Event creation    │
│   Price sync · Arbitrage · Resolution · Liquidity top-ups      │
│   Fiat credit · ETH deposit credit · Withdrawal processing    │
│                                                                │
│   ┌──────────┐  ┌──────────┐  ┌──────────┐                    │
│   │  Cron    │  │  HTTP    │  │ EVM Log  │   ← 3 trigger types│
│   │ Triggers │  │ Triggers │  │ Triggers │                     │
│   └──────────┘  └──────────┘  └──────────┘                     │
└────────────────────────┬───────────────────────────────────────┘
                         │ On-chain reports
┌────────────────────────▼───────────────────────────────────────┐
│              SMART CONTRACTS (Solidity, Multi-Chain)            │
│   MarketFactory (hub/spoke) · PredictionMarket (AMM)           │
│   RouterVault (custodial credits) · CCIP bridge                │
│   Canonical pricing · Deviation policy · Fee accounting        │
└────────────────────────────────────────────────────────────────┘
```

---

## How It Works: End-to-End Flows

### Flow 1 — Sponsored Trading (Zero-Gas UX)

This is the core user flow. A user trades a prediction market without paying gas or signing multiple wallet transactions.

```
User clicks "Buy YES"
        │
        ▼
   ┌─────────────┐     EIP-712 session signature
   │  Frontend    │────────────────────────────────┐
   │  (App.tsx)   │                                │
   └──────┬───────┘                                │
          │ HTTP POST                              │
          ▼                                        ▼
   ┌───────────────────┐              ┌───────────────────┐
   │ CRE Sponsor       │  validates   │ Session Wallet    │
   │ Policy Handler    │◄─────────────│ (browser-local)   │
   │                   │  chain/      └───────────────────┘
   │ Checks:           │  action/
   │ • Action allowed? │  amount/
   │ • Chain supported?│  slippage/
   │ • Amount ≤ limit? │  signature
   │ • Session valid?  │
   └──────┬────────────┘
          │ Writes 1-time approval to Firestore
          ▼
   ┌───────────────────┐
   │ CRE Execute       │  consumes approval EXACTLY ONCE
   │ Report Handler    │  submits on-chain report
   └──────┬────────────┘
          │
          ▼
   ┌───────────────────┐
   │ Router Vault      │  dispatches to market:
   │ (on-chain)        │  routerMintCompleteSets /
   │                   │  routerSwapYesForNo /
   │                   │  routerRedeem / etc.
   └───────────────────┘
```

**Why this matters:** The user signed once. CRE handled policy, approval, consumption, and on-chain execution. No MetaMask popups. No gas fee. No replay possible.

### Flow 2 — Automated Market Lifecycle

Markets don't need an operator babysitting them. CRE cron handlers run every 30 seconds and handle the full lifecycle:

| Stage | CRE Handler | What Happens |
|---|---|---|
| **Creation** | `marketCreation.ts` | Pulls trending events from Firestore, uses Gemini AI to generate market questions, deploys to ALL configured chains |
| **Price Sync** | `syncPrice.ts` | Reads hub-chain AMM prices, propagates canonical prices to spoke chains with short-lived validity windows |
| **Arbitrage** | `arbitrage.ts` | Monitors deviation bands, auto-corrects unsafe price drift with bounded spend limits |
| **Top-Up** | `topUpMarket.ts` | Checks factory/bridge/router collateral balances, mints USDC when below threshold |
| **Resolution** | `resolve.ts` | Checks `checkResolutionTime()` on every active market, submits `ResolveMarket` reports for eligible ones |
| **Withdrawals** | `marketWithdrawal.ts` | Drains queued post-resolution withdrawals in batches |

**Why this matters:** One CRE workflow replaces what would traditionally be 6 separate cron services, each with its own deployment, monitoring, and failure mode.

### Flow 3 — Multi-Source Funding

Users can fund their trading vault from three different sources, all unified through CRE:

| Source | Handler | How It Works |
|---|---|---|
| **USDC Deposit** | Direct on-chain | MetaMask `depositFor()` → Router credits user |
| **Fiat Payment** | `httpFiatCredit.ts` | Payment callback → CRE validates → `routerCreditFromFiat` report |
| **ETH Transfer** | `ethCreditFromLogs.ts` | `EthReceived` log → CRE converts ETH→USDC → `routerCreditFromEth` report |

Each flow has explicit replay protection:
- Fiat: Firestore payment consumption (one-time)
- ETH: Deterministic `depositId` derived from `keccak256(txHash, logIndex)`
- USDC: Standard on-chain nonce

---

## Smart Contract Architecture

### Hub-Spoke Cross-Chain Design

```
         ┌─────────────────────┐
         │ Arbitrum Sepolia     │
         │ (HUB)               │
         │                     │
         │ MarketFactory ──────┼──── Creates markets
         │ PredictionMarket ───┼──── AMM + resolution
         │ RouterVault ────────┼──── User credits
         │ Bridge ─────────────┼──── CCIP sender
         └─────────┬───────────┘
                   │ CCIP messages:
                   │ • CanonicalPriceSync
                   │ • ResolutionSync
                   ▼
         ┌─────────────────────┐
         │ Base Sepolia         │
         │ (SPOKE)             │
         │                     │
         │ MarketFactory ──────┼──── Mirrors markets
         │ PredictionMarket ───┼──── AMM + canonical pricing
         │ RouterVault ────────┼──── User credits
         │ Bridge ─────────────┼──── CCIP receiver
         └─────────────────────┘
```

### Key Contracts

| Contract | Role |
|---|---|
| **MarketFactory** | Upgradeable (UUPS) factory that deploys markets, seeds liquidity, maintains active market registry, and handles CRE report dispatch for admin actions (`createMarket`, `mintCollateralTo`, `priceCorrection`) |
| **PredictionMarket** | Binary YES/NO market with constant-product AMM, complete set minting, canonical pricing deviation rails, resolution + manual review, and CRE-driven `ResolveMarket` execution |
| **RouterVault** | Custodial credit system — users deposit once, trade many times. Dispatches 7 action types from CRE reports. Supports collateral, outcome tokens, and LP share credits |
| **CanonicalPricingModule** | Computes deviation bands (Normal/Stress/Unsafe/CircuitBreaker) between local AMM price and hub canonical price, enforcing fees and trade restrictions at each level |

### Canonical Pricing Safety Rails

The deviation policy protects spoke-chain markets from price manipulation:

```
0%          Soft         Stress        Hard        100%
├───────────┼────────────┼─────────────┼───────────┤
  Normal     Direction    Extra fees   CIRCUIT
  trading    restricted   + max caps   BREAKER
                                       (halt)
```

- **Normal band:** Free trading at standard fees
- **Stress band:** Only trades that push price toward canonical value are allowed; extra fee applied
- **Unsafe band:** CRE arbitrage handler auto-corrects; max output caps enforced
- **Circuit breaker:** Trading halted until hub price sync restores safety

---

## Frontend: Session-Based Zero-Friction UX

The frontend (`App.tsx`) eliminates the typical DeFi wallet-signing fatigue:

1. **Sign in once** — a browser-local encrypted wallet is created and stored
2. **Session identity** — EIP-712 typed signatures authorize a session with action/amount/time bounds
3. **Trade without popups** — session wallet signs trade intents locally, CRE sponsors execution
4. **MetaMask only for deposits** — external wallet used only when funding the vault
5. **Multi-chain aware** — switch between Base Sepolia and Arbitrum Sepolia; markets refresh automatically

### What The User Sees

| Page | Functionality |
|---|---|
| **Markets** | Active and closed markets with real-time prices, countdown to close/resolution, YES/NO probability display |
| **Deposit** | Connect MetaMask → `depositFor()` local wallet |
| **Fiat** | Pay with Google Pay/card → CRE credits vault |
| **Positions** | View YES/NO share balances, redeemable USDC, and claim resolved winnings |

---

## Security & Risk Controls

| Layer | Control | Implementation |
|---|---|---|
| **CRE** | One-time approval consumption | Firestore record written on approve, consumed on execute |
| **CRE** | Action allowlists | Config-driven `allowedActions` and `allowedActionTypes` |
| **CRE** | Chain allowlists | `supportedChainIds` per policy |
| **CRE** | Session authorization | EIP-712 session grant + per-request signatures |
| **CRE** | Amount/slippage caps | `maxAmountUsdc` and `maxSlippageBps` per policy |
| **Contract** | Risk exposure cap | Per-address minting limited to 10,000 USDC |
| **Contract** | Reentrancy guards | `ReentrancyGuard` on all state-changing functions |
| **Contract** | Canonical price gates | Deviation policy prevents manipulation on spoke chains |
| **Contract** | Manual review | Inconclusive outcomes trigger review mode requiring second owner action |
| **Contract** | Market allowlisting | Router only interacts with factory-registered markets |
| **Deposits** | Replay protection | Deterministic `depositId` (ETH), payment consumption (fiat), on-chain nonce (USDC) |

---

## Deployed Contracts (Testnet)

| Chain | Contract | Address |
|---|---|---|
| Arbitrum Sepolia | MarketFactory | `0x145A8D0eD56fd02A8b29b2E81C09F5d66e1918Ec` |
| Arbitrum Sepolia | RouterVault | `0x3E6206fa635C74288C807ee3ba90C603a82B94A8` |
| Arbitrum Sepolia | Bridge | `0x0043866570462b0495eC23d780D873aF1afA1711` |
| Arbitrum Sepolia | Collateral (USDC) | `0x28dF0b4CD6d0627134b708CCAfcF230bC272a663` |
| Base Sepolia | MarketFactory | `0x54DDeC2F7420b3AF1BB53157f3c533F9Ad598651` |
| Base Sepolia | RouterVault | `0x1381A3b6d81BA62bb256607Cc2BfBBd5271DD525` |
| Base Sepolia | Bridge | `0xf898E8b44513F261a13EfF8387eC7b58baB4846e` |
| Base Sepolia | Collateral (USDC) | `0x15a6D5380397644076f13D76B648A45B29e754bc` |

---

## Repository Map

```
contracts/
├── contract/                         # Solidity smart contracts (Foundry)
│   ├── src/
│   │   ├── marketFactory/            # Hub/spoke factory (5 files)
│   │   ├── predictionMarket/         # AMM + resolution (4 files)
│   │   ├── router/                   # Custodial vault (3 files)
│   │   ├── ccip/                     # Cross-chain messaging
│   │   ├── Bridge/                   # CCIP bridge adapter
│   │   ├── libraries/                # AMMLib, FeeLib, MarketTypes
│   │   └── modules/                  # CanonicalPricingModule
│   ├── test/                         # Unit + fuzz tests
│   └── script/                       # Deploy + upgrade scripts
│
├── cre/                              # Chainlink CRE workflow
│   └── market-workflow/
│       ├── main.ts                   # Workflow graph (cron/HTTP/log)
│       ├── handlers/
│       │   ├── cronHandlers/         # 6 automation handlers
│       │   ├── httpHandlers/         # 4 policy/execution handlers
│       │   └── eventsHandler/        # 1 log-driven handler
│       ├── firebase/                 # Auth + Firestore
│       └── gemini/                   # AI event generation
│
└── frontend/
    └── minimal-sponsor-ui/
        ├── src/App.tsx               # Main UI component
        ├── src/chain.ts              # Multi-chain config + reads
        └── server.ts                 # Backend bridge / mock server
```

---

## One-Line Value Proposition

**GeoChain replaces five backend services with one CRE workflow — making prediction markets self-operating, cross-chain, zero-gas for users, and policy-secure by default.**
