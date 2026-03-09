<p align="center">
  <h1 align="center">🤖 Agents Workflow — AI Trading Engine</h1>
  <p align="center">
    <strong>Dedicated CRE workflow for AI agent-delegated prediction market trading</strong>
  </p>
  <p align="center">
    <a href="#overview">Overview</a> ·
    <a href="#architecture">Architecture</a> ·
    <a href="#handler-reference">Handlers</a> ·
    <a href="#security-model">Security</a> ·
    <a href="#configuration">Configuration</a> ·
    <a href="#getting-started">Getting Started</a>
  </p>
</p>

---

## Overview

The **agents-workflow** is a standalone CRE workflow purpose-built for AI agent trading on GeoChain prediction markets. It is **architecturally separate** from the [market-automation-workflow](../market-automation-workflow/README.md) to isolate agent trading from operational market automation.

### Why a Separate Workflow?

| Concern | Benefit |
|---|---|
| **Independent key sets** | Agent HTTP keys can't trigger market resolution and vice versa |
| **Isolated failure domains** | Agent misconfiguration can't break market creation or resolution |
| **Independent deploy cycles** | Upgrade agent trading without touching operational automation |
| **Separate policy enforcement** | `agentPolicy` governs trading limits independently of `sponsorPolicy` |

### Handlers

| Handler | Trigger | Purpose |
|---|---|---|
| `agentPlanTrade` | HTTP | Validate intent, normalize parameters, produce a trade plan |
| `agentSponsorTrade` | HTTP | Convert plan to sponsor format, create Firestore approval |
| `agentExecuteTrade` | HTTP | Consume approval, ABI-encode payload, submit on-chain |
| `agentRevoke` | HTTP | Terminate agent session |
| `agentGeminiAutoTrade` | HTTP | AI-driven trading — Gemini decides action + amount autonomously |

---

## Architecture

```
                  ┌──────────────────────────────┐
                  │          main.ts              │
                  │   (Agent Workflow Graph)       │
                  └───────────┬──────────────────┘
                              │
               ┌──────────────┼──────────────────────┐
               │              │                      │
    ┌──────────▼───────┐ ┌───▼────────────┐ ┌──────▼────────────┐
    │  Plan + Sponsor   │ │    Execute     │ │  Revoke + Gemini  │
    │  (validation &    │ │  (on-chain     │ │  (session mgmt    │
    │   approval)       │ │   submission)  │ │   + AI trading)   │
    └──────────┬───────┘ └───┬────────────┘ └──────┬────────────┘
               │              │                      │
    ┌──────────▼──────────────▼──────────────────────▼────────────┐
    │                   Shared Infrastructure                      │
    ├────────────────┬───────────────┬────────────────────────────┤
    │   firebase/    │    utils/     │  market-automation-workflow │
    │  Session mgmt  │ Validation   │  sponsor + execute handlers │
    └────────────────┴───────────────┴────────────────────────────┘
```

### Trade Flow

The complete agent trade lifecycle follows a strict 4-step pipeline:

```
┌─────────┐     ┌──────────┐     ┌──────────┐     ┌──────────┐
│  Plan   │────▶│  Sponsor │────▶│ Execute  │     │  Revoke  │
│ validate│     │ approve  │     │ on-chain │     │ terminate│
│ + norm  │     │ + store  │     │ + submit │     │ session  │
└─────────┘     └──────────┘     └──────────┘     └──────────┘
     │                │                │
     ▼                ▼                ▼
  Policy           Firestore       CRE Report
  checks           approval        → writeReport
                   record          → on-chain tx
```

For **Gemini Auto Trade**, steps 1–3 are orchestrated automatically:

```
┌──────────────────┐     ┌─────────┐     ┌──────────┐     ┌──────────┐
│ Gemini AI Decides│────▶│  Plan   │────▶│  Sponsor │────▶│ Execute  │
│  action + amount │     │(internal│     │(internal │     │(internal │
│  via Search API  │     │  call)  │     │  call)   │     │  call)   │
└──────────────────┘     └─────────┘     └──────────┘     └──────────┘
```

