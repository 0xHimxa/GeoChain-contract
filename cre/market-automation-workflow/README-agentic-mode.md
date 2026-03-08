# Agentic Trading Mode (Router + CRE) - Full Explanation

This document explains the agentic trading feature that was added across:

- Solidity router contracts
- CRE workflow HTTP handlers
- Workflow config

It is written to be explicit and practical, without assuming prior context.

For a step-by-step implementation guide from contract setup to HTTP calls, read:

- `README-agentic-setup.md`

## 1. Problem This Solves

You want users to allow an AI/automation agent to trade for them.

The main security requirement is:

- The agent can execute actions **for a specific user**
- But only if that user explicitly delegated permission
- And only inside limits (expiry, allowed actions, max amount per action)

## 2. Core Design Choice

Important design decision:

- Funds are **not moved** to an agent wallet.
- The router still holds custody and keeps user balances in router accounting.
- The agent is an executor with scoped permission.

So:

- custody stays with protocol/router
- permission is per user -> per agent
- execution is blocked on-chain if permission is missing/expired/out-of-scope

## 3. What Changed On-Chain (Router)

Files:

- `contract/src/router/PredictionMarketRouterVaultBase.sol`
- `contract/src/router/PredictionMarketRouterVaultOperations.sol`

### 3.1 New Agent Permission Storage

Added:

- `struct AgentPermission { enabled, expiresAt, maxAmountPerAction, actionMask }`
- `mapping(address => mapping(address => AgentPermission)) public agentPermissions;`

Meaning:

- key = `agentPermissions[user][agent]`
- each user controls which agent can act for them

### 3.2 New Router Errors

Added explicit revert reasons:

- `Router__AgentNotAuthorized`
- `Router__AgentPermissionExpired`
- `Router__AgentActionNotAllowed`
- `Router__AgentAmountExceeded`

### 3.3 New Router Events

Added:

- `AgentPermissionUpdated(...)`
- `AgentPermissionRevoked(...)`
- `AgentActionExecuted(...)`

These make permission changes and execution auditable on-chain.

### 3.4 User-Controlled Delegation Functions

Added:

- `setAgentPermission(address agent, uint32 actionMask, uint128 maxAmountPerAction, uint64 expiresAt)`
- `revokeAgentPermission(address agent)`

Only the user (caller) can set/revoke their own agent delegation.

### 3.5 New Delegated Entry Functions

Added direct external delegated functions:

- `mintCompleteSetsFor(...)`
- `redeemCompleteSetsFor(...)`
- `swapYesForNoFor(...)`
- `swapNoForYesFor(...)`
- `addLiquidityFor(...)`
- `removeLiquidityFor(...)`
- `redeemFor(...)`
- `disputeProposedResolutionFor(...)`

Each calls `_authorizeAgent(...)` before doing the action.

### 3.6 New Agent Report Action Types (CRE path)

Added hashed action names for report processing:

- `routerAgentMintCompleteSets`
- `routerAgentRedeemCompleteSets`
- `routerAgentSwapYesForNo`
- `routerAgentSwapNoForYes`
- `routerAgentAddLiquidity`
- `routerAgentRemoveLiquidity`
- `routerAgentRedeem`
- `routerAgentDisputeProposedResolution`

`_processReport(...)` now decodes these payloads and enforces `_authorizeAgent(...)`.

### 3.7 How `_authorizeAgent(...)` Protects Users

Checks:

1. Permission exists and is enabled
2. Permission not expired
3. Action bit is allowed in `actionMask`
4. Bound amount does not exceed `maxAmountPerAction`

If any check fails, tx/report execution reverts on-chain.

## 4. What Changed Off-Chain (CRE Handlers)

New files:

- `cre/market-workflow/handlers/httpHandlers/httpAgentPlanTrade.ts`
- `cre/market-workflow/handlers/httpHandlers/httpAgentSponsorTrade.ts`
- `cre/market-workflow/handlers/httpHandlers/httpAgentExecuteTrade.ts`
- `cre/market-workflow/handlers/httpHandlers/httpAgentRevoke.ts`
- `cre/market-workflow/handlers/utils/agentAction.ts`

### 4.1 `agentAction.ts` (shared mapping + payload encoding)

Contains:

- `AgentAction` union type
- map from action -> router agent `actionType`
- `buildAgentPayloadHex(...)` encoder for each action ABI shape

Purpose:

- one canonical place for agent payload format
- reduces encoding mismatches

### 4.2 `httpAgentPlanTrade.ts`

Purpose:

- Normalize/validate agent trade intent before sponsor/execute.

Checks include:

- `agentPolicy.enabled`
- action in allowed list
- chain supported
- address formats valid
- `sender == user`
- amount/slippage inside policy

Output:

- deterministic plan object containing final `actionType` and fields needed later

### 4.3 `httpAgentSponsorTrade.ts`

Purpose:

- Reuse your existing sponsor policy logic instead of creating a second security path.

Behavior:

- converts agent request to regular sponsor shape
- calls existing `sponsorUserOpPolicyHandler(...)`

