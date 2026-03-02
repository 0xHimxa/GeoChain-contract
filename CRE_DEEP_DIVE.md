# How GeoChain Uses Chainlink CRE — And Why It Changes Everything

> **A deep dive into CRE usage for Chainlink Convergence 2026 hackathon judges**

---

## What Is CRE?

The **Chainlink Runtime Environment (CRE)** is an all-in-one orchestration layer that lets developers compose multi-trigger, multi-chain workflows running on a Decentralized Oracle Network (DON). Instead of building separate backend services for data fetching, transaction relaying, cron scheduling, and event listening — you write one workflow in TypeScript and deploy it.

CRE provides:
- **Cron triggers** — scheduled recurring execution
- **HTTP triggers** — request/response API-style endpoints
- **EVM log triggers** — react to on-chain events
- **EVM read/write** — call and transact with contracts on any chain
- **Report signing** — BFT consensus ensures all actions are cryptographically verified
- **Secret management** — secure credential handling

The key property: **every operation runs across multiple independent DON nodes with Byzantine Fault Tolerant consensus**, giving off-chain logic the same trust guarantees as on-chain transactions.

---

## The Core Problem We Solved

Building a prediction market contract is straightforward. **Running one reliably in production is not.**

The real challenge wasn't "how do we let someone place a trade." The real challenge was:

> **How do we coordinate policy enforcement, gas sponsorship, multi-source funding, cross-chain price synchronization, automated market lifecycle operations, and arbitrage correction — without building and maintaining 5–6 separate backend services that each have their own failure modes?**

CRE is the answer.

---

## Before CRE vs. After CRE

### The Traditional Approach (What Teams Built Before)

```
┌────────────────────────────────────────────────────────────┐
│ TYPICAL PREDICTION MARKET BACKEND                         │
│                                                           │
│  ┌──────────────┐  ┌──────────────┐  ┌────────────────┐  │
│  │ API Service  │  │ Relayer      │  │ Event Listener │  │
│  │ (auth, UX)   │  │ (tx submit)  │  │ (deposits)     │  │
│  └──────┬───────┘  └──────┬───────┘  └──────┬─────────┘  │
│         │                 │                  │            │
│  ┌──────▼───────┐  ┌──────▼───────┐  ┌──────▼─────────┐  │
│  │ Cron Worker  │  │ Cross-chain  │  │ Database +     │  │
│  │ (resolution, │  │ Sync Worker  │  │ Lock/Retry     │  │
│  │  maintenance)│  │ (price relay)│  │ Layer          │  │
│  └──────────────┘  └──────────────┘  └────────────────┘  │
│                                                           │
│  ❌ 6 services · 6 deployments · 6 failure modes          │
│  ❌ Policy logic duplicated across services                │
│  ❌ No unified replay protection                           │
│  ❌ Cross-chain consistency is a hope, not a guarantee     │
└────────────────────────────────────────────────────────────┘
```

### The GeoChain Approach (One CRE Workflow)

```
┌────────────────────────────────────────────────────────────┐
│ GEOCHAIN CRE WORKFLOW (main.ts)                           │
│                                                           │
│  ┌──────────────────────────────────────────────────────┐ │
│  │              Single Workflow Runtime                  │ │
│  │                                                      │ │
│  │  Cron ──► Market creation (Gemini AI + Firestore)    │ │
│  │  Cron ──► Price sync (hub → spoke)                   │ │
│  │  Cron ──► Arbitrage correction                       │ │
│  │  Cron ──► Resolution                                 │ │
│  │  Cron ──► Withdrawal processing                      │ │
│  │  Cron ──► Liquidity top-up                           │ │
│  │  HTTP ──► Sponsor policy (validate + approve)        │ │
│  │  HTTP ──► Execute report (consume + write)           │ │
│  │  HTTP ──► Fiat credit (validate + credit)            │ │
│  │  HTTP ──► Session revocation                         │ │
│  │  Log  ──► ETH deposit credit                         │ │
│  │                                                      │ │
│  │  ✅ 1 deployment · 1 runtime · 1 config model        │ │
│  │  ✅ Policy enforcement co-located with execution      │ │
│  │  ✅ Replay protection built into every flow           │ │
│  │  ✅ Cross-chain reads & writes in same workflow       │ │
│  └──────────────────────────────────────────────────────┘ │
└────────────────────────────────────────────────────────────┘
```

---

## Problem-by-Problem Breakdown

### Problem 1: Gasless Trading Without AA/Bundler Infrastructure

**How it was done before:**

Platforms that want gasless trading adopt Account Abstraction (ERC-4337) with bundler services like Pimlico or Stackup, plus Paymaster contracts to cover gas. This works, but introduces real problems:

