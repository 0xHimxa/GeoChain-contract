

This guide shows the full setup path:

1. Prepare router contract state
2. Prepare CRE config and secrets
3. Build session signatures
4. Call HTTP handlers in correct order
5. Understand failure reasons

This is for **manual/on-demand mode** (no autonomous cron trading).

## 1. Prerequisites

You need:

1. A deployed router (`PredictionMarketRouterVault`)
2. A user EOA with collateral deposited into router credits
3. A backend/agent address (the `agent` address users authorize)
4. CRE workflow deployed/running with HTTP triggers enabled
5. Firestore secrets configured for session/approval storage
6. `AI_KEY` secret if you use Gemini endpoint

## 2. Router Setup (On-Chain)

File references:

- [PredictionMarketRouterVaultBase.sol](/home/himxa/Desktop/market/contracts/contract/src/router/PredictionMarketRouterVaultBase.sol)
- [PredictionMarketRouterVaultOperations.sol](/home/himxa/Desktop/market/contracts/contract/src/router/PredictionMarketRouterVaultOperations.sol)

### 2.1 Ensure market is allowlisted

Router owner or market factory must call:

- `setMarketAllowed(market, true)`

If this is not set, agent trades revert with `Router__MarketNotAllowed`.

### 2.2 Ensure user has router collateral credits

User calls:

- `depositCollateral(amount)` or `depositFor(user, amount)`

If user has no credits, trade execution reverts with `Router__InsufficientBalance`.

### 2.3 User authorizes agent

User calls:

- `setAgentPermission(agent, actionMask, maxAmountPerAction, expiresAt)`

Action mask bits:

1. `1 << 0` mintCompleteSets
2. `1 << 1` redeemCompleteSets
3. `1 << 2` swapYesForNo
4. `1 << 3` swapNoForYes
5. `1 << 4` addLiquidity
6. `1 << 5` removeLiquidity
7. `1 << 6` redeem
8. `1 << 7` disputeProposedResolution

Example:

- allow `mintCompleteSets` + `swapYesForNo`
- `actionMask = (1 << 0) | (1 << 2) = 5`

If missing/expired/too large/out-of-scope:

- `Router__AgentNotAuthorized`
- `Router__AgentPermissionExpired`
- `Router__AgentActionNotAllowed`
- `Router__AgentAmountExceeded`

### 2.4 Revocation

User can instantly stop agent:

- `revokeAgentPermission(agent)`

## 3. CRE Config Setup

Files:

- [config.staging.json](/home/himxa/Desktop/market/contracts/cre/market-workflow/config.staging.json)
- [config.production.json](/home/himxa/Desktop/market/contracts/cre/market-workflow/config.production.json)
- [config.ts](/home/himxa/Desktop/market/contracts/cre/market-workflow/Constant-variable/config.ts)

Required fields:

1. `agentPolicy.enabled = true`
2. `agentPolicy.supportedChainIds` includes your chain (`421614` or `84532`)
3. `agentPolicy.allowedActions` includes requested action
4. `executePolicy.enabled = true`
5. `executePolicy.allowedActionTypes` includes `routerAgent...` action types
6. `sponsorPolicy.enabled = true`
7. `sponsorPolicy.allowedActions` includes requested action
8. `sponsorPolicy.supportedChainIds` includes your chain
9. `evms[].routerReceiverAddress` is set and correct
10. `httpAgentAuthorizedKeys` configured

## 4. Session Authorization Setup (When Required)

If `sponsorPolicy.requireSessionAuthorization = true`, each sponsor request needs:

- `session` object with valid signatures

Relevant code:

- [sessionMessage.ts](/home/himxa/Desktop/market/contracts/cre/market-workflow/handlers/utils/sessionMessage.ts)
- [sessionValidation.ts](/home/himxa/Desktop/market/contracts/cre/market-workflow/handlers/utils/sessionValidation.ts)

### 4.1 Required session fields

1. `sessionId` (12-100 chars, `[a-zA-Z0-9_-]`)
2. `owner` (user wallet address)
3. `sessionPublicKey` (uncompressed secp256k1, `0x04...`, 65 bytes)
4. `chainId`
5. `allowedActions`
6. `maxAmountUsdc`
7. `expiresAtUnix`
8. `grantSignature` (signed by `owner`)
9. `requestNonce` (unique per request)
10. `requestSignature` (signed by session key)