### Directory Structure

```
agents-workflow/
├── main.ts                          # Workflow entry point — 4-5 HTTP triggers
├── config.staging.json              # Staging config (addresses, policies, keys)
├── config.production.json           # Production config
├── workflow.yaml                    # CRE CLI target definitions
├── Constant-variable/
│   └── config.ts                    # TypeScript config types
├── handlers/
│   ├── httpHandlers/
│   │   ├── httpAgentPlanTrade.ts     # Intent validation & normalized plan output
│   │   ├── httpAgentSponsorTrade.ts  # Plan → sponsor approval creation
│   │   ├── httpAgentExecuteTrade.ts  # Approval consumption & on-chain submission
│   │   ├── httpAgentRevoke.ts        # Session termination
│   │   ├── httpAgentGeminiAutoTrade.ts  # AI-driven autonomous trading
│   │   ├── httpSponsorPolicy.ts     # (Reused from market-automation-workflow)
│   │   ├── httpExecuteReport.ts     # (Reused from market-automation-workflow)
│   │   └── httpRevokeSession.ts     # (Reused from market-automation-workflow)
│   └── utils/
│       ├── sessionValidation.ts     # EIP-712 session signature verification
│       ├── agentAction.ts           # Agent action → router action type mapping
│       └── payloadBuilder.ts        # Agent-specific ABI payload encoding
├── firebase/
│   ├── sessionStore.ts              # Approval record CRUD
│   └── signUp.ts                    # Firebase anonymous auth
├── payload/                         # JSON payloads for CRE simulation
│   ├── plan.json
│   ├── sponsor.json
│   ├── execute.json
│   └── revoke.json
└── main.test.ts                     # Unit tests
```

---

## Handler Reference

### `agentPlanTradeHttpHandler` — Trade Intent Validation

**File:** `handlers/httpHandlers/httpAgentPlanTrade.ts`

Produces a normalized, policy-aligned trade plan from an agent's raw trading intent. This handler is **deterministic** and rejects missing or ambiguous fields.

**Validation checks:**
- Agent policy is enabled
- Action is in `agentPolicy.allowedActions`
- Chain ID is in `agentPolicy.supportedChainIds`
- All addresses (`sender`, `user`, `agent`, `market`) are valid 0x40 hex format
- `sender` must equal `user` (self-trade enforcement)
- Amount is within `agentPolicy.maxAmountUsdc` (zero allowed only for `disputeProposedResolution`)
- Slippage is within `agentPolicy.maxSlippageBps` (defaults to `defaultSlippageBps` if unset)

**Input:**
```json
{
  "requestId": "agent_plan_001",
  "chainId": 421614,
  "sender": "0x...",
  "user": "0x...",
  "agent": "0x...",
  "market": "0x...",
  "action": "swapYesForNo",
  "amountUsdc": "1000000",
  "slippageBps": 100,
  "yesIn": "1000000",
  "minNoOut": "950000",
  "session": { ... }
}
```

**Output:**
```json
{
  "planned": true,
  "requestId": "agent_plan_001",
  "plan": {
    "action": "swapYesForNo",
    "actionType": "routerAgentSwapYesForNo",
    "chainId": 421614,
    "sender": "0x...",
    "user": "0x...",
    "agent": "0x...",
    "market": "0x...",
    "amountUsdc": "1000000",
    "slippageBps": 100,
    "yesIn": "1000000",
    "minNoOut": "950000"
  }
}
```

**Supported actions:**

| Action | Router Action Type | Description |
|---|---|---|
| `swapYesForNo` | `routerAgentSwapYesForNo` | Sell YES tokens for NO tokens |
| `swapNoForYes` | `routerAgentSwapNoForYes` | Sell NO tokens for YES tokens |
| `mintCompleteSets` | `routerAgentMintCompleteSets` | Mint YES+NO token pairs from collateral |
| `redeemCompleteSets` | `routerAgentRedeemCompleteSets` | Burn YES+NO pairs for collateral |
| `redeem` | `routerAgentRedeem` | Redeem winning tokens post-resolution |
| `addLiquidity` | `routerAgentAddLiquidity` | Provide liquidity to the AMM |
| `removeLiquidity` | `routerAgentRemoveLiquidity` | Remove liquidity from the AMM |
| `disputeProposedResolution` | `routerAgentDisputeProposedResolution` | Dispute a proposed market resolution |

