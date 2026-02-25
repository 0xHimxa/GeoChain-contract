# CRE + AA Integration Guide

This document explains:

1. What was added/changed in this repo.
2. Why each part exists.
3. How to set everything up from zero.
4. How to test both transaction modes.

It is written as a standalone guide without assuming prior setup.

---

## 1) What Was Added

### A. CRE workflow changes (`cre/market-workflow`)

#### New HTTP policy handler

- File: `cre/market-workflow/handlers/httpSponsorPolicy.ts`
- Purpose:
  - Accepts HTTP request payload.
  - Validates whether a requested user action can be sponsored.
  - Returns `approved`/`denied` + reason.

#### New HTTP execute handler

- File: `cre/market-workflow/handlers/httpExecuteReport.ts`
- Purpose:
  - Accepts approved execution request.
  - Encodes `actionType + payload`.
  - Submits onchain tx via `runtime.report(...)` + `EVMClient.writeReport(...)`.
  - Returns tx hash and explorer URL when successful.

#### Workflow wiring

- File: `cre/market-workflow/main.ts`
- Purpose:
  - Adds HTTP triggers for:
    - policy decisions
    - optional execution
  - Keeps existing cron workflow support.

#### Config types extended

- File: `cre/market-workflow/Constant-variable/config.ts`
- Added:
  - `httpTriggerAuthorizedKeys`
  - `httpExecutionAuthorizedKeys`
  - `sponsorPolicy`
  - `executePolicy`

#### Config JSONs updated

- Files:
  - `cre/market-workflow/config.staging.json`
  - `cre/market-workflow/config.production.json`
- Purpose:
  - Adds placeholders/toggles for policy + execute modes.

---

### B. Frontend/local adapter changes (`frontend/minimal-sponsor-ui`)

#### Local server + UI

- Files:
  - `frontend/minimal-sponsor-ui/server.ts`
  - `frontend/minimal-sponsor-ui/index.html`
- Purpose:
  - Local page to submit sponsor requests.
  - Adapter endpoint (`/api/sponsor`) to orchestrate:
    - policy trigger
    - execute trigger OR paymaster path.

#### AA scripts

- Files:
  - `scripts/checkBundler.ts`
  - `scripts/checkPaymaster.ts`
  - `scripts/testSponsoredUserOp.ts`
  - `scripts/setupPimlicoEnv.ts`
  - `scripts/triggerExecuteReport.ts`
- Purpose:
  - Validate infra quickly.
  - Send a real sponsored UserOp.
  - Simplify env generation (Pimlico helper).
  - Trigger CRE execute endpoint from CLI.

#### Package updates

- File: `frontend/minimal-sponsor-ui/package.json`
- Added dependencies:
  - `permissionless`
  - `viem`
- Added scripts:
  - `aa:setup:pimlico`
  - `aa:check-bundler`
  - `aa:check-paymaster`
  - `aa:test-sponsored`
  - `cre:execute`

#### Env template

- File: `frontend/minimal-sponsor-ui/.env.example`
- Purpose:
  - Provides required environment variable names and expected format.

---

### C. Top-level frontend docs

- File: `frontend/README.md`
- Purpose:
  - Workspace-level summary and quick links.

---

## 2) System Modes (Important)

There are two distinct transaction modes:

### Mode 1: ERC-4337 paymaster mode

- You create/send a UserOperation with bundler + paymaster infra.
- Scripts used:
  - `aa:check-bundler`
  - `aa:check-paymaster`
  - `aa:test-sponsored`

### Mode 2: CRE execute mode

- You call policy trigger first.
- If approved, call execute trigger.
- Execute trigger sends onchain tx using `writeReport` to your receiver contract (factory/market).
- No paymaster required for this execution path.

---

## 3) Prerequisites

Install on your machine:

1. Bun (for frontend scripts)
2. CRE CLI (for workflow deploy/simulate/update)
3. Access to a supported testnet RPC
4. Funded wallet/private key (for testnet txs where needed)

---

## 4) Setup Step-by-Step

## Step 1: Install minimal sponsor UI dependencies

```bash
cd /home/himxa/Desktop/market/contracts/frontend/minimal-sponsor-ui
bun install
```

## Step 2: Create env file

```bash
cp .env.example .env
```

Fill values manually or use helper.

### Option A: manual `.env` fill

Set at least:

- `AA_CHAIN`
- `AA_RPC_URL`
- `AA_BUNDLER_URL`
- `AA_PAYMASTER_URL`
- `AA_OWNER_PRIVATE_KEY`
- `AA_ENTRYPOINT`

### Option B: Pimlico helper (quickest)

```bash
PIMLICO_API_KEY=YOUR_KEY \
AA_CHAIN=baseSepolia \
AA_RPC_URL=YOUR_RPC_URL \
AA_OWNER_PRIVATE_KEY=0xYOUR_KEY \
bun run aa:setup:pimlico
```

This writes `.env` and sets bundler + paymaster URLs in Pimlico format.

---

## Step 3: Configure CRE workflow (staging)

Edit:

- `cre/market-workflow/config.staging.json`

Set:

1. `httpTriggerAuthorizedKeys`: for policy trigger auth.
2. `httpExecutionAuthorizedKeys`: for execute trigger auth.
3. `sponsorPolicy.enabled = true` (if using policy gating).
4. `executePolicy.enabled = true` (if using execute trigger).
5. `executePolicy.allowedActionTypes` include only actions you want to permit.

Also ensure `evms` entries match your deployment chain names + receiver addresses.

---

## Step 4: Deploy/update CRE workflow

From project root (or your CRE workflow deployment command location), run your normal CRE deploy/update flow using:

- `cre/market-workflow/workflow.yaml`
- target `staging-settings` or your chosen target

After deployment, capture your trigger endpoint URLs:

1. Policy trigger URL
2. Execute trigger URL (if enabled)

Store them in:

- UI input fields, or
- env vars for scripts.

---

## Step 5: Validate AA infrastructure (if using paymaster mode)

```bash
cd /home/himxa/Desktop/market/contracts/frontend/minimal-sponsor-ui
bun run aa:check-bundler
bun run aa:check-paymaster
```

Expected:

- bundler returns `eth_supportedEntryPoints` containing your entrypoint.
- paymaster returns `pm_supportedEntryPoints` and gas-price response.

---

## 5) How To Test

### Test A: Send sponsored UserOp directly

```bash
bun run aa:test-sponsored
```

Success output includes:

- smart account address
- userOp hash
- included tx hash

---

### Test B: Policy + Execute through local UI

Run server:

```bash
bun run dev
```

Open:

- `http://localhost:5173`

Fill:

1. `CRE HTTP Trigger URL` (policy)
2. `CRE Execute Trigger URL` (execute)
3. `chainId`, `action`, limits
4. report fields:
   - `reportActionType`
   - `reportPayloadHex`
   - optional `reportReceiver`

Click `Request Sponsorship`.

Expected response:

- `creDecision.approved: true`
- `execute.submitted: true`
- tx hash + explorer URL

---

### Test C: Execute trigger from CLI

```bash
CRE_EXECUTE_TRIGGER_URL=... \
CRE_APPROVAL_ID=cre_approval_... \
CHAIN_ID=84532 \
REPORT_ACTION_TYPE=createMarket \
REPORT_PAYLOAD_HEX=0x... \
bun run cre:execute
```

---

## 6) Request/Response Shapes

### Policy trigger request (example)

```json
{
  "requestId": "req_1",
  "chainId": 84532,
  "action": "swapYesForNo",
  "amountUsdc": "1000000",
  "slippageBps": 150,
  "userOp": {
    "sender": "0x1111111111111111111111111111111111111111",
    "nonce": "0x1",
    "callData": "0x1234",
    "signature": "0x1234"
  }
}
```

### Policy trigger response (approved example)

```json
{
  "approved": true,
  "reason": "approved by CRE sponsor policy",
  "requestId": "req_1",
  "approvalId": "cre_approval_...",
  "approvalExpiresAtUnix": 1730000000
}
```

### Execute trigger request (example)

```json
{
  "requestId": "exec_1",
  "approvalId": "cre_approval_...",
  "chainId": 84532,
  "actionType": "createMarket",
  "payloadHex": "0x...",
  "receiver": "0xYourFactoryAddress",
  "gasLimit": "10000000"
}
```

### Execute trigger response (success example)

```json
{
  "submitted": true,
  "requestId": "exec_1",
  "txHash": "0x...",
  "chainName": "ethereum-testnet-sepolia-base-1",
  "receiver": "0x...",
  "explorerUrl": "https://sepolia.basescan.org/tx/0x..."
}
```

---

## 7) EntryPoint Clarification

For public testnets/mainnets, you usually do **not** deploy your own EntryPoint.

Default in this setup:

- EntryPoint v0.7:
  - `0x0000000071727de22e5e9d8baf0edac6f37da032`

Deploy your own EntryPoint only for private/local AA infrastructure.

---

## 8) Common Errors and Fixes

### `Missing env var ...`

- You did not fill required `.env` values.
- Fix: copy `.env.example` and fill all required fields.

### `entryPoint not supported`

- Bundler/paymaster and your configured entrypoint mismatch.
- Fix: run both check scripts and align entrypoint value.

### `chainId not mapped in config.evms`

- Execute trigger could not find matching chain in CRE config.
- Fix: add/update `evms` entry in `config.staging.json`.

### `actionType not allowed`

- Requested action is not in `executePolicy.allowedActionTypes`.
- Fix: add action or change request actionType.

### `writeReport reverted`

- Receiver or payload/action does not match contract `_processReport` logic.
- Fix:
  - confirm `actionType` string exactly matches expected values
  - ensure payload encoding matches contract decode type.

---

## 9) Security Notes (Must Read)

1. Keep `allowedActionTypes` strict and minimal.
2. Keep policy limits conservative during testing.
3. Use separate keys/endpoints for staging vs production.
4. Never expose private keys in UI/browser code.
5. Treat trigger URLs + authorized key setup as sensitive.

---

## 10) Recommended First Validation Sequence

1. `bun install`
2. `.env` complete
3. `aa:check-bundler`
4. `aa:check-paymaster`
5. Deploy/update CRE workflow with policy enabled
6. Test policy trigger (expect approved/denied output)
7. Test execute trigger with safe action/payload
8. Verify tx appears on explorer and contract state changes as expected