- **Extra infrastructure:** You now depend on a bundler service (availability, throughput, pricing), a Paymaster contract (funding, security), and a UserOp mempool — all additional failure points
- **Policy separation:** The approve and execute steps happen inside the bundler pipeline. Policy logic (what's allowed, how much) lives in application code that can drift from actual execution constraints
- **Replay risk:** If the bundler retries on timeout, or the backend sends the same UserOp twice, duplicate execution risk exists — each service must implement "exactly once" independently
- **Users still need a wallet:** Even with AA, users typically need MetaMask or another wallet extension installed. The AA stack abstracts gas, not onboarding

**How GeoChain solves it with CRE:**

We eliminate the entire AA/bundler stack. Users sign in with email and password (Web2 style), get a browser-local encrypted wallet, and CRE handles execution directly:

```typescript
// Step 1: Policy handler validates everything and writes approval
// handlers/httpHandlers/httpSponsorPolicy.ts
→ Validates: chain, action, actionType mapping, amount, slippage, session signature
→ Writes: short-lived Firestore approval record (1-time consumable)
→ Returns: { approved: true, approvalId: "cre_approval_...", expiresAtUnix }

// Step 2: Execute handler consumes approval and writes on-chain report
// handlers/httpHandlers/httpExecuteReport.ts
→ Validates: approvalId exists, not expired, not consumed, amounts match
→ Consumes: approval record (exactly once)
→ Writes: on-chain report to Router or Factory via CRE writeReport()
```

**Why CRE makes this better than AA/bundlers:**
- **No bundler, no Paymaster, no UserOp mempool** — CRE submits the on-chain report directly via `writeReport()`. Three pieces of infrastructure eliminated
- **No wallet extension required** — users sign in with email/password; the browser-local wallet handles signing. Web2 onboarding, non-custodial under the hood
- **Policy and execution in one DON** — BFT consensus means no single server can be manipulated
- **Atomic approval consumption** — replay is structurally impossible, not just "hopefully prevented"
- **Session authorization** uses EIP-712 typed signatures verified inside the CRE handler

---

### Problem 2: Multi-Source Funding Without Double Credits

**How it was done before:**

Payment webhooks arrive → backend trusts the callback → credits balance → submits on-chain tx. If the webhook fires twice, or the on-chain tx is retried, users get credited double. Teams build ad-hoc database locks, but these break under concurrent requests and reorgs.

For ETH deposits, custom event indexers watch for transfer logs. If the indexer restarts or reprocesses blocks, the same deposit can be credited again. Building "exactly once" semantics across payment providers, chain events, and database records is one of the hardest distributed systems problems.

**How GeoChain solves it with CRE:**

**Fiat credit flow (`httpFiatCredit.ts`):**
```
Payment success → CRE HTTP handler → validate(provider, chain, user, amount)
  → consumeFiatPaymentRecord(Firestore) ← prevents replay
  → submit routerCreditFromFiat report → Router credits user on-chain
```

**ETH deposit flow (`ethCreditFromLogs.ts`):**
```
User sends ETH to Router → EthReceived event emitted
  → CRE EVM Log trigger fires → handler validates log shape
  → depositId = keccak256(txHash, logIndex) ← deterministic, unique
  → submit routerCreditFromEth report → Router credits once per depositId
```

**Why CRE makes this better:**
- Log triggers are native to CRE — no custom event indexer service to maintain
- Firestore consumption happens *inside* the CRE handler, not in a separate service that might be out of sync
- Deterministic deposit IDs mean even if the log trigger fires twice, the Router contract rejects the duplicate
- All three funding paths (USDC, fiat, ETH) go through the same Router Vault, so users see one unified balance

---

### Problem 3: Cross-Chain Price and Resolution Consistency

**How it was done before:**

Teams deployed markets on multiple chains and ran separate relay scripts to synchronize prices and resolution outcomes. These scripts had independent uptime, their own retry logic, and no coordination. Result: spoke chains showed stale prices, users traded on wrong information, and resolution could happen on one chain but not another.

**How GeoChain solves it with CRE:**

```typescript
// handlers/cronHandlers/syncPrice.ts
// Runs every 30 seconds

1. Read active markets from hub MarketFactory (Arbitrum)
2. For each market:
   a. Read marketId, yesPriceE6, noPriceE6 from hub PredictionMarket
   b. Create payload with 15-minute validity window
   c. Sign report via CRE consensus
   d. Write report to EVERY spoke factory (Base, etc.)
3. Spokes reject stale prices (validUntil expired)
```

The contract side enforces deviation bands:

| Band | Behavior | CRE Role |
|---|---|---|
| **Normal** | Free trading at standard fees | Price sync keeps band normal |
| **Stress** | Direction-restricted trading + extra fees | Price sync attempts to correct |
| **Unsafe** | CRE arbitrage handler intervenes | `arbitrage.ts` submits `priceCorrection` reports |
| **Circuit Breaker** | Trading halted | Price sync restores safety before trading resumes |

**Why CRE makes this better:**
- Hub reads and spoke writes happen in the same workflow handler — no coordination gap
- The same CRE runtime handles both regular price sync AND emergency arbitrage, so there's no window where one service is healthy and the other isn't
- Short validity windows (`validUntil`) are enforced on-chain — stale CRE reports are rejected

---

### Problem 4: Market Lifecycle Automation

**How it was done before:**

Market creation: manual. Resolution: manual RPC call. Liquidity top-up: "someone noticed the factory balance went to zero." Withdrawal processing: "we'll get to it." Each task is a separate script or cron job, deployed independently, failing silently when something breaks.

**How GeoChain solves it with CRE:**

One cron schedule (`*/30 * * * * *` — every 30 seconds) drives SIX automated handlers:

| Handler | What It Does | Why It Matters |
|---|---|---|
| `marketCreation.ts` | Fetches existing events from Firestore, asks Gemini AI for new market question, creates on ALL chains | Markets appear automatically with AI-sourced topics |
| `resolve.ts` | Checks `checkResolutionTime()` per market, submits `ResolveMarket` reports | No human operator needed for resolution |
| `topUpMarket.ts` | Reads factory/bridge/router USDC balances, mints when below threshold | Liquidity never runs dry (~50K USDC trigger, ~140K top-up) |
| `syncPrice.ts` | Hub→spoke canonical price propagation | Cross-chain consistency maintained continuously |
| `arbitrage.ts` | Detects unsafe deviation bands, submits bounded `priceCorrection` | Price manipulation corrected automatically |
| `marketWithdrawal.ts` | Drains post-resolution withdrawal queue in batches | Users don't wait for manual settlement |

**Why CRE makes this better:**
- All six handlers run under the same cron trigger — they succeed or fail together, no partial state
- Configuration is unified in one JSON file per environment — no scattered env vars across services
- The CRE runtime provides `runtime.log()` for every handler — unified observability instead of checking 6 separate services

---

### Problem 5: External System Integration

**How it was done before:**

Connecting to Firebase, Gemini API, payment providers, and multiple chains meant writing custom glue code for each integration, managing API keys across services, and handling authentication in different ways for different backends.

**How GeoChain solves it with CRE:**

The CRE workflow natively integrates:
- **Firebase Auth** — `signUpWorkFlow()` authenticates for Firestore access
- **Firestore** — market event data, approval records, payment records
- **Gemini AI** — `askGemeni()` generates market questions from trending events
- **Multi-chain EVM** — reads/writes across Arbitrum Sepolia and Base Sepolia
- **CRE Secrets** — API keys managed via `secrets.yaml`, never in code

All within the same workflow runtime, using the same config model, with the same trust guarantees.

---

## The Numbers

| Metric | Traditional | GeoChain + CRE |
|---|---|---|
| Backend services | 5–6 | 1 workflow |
| Config files | Scattered env vars | 1 JSON per environment |
| Failure modes | Each service independent | One runtime, all-or-nothing |
| Replay protection | Ad-hoc per service | Built into every handler |
| Cross-chain sync | Separate relay scripts | Same workflow handler |
| Policy enforcement | Application code | CRE handler + on-chain contract |
| User wallet signatures per trade | 2–3 | 0 (sponsored) |
| Time to add new chain | Days (new services) | Add entry to config JSON |

---

## Technical Reference

| CRE Capability Used | Where | Purpose |
|---|---|---|
| `CronCapability` | `main.ts` | Schedule market lifecycle automation |
| `HTTPCapability` | `main.ts` | Sponsor policy, execution, fiat credit, session revocation |
| `EVMClient.logTrigger` | `main.ts` | React to router ETH deposit events |
| `EVMClient.callContract` | All cron handlers | Read on-chain state (balances, prices, market lists) |
| `EVMClient.writeReport` | All handlers | Submit consensus-signed reports to contracts |
| `runtime.report()` | All handlers | Request BFT consensus on report payload |
| `runtime.config` | All handlers | Access unified config model |
| `runtime.log()` | All handlers | Unified logging across DON |
| `getNetwork()` | All handlers | Resolve chain selector for multi-chain operations |
| `prepareReportRequest()` | All handlers | Encode report data for consensus |

**CRE SDK imports used:** `CronCapability`, `EVMClient`, `HTTPCapability`, `Runner`, `handler`, `getNetwork`, `encodeCallMsg`, `bytesToHex`, `prepareReportRequest`, `TxStatus`

---

## Final Statement for Judges

The Chainlink Convergence 2026 hackathon asked teams to build real-world applications using CRE. We didn't use CRE for a demo. We used it to solve the **operational complexity** that prevents prediction markets from running reliably in production.

Our workflow handles:
- **13 distinct handlers** across 3 trigger types (cron, HTTP, EVM log)
- **2 EVM chains** with hub-spoke coordination
- **3 funding sources** with replay protection on each
- **Policy-enforced sponsored execution** with approve→consume semantics
- **AI-assisted market creation** integrated into the same workflow
- **Continuous market health automation** (price sync, arbitrage, liquidity, resolution, withdrawals)

Other teams build contracts. We built a **self-operating prediction market protocol** — and CRE is what makes that possible.
