# Minimal CRE Sponsor UI + AA Test Kit

This folder now contains:

1. A local UI + adapter:
   - frontend -> `/api/sponsor` -> CRE policy -> paymaster sponsor RPC.
2. A direct AA test script:
   - creates a `SimpleAccount` and submits one sponsored UserOp.
3. A paymaster preflight check script.
4. Optional CRE execute mode:
   - policy trigger approves
   - second execute trigger sends onchain `writeReport`.

## Do I need to deploy EntryPoint?

- Public testnets/mainnets: **No**, usually not. Use standard EntryPoint v0.7:
  - `0x0000000071727de22e5e9d8baf0edac6f37da032`
- Local/private chain without AA infra: **Yes**, you must deploy EntryPoint + bundler + paymaster stack.

## 1) Prepare environment

```bash
cd /home/himxa/Desktop/market/contracts/frontend/minimal-sponsor-ui
cp .env.example .env
```

Set:

- `AA_RPC_URL`
- `AA_BUNDLER_URL`
- `AA_PAYMASTER_URL`
- `AA_OWNER_PRIVATE_KEY`
- `AA_CHAIN` (`baseSepolia`, `arbitrumSepolia`, or `sepolia`)

Optional:

- `AA_ENTRYPOINT` (defaults to v0.7 address above)
- `CRE_TRIGGER_URL`

### Where to get `AA_PAYMASTER_URL` and `AA_BUNDLER_URL`

Recommended quickest path (Pimlico):

1. Create account and API key in Pimlico dashboard.
2. Build URL:
   - `https://api.pimlico.io/v2/<network>/rpc?apikey=<YOUR_KEY>`
3. For Base Sepolia:
   - `https://api.pimlico.io/v2/base-sepolia/rpc?apikey=<YOUR_KEY>`
4. Set both:
   - `AA_BUNDLER_URL=<that URL>`
   - `AA_PAYMASTER_URL=<that URL>`

`AA_RPC_URL` should be your standard chain RPC (Alchemy/Infura/public node), not bundler URL.

One-command helper (writes `.env` for Pimlico):

```bash
PIMLICO_API_KEY=... \
AA_CHAIN=baseSepolia \
AA_RPC_URL=... \
AA_OWNER_PRIVATE_KEY=0x... \
bun run aa:setup:pimlico
```

## 2) Install and check paymaster

```bash
bun install
bun run aa:check-bundler
bun run aa:check-paymaster
```

This calls:

- `eth_supportedEntryPoints` (bundler)
- `pm_supportedEntryPoints`
- `pimlico_getUserOperationGasPrice`

## 3) Send one sponsored UserOp directly

```bash
bun run aa:test-sponsored
```

What it does:

- creates a SimpleAccount from `AA_OWNER_PRIVATE_KEY`
- gets gas price from paymaster
- sends a minimal 0-value transaction via bundler/paymaster
- waits for inclusion receipt

Script file:

- [testSponsoredUserOp.ts](/home/himxa/Desktop/market/contracts/frontend/minimal-sponsor-ui/scripts/testSponsoredUserOp.ts)

## 4) Test CRE policy + paymaster path via UI

Run:

```bash
bun run dev
```

Open:

- `http://localhost:5173`

Then fill:

- `CRE HTTP Trigger URL`
- `Paymaster JSON-RPC URL`
- `EntryPoint`
- request payload/UserOp

To use **second CRE trigger execution mode** instead of paymaster:

- Fill `CRE Execute Trigger URL`
- Fill `Report ActionType` + `Report PayloadHex`
- Optional: `Report Receiver` (defaults to configured marketFactoryAddress for selected chain)

In this mode flow is:

1. `/api/sponsor` -> policy trigger (`approved`)
2. adapter calls execute trigger
3. execute trigger uses `writeReport` to send tx onchain

UI/adapter files:

- [index.html](/home/himxa/Desktop/market/contracts/frontend/minimal-sponsor-ui/index.html)
- [server.ts](/home/himxa/Desktop/market/contracts/frontend/minimal-sponsor-ui/server.ts)

## CRE workflow requirements

In [config.staging.json](/home/himxa/Desktop/market/contracts/cre/market-workflow/config.staging.json):

- set `sponsorPolicy.enabled` to `true`
- configure `httpTriggerAuthorizedKeys` with your trigger signer key
- configure `httpExecutionAuthorizedKeys` for execute trigger
- set `executePolicy.enabled` to `true`
- whitelist action strings in `executePolicy.allowedActionTypes`

CRE policy handler:

- [httpSponsorPolicy.ts](/home/himxa/Desktop/market/contracts/cre/market-workflow/handlers/httpSponsorPolicy.ts)
- [httpExecuteReport.ts](/home/himxa/Desktop/market/contracts/cre/market-workflow/handlers/httpExecuteReport.ts)

Optional manual execute trigger call:

```bash
CRE_EXECUTE_TRIGGER_URL=... \
CRE_APPROVAL_ID=cre_approval_... \
CHAIN_ID=84532 \
REPORT_ACTION_TYPE=createMarket \
REPORT_PAYLOAD_HEX=0x... \
bun run cre:execute
```