Security benefit:

- keeps session signature validation, nonce replay control, and approval creation in one place

### 4.4 `httpAgentExecuteTrade.ts`

Purpose:

- Build `payloadHex` for agent action and route to existing execute pipeline.

Behavior:

- maps action -> `routerAgent...` actionType
- encodes payload via `buildAgentPayloadHex(...)`
- calls existing `executeReportHttpHandler(...)`

Security benefit:

- still uses approval consumption + one-time execute checks
- plus on-chain `_authorizeAgent(...)`

### 4.5 `httpAgentRevoke.ts`

Purpose:

- agent-facing revoke endpoint that forwards to existing session revoke logic.

Behavior:

- checks `agentPolicy.enabled`
- calls `revokeSessionHttpHandler(...)`

## 5. Existing Handler Changes

### 5.1 Sponsor policy now accepts agent action types

File:

- `cre/market-workflow/handlers/httpHandlers/httpSponsorPolicy.ts`

What changed:

- actionType matching now accepts either:
  - normal router action type, or
  - corresponding `routerAgent...` type

### 5.2 Execute zero-amount exception for agent dispute

File:

- `cre/market-workflow/handlers/httpHandlers/httpExecuteReport.ts`

What changed:

- added `routerAgentDisputeProposedResolution` to zero-amount allowed list

## 6. Workflow Wiring

File:

- `cre/market-workflow/main.ts`

Added imports + HTTP trigger registrations for:

- `agentPlanTradeHttpHandler`
- `agentSponsorTradeHttpHandler`
- `agentExecuteTradeHttpHandler`
- `agentRevokeHttpHandler`

And added:

- `httpAgentAuthorizedKeys` (defaults to `httpTriggerAuthorizedKeys` if missing)

## 7. Config Changes

File:

- `cre/market-workflow/Constant-variable/config.ts`

Added types:

- `AgentPolicyConfig`
- `httpAgentAuthorizedKeys?: AuthorizedKeyConfig[]`
- `agentPolicy?: AgentPolicyConfig`

Config JSON updates:

- `config.staging.json`
- `config.production.json`

Added:

- new `routerAgent...` entries in `executePolicy.allowedActionTypes`
- new `agentPolicy` block
- `httpAgentAuthorizedKeys` in staging

## 8. Execution Flow End-to-End

1. User opts in on-chain:
   - calls `setAgentPermission(...)` on router
2. Backend/CRE receives agent request:
   - `httpAgentPlanTrade` validates and normalizes
3. Sponsor step:
   - `httpAgentSponsorTrade` -> existing sponsor policy
   - session signatures + nonce + policy checks run
   - approval record created
4. Execute step:
   - `httpAgentExecuteTrade` builds agent payload and calls existing execute handler
   - execute handler consumes approval (one-time)
   - report sent to router
5. Router final check:
   - `_processReport` decodes `routerAgent...` action
   - `_authorizeAgent` enforces user->agent delegation constraints
   - action executes or reverts

## 9. Who Is The Agent In This Model?

Current model:

- the configured backend/CRE agent key executes transactions
- users grant that key permission via `setAgentPermission`

Alternative:

- allow each user to set their own bot key as `agent`
- architecture supports this already

## 10. Security Layers (Defense in Depth)

Layer 1: HTTP authorized keys (CRE trigger gate)  
Layer 2: sponsor policy + session signatures  
Layer 3: Firestore one-time approval and nonce replay protection  
Layer 4: execute policy action allowlist  
Layer 5: on-chain router `_authorizeAgent(...)` checks  
Layer 6: existing router market/risk balance checks

Even if off-chain path is misused, on-chain delegated checks still block unauthorized agent actions.

## 11. Important Operational Notes

1. You must set `agentPolicy.enabled=true` and include allowed actions/chains.
2. You must include `routerAgent...` action types in `executePolicy.allowedActionTypes`.
3. User must call `setAgentPermission(...)` before agent execution can succeed.
4. `expiresAt` should be short and renewable, not indefinite.
5. `maxAmountPerAction` should be conservative.

## 12. Example High-Level API Sequence

1. `POST /agent/plan` -> `httpAgentPlanTrade`
2. `POST /agent/sponsor` -> `httpAgentSponsorTrade`
3. `POST /agent/execute` -> `httpAgentExecuteTrade`
4. `POST /agent/revoke` -> `httpAgentRevoke`

You can map these four to separate CRE HTTP triggers/routes in your API gateway.

## 14. Manual-Only Operation

Current recommended mode is manual/on-demand execution only:

- use HTTP handlers (`plan`, `sponsor`, `execute`, `geminiAutoTrade`, `revoke`)
- do not run autonomous cron trading

This keeps risk lower while strategy and monitoring mature.

## 13. What This Does NOT Do Yet

1. It does not force market allowlists per agent (only per router market policy).
2. It does not add cumulative daily spend caps on-chain (currently per-action max).
3. It does not auto-rotate agent keys.

These can be added as next hardening steps.