### 4.2 EIP-712 domain

Domain:

- `name = "CRE Session Authorization"`
- `version = "1"`
- `chainId = request chainId`

### 4.3 Signature generation snippet (TypeScript + viem)

```ts
import { createWalletClient, http, keccak256, stringToHex } from "viem";
import { privateKeyToAccount } from "viem/accounts";

const owner = privateKeyToAccount(process.env.OWNER_PK as `0x${string}`);
const session = privateKeyToAccount(process.env.SESSION_PK as `0x${string}`);

const chainId = 84532;
const allowedActions = ["swapYesForNo", "mintCompleteSets"].sort();
const allowedActionsHash = keccak256(stringToHex(allowedActions.join(",")));

const domain = { name: "CRE Session Authorization", version: "1", chainId };
const sessionId = "sess_user123_001";
const maxAmountUsdc = 100_000_000n; // 100 USDC (6 decimals)
const expiresAtUnix = BigInt(Math.floor(Date.now() / 1000) + 3600);

const grantTypes = {
  SessionGrant: [
    { name: "sessionId", type: "string" },
    { name: "owner", type: "address" },
    { name: "sessionPublicKey", type: "bytes" },
    { name: "chainId", type: "uint256" },
    { name: "allowedActionsHash", type: "bytes32" },
    { name: "maxAmountUsdc", type: "uint256" },
    { name: "expiresAtUnix", type: "uint256" },
  ],
} as const;

const grantMessage = {
  sessionId,
  owner: owner.address,
  sessionPublicKey: session.publicKey as `0x${string}`, // must be uncompressed 0x04...
  chainId: BigInt(chainId),
  allowedActionsHash,
  maxAmountUsdc,
  expiresAtUnix,
};

const grantSignature = await owner.signTypedData({
  domain,
  types: grantTypes,
  primaryType: "SessionGrant",
  message: grantMessage,
});

const requestId = "req_123";
const requestNonce = "nonce_12345678"; // must be unique
const intentTypes = {
  SponsorIntent: [
    { name: "requestId", type: "string" },
    { name: "sessionId", type: "string" },
    { name: "requestNonce", type: "string" },
    { name: "chainId", type: "uint256" },
    { name: "action", type: "string" },
    { name: "amountUsdc", type: "uint256" },
    { name: "slippageBps", type: "uint256" },
    { name: "sender", type: "address" },
  ],
} as const;

const action = "swapYesForNo";
const amountUsdc = 25_000_000n;
const slippageBps = 100n;

const requestSignature = await session.signTypedData({
  domain,
  types: intentTypes,
  primaryType: "SponsorIntent",
  message: {
    requestId,
    sessionId,
    requestNonce,
    chainId: BigInt(chainId),
    action,
    amountUsdc,
    slippageBps,
    sender: owner.address,
  },
});
```

## 5. HTTP Handlers and Call Order

Files:

- [httpAgentPlanTrade.ts](/home/himxa/Desktop/market/contracts/cre/market-workflow/handlers/httpHandlers/httpAgentPlanTrade.ts)
- [httpAgentSponsorTrade.ts](/home/himxa/Desktop/market/contracts/cre/market-workflow/handlers/httpHandlers/httpAgentSponsorTrade.ts)
- [httpAgentExecuteTrade.ts](/home/himxa/Desktop/market/contracts/cre/market-workflow/handlers/httpHandlers/httpAgentExecuteTrade.ts)
- [httpAgentGeminiAutoTrade.ts](/home/himxa/Desktop/market/contracts/cre/market-workflow/handlers/httpHandlers/httpAgentGeminiAutoTrade.ts)
- [httpAgentRevoke.ts](/home/himxa/Desktop/market/contracts/cre/market-workflow/handlers/httpHandlers/httpAgentRevoke.ts)

You have two modes:

1. Non-Gemini (your own AI/bot logic):
   - `plan -> sponsor -> execute`
2. Gemini one-shot:
   - `geminiAutoTrade` (internally does plan+sponsor+execute)

### 5.1 Plan request example