---

### `agentSponsorTradeHttpHandler` — Authorization Bridge

**File:** `handlers/httpHandlers/httpAgentSponsorTrade.ts`

Converts the agent plan into the standard sponsor request format and routes it through `sponsorUserOpPolicyHandler` — **reusing the same security pipeline** used by human-initiated trades. This eliminates a second, potentially divergent, authorization path.

**Flow:**
1. Receives the plan output from `agentPlanTrade`
2. Maps agent action to `routerAgent*` action type
3. Delegates to `sponsorUserOpPolicyHandler` for full policy validation
4. Returns the sponsor decision (including `approvalId` on success)

---

### `agentExecuteTradeHttpHandler` — On-Chain Execution

**File:** `handlers/httpHandlers/httpAgentExecuteTrade.ts`

Consumes the sponsor approval and submits the final on-chain transaction. Internally delegates to `executeReportHttpHandler`.

**Flow:**
1. Receives execute request with `approvalId` and `payloadHex`
2. Maps agent action to its `routerAgent*` action type
3. ABI-encodes the trade payload via `buildAgentPayloadHex`
4. Delegates to `executeReportHttpHandler` which:
   - Consumes the one-time Firestore approval
   - Submits the CRE report via `writeReport`

---

### `agentRevokeHttpHandler` — Session Termination

**File:** `handlers/httpHandlers/httpAgentRevoke.ts`

Terminates an agent session by delegating to the canonical `revokeSessionHttpHandler`. Using the same revocation path prevents policy drift between agent and non-agent revocation.

---

### `agentGeminiAutoTradeHttpHandler` — AI-Driven Trading

**File:** `handlers/httpHandlers/httpAgentGeminiAutoTrade.ts`

End-to-end autonomous trading handler that asks **Google Gemini AI** to make a trading decision and then executes it through the secured pipeline.

**Flow:**
1. Receives market context (question, YES/NO prices, note, allowed actions)
2. Constructs a structured prompt with the system instruction:
   > *"You are a risk-constrained trading assistant for prediction markets."*
3. Sends prompt to Gemini via CRE `HTTPClient` + consensus aggregation
4. Parses Gemini's JSON response: `{ action, amountUsdc, rationale, confidenceBps }`
5. If action is `"hold"`, returns without trading
6. Otherwise, orchestrates the full Plan → Sponsor → Execute pipeline internally

**Gemini response format:**
```json
{
  "action": "swapYesForNo",
  "amountUsdc": "500000",
  "rationale": "Market consensus undervalues YES based on search evidence",
  "confidenceBps": 7500
}
```

**Safety constraints:**
- Action must be in `ALLOWED_ACTIONS` set
- Amount must be within `agentPolicy.maxAmountUsdc`
- Only auto-executable actions are processed (`mintCompleteSets`, `redeemCompleteSets`, `redeem`, `swapYesForNo`, `swapNoForYes`)
- Gemini can return `"hold"` with `amountUsdc: "0"` to skip trading

---

## Security Model

Agent trading uses a **6-layer defense-in-depth** security model:

```
┌─────────────────────────────────────────────────────────────┐
│ Layer 1: HTTP Authorized Keys — CRE trigger gate            │
├─────────────────────────────────────────────────────────────┤
│ Layer 2: Agent Policy — action/amount/slippage/chain limits │
├─────────────────────────────────────────────────────────────┤
│ Layer 3: Sponsor Policy + EIP-712 Session Signatures        │
├─────────────────────────────────────────────────────────────┤
│ Layer 4: Firestore One-Time Approval + Nonce Replay Guard   │
├─────────────────────────────────────────────────────────────┤
│ Layer 5: Execute Policy Action Allowlist                    │
├─────────────────────────────────────────────────────────────┤
│ Layer 6: On-Chain _authorizeAgent() — permission, expiry,   │
│          action mask, per-action amount cap                  │
└─────────────────────────────────────────────────────────────┘
```

**Key principle:** Funds never leave the router contract. The agent is an executor with scoped, time-limited permissions — not a custodian.

---

## Configuration

### `config.staging.json` Reference

| Key | Type | Description |
|---|---|---|
| `httpTriggerAuthorizedKeys` | `AuthKey[]` | Fallback keys for agent endpoints |
| `httpAgentAuthorizedKeys` | `AuthKey[]` | Dedicated ECDSA keys for agent HTTP endpoints |
| `agentPolicy` | `object` | Agent-specific trading policy |
| `agentPolicy.allowedActions` | `string[]` | Actions agents can perform |
| `agentPolicy.maxAmountUsdc` | `string` | Maximum trade amount (USDC, 6 decimals) |
| `agentPolicy.maxSlippageBps` | `number` | Maximum allowed slippage in basis points |
| `agentPolicy.defaultSlippageBps` | `number` | Default slippage when not specified |
| `agentPolicy.supportedChainIds` | `number[]` | Chain IDs agents can trade on |
| `sponsorPolicy` | `object` | Shared sponsor policy (reused from market-automation-workflow) |
| `executePolicy` | `object` | Shared execute policy allowlist |
| `evms[]` | `EvmConfig[]` | Per-chain contract addresses and config |

### Required Secrets

Same as market-automation-workflow:

| Secret | Description |
|---|---|
| `AI_KEY` | Google Gemini API key (required for `agentGeminiAutoTrade`) |
| `FIREBASE_API_KEY` | Firebase Web API key |
| `FIREBASE_PROJECT_ID` | Firebase project ID |

---

## Getting Started

### Prerequisites

- [Bun](https://bun.sh) ≥ 1.0
- [Chainlink CRE CLI](https://docs.chain.link/cre)
- Deployed smart contracts with agent permissions configured
- `market-automation-workflow` deployed (agents-workflow reuses shared policies)

### Install

```bash
cd cre/agents-workflow
bun install
```

### Configure

1. Edit `config.staging.json`:
   - Set `httpAgentAuthorizedKeys` with your agent ECDSA public keys
   - Update `evms[]` with your deployed contract addresses
   - Configure `agentPolicy` limits as needed

2. Register secrets:
```bash
cre secrets set AI_KEY <your-gemini-api-key>
cre secrets set FIREBASE_API_KEY <your-firebase-api-key>
cre secrets set FIREBASE_PROJECT_ID <your-firebase-project-id>
```

### Simulate

```bash
# Simulate plan handler (trigger index 0)
cre workflow simulate ./ \
  --target staging-settings \
  --non-interactive \
  --trigger-index 0 \
  --http-payload "$(cat payload/plan.json)" \
  --broadcast

# Simulate sponsor handler (trigger index 1)
cre workflow simulate ./ \
  --target staging-settings \
  --non-interactive \
  --trigger-index 1 \
  --http-payload "$(cat payload/sponsor.json)" \
  --broadcast

# Simulate execute handler (trigger index 2)
cre workflow simulate ./ \
  --target staging-settings \
  --non-interactive \
  --trigger-index 2 \
  --http-payload "$(cat payload/execute.json)" \
  --broadcast
```

### Deploy

```bash
cre workflow deploy --target staging-settings
```

### Trigger Index Map

| Index | Handler | Purpose |
|---|---|---|
| 0 | `agentPlanTradeHttpHandler` | Trade intent validation |
| 1 | `agentSponsorTradeHttpHandler` | Authorization & approval creation |
| 2 | `agentExecuteTradeHttpHandler` | On-chain trade execution |
| 3 | `agentRevokeHttpHandler` | Session termination |

---

## Testing

Run unit tests:

```bash
bun test
```

---

## Related Documentation

- [Market Automation Workflow README](../market-automation-workflow/README.md) — Core automation CRE workflow
- [Project README](../../README.md) — Full project documentation