```json
{
  "requestId": "req_123",
  "chainId": 84532,
  "sender": "0xUSER...",
  "user": "0xUSER...",
  "agent": "0xAGENT...",
  "market": "0xMARKET...",
  "action": "swapYesForNo",
  "amountUsdc": "25000000",
  "slippageBps": 100,
  "session": {
    "sessionId": "sess_user123_001",
    "owner": "0xUSER...",
    "sessionPublicKey": "0x04....",
    "chainId": 84532,
    "allowedActions": ["swapYesForNo", "mintCompleteSets"],
    "maxAmountUsdc": "100000000",
    "expiresAtUnix": "1735689600",
    "grantSignature": "0x....",
    "requestNonce": "nonce_12345678",
    "requestSignature": "0x...."
  }
}
```

Expected success includes:

- `planned: true`
- `plan.actionType = "routerAgentSwapYesForNo"` (example)

### 5.2 Sponsor request example

Use fields from `plan.plan`:

```json
{
  "requestId": "req_123",
  "chainId": 84532,
  "sender": "0xUSER...",
  "action": "swapYesForNo",
  "amountUsdc": "25000000",
  "slippageBps": 100,
  "session": { "...": "same session object" }
}
```

Expected success:

- `approved: true`
- `approvalId: "cre_approval_..."`

### 5.3 Execute request example

```json
{
  "requestId": "req_123",
  "approvalId": "cre_approval_...",
  "chainId": 84532,
  "action": "swapYesForNo",
  "user": "0xUSER...",
  "agent": "0xAGENT...",
  "market": "0xMARKET...",
  "amountUsdc": "25000000",
  "yesIn": "25000000",
  "minNoOut": "24000000"
}
```

Expected success:

- `submitted: true`
- `txHash`, `explorerUrl`

### 5.4 Gemini one-shot request example

```json
{
  "requestId": "req_456",
  "chainId": 84532,
  "sender": "0xUSER...",
  "user": "0xUSER...",
  "agent": "0xAGENT...",
  "market": "0xMARKET...",
  "amountUsdc": "50000000",
  "slippageBps": 100,
  "allowedActions": ["swapYesForNo", "swapNoForYes", "mintCompleteSets"],
  "marketContext": {
    "question": "Will event happen?",
    "yesPriceBps": 6200,
    "noPriceBps": 3800,
    "note": "prefer low risk"
  },
  "session": { "...": "same session object fields" }
}
```

### 5.5 Revoke session example

Call `agentRevoke` with the same payload shape used by session revoke handler:

```json
{
  "requestId": "revoke_1",
  "sessionId": "sess_user123_001",
  "owner": "0xUSER...",
  "chainId": 84532,
  "revokeSignature": "0x..."
}
```

After revoke:

- sponsor requests with that session will fail.

## 6. How Your Own AI Agent Replaces Gemini

If you do not want Gemini:

1. Your AI picks action/amount/limits off-chain
2. Call `agentPlanTrade` with chosen values
3. Call `agentSponsorTrade`
4. Call `agentExecuteTrade`

You can skip `httpAgentGeminiAutoTrade` entirely.

## 7. Critical Checks Before First Live Call

1. User has called `setAgentPermission(...)`
2. Permission `actionMask` includes your action
3. `maxAmountPerAction` >= requested amount
4. Permission `expiresAt` in future
5. Router market is allowlisted
6. User has sufficient router credits/tokens
7. Session signatures are valid and nonce unused
8. Action type exists in `executePolicy.allowedActionTypes`

## 8. Common Failures and Meaning

1. `action not allowed by agent policy`
   - `agentPolicy.allowedActions` missing action
2. `session nonce already used`
   - reuse of `requestNonce`
3. `actionType not allowed by execute policy`
   - missing `routerAgent...` action in config
4. `approval already used`
   - execute called twice with same approval
5. `Router__AgentNotAuthorized` / `...Expired` / `...AmountExceeded`
   - on-chain delegation mismatch

## 9. Related Docs

1. [README-agentic-mode.md](/home/himxa/Desktop/market/contracts/cre/market-workflow/README-agentic-mode.md)
2. [README.md](/home/himxa/Desktop/market/contracts/cre/market-workflow/README.md)
