# Minimal CRE Sponsor UI

This folder is configured for CRE policy + execute flow only.

Flow:

1. Frontend calls `/api/sponsor`.
2. Adapter calls CRE policy trigger with `permit` payload + requested amount.
3. If approved, adapter calls CRE execute trigger (`writeReport` onchain).

## Setup

```bash
cd /home/himxa/Desktop/market/contracts/frontend/minimal-sponsor-ui
bun install
cp .env.example .env
```

Set:

- `CRE_TRIGGER_URL`
- `CRE_EXECUTE_TRIGGER_URL`

## Run UI

```bash
bun run dev
```

Open:

- `http://localhost:5173`

Fill:

- `CRE HTTP Trigger URL`
- `CRE Execute Trigger URL`
- request fields
- permit fields (`token`, `spender`, domain), then click `Sign Permit`
- permit JSON fields (`token`, `owner`, `spender`, `value`, `nonce`, `deadline`, `signature`, `domainName`, optional `domainVersion`) are auto-filled after signing
- report fields (`Report ActionType`, `Report PayloadHex`, optional receiver)

## Manual execute trigger call

```bash
CRE_EXECUTE_TRIGGER_URL=... \
CRE_APPROVAL_ID=cre_approval_... \
CHAIN_ID=84532 \
AMOUNT_USDC=1000000 \
PERMIT_JSON='{"token":"0x...","owner":"0x...","spender":"0x...","value":"1000000","nonce":"0","deadline":"1893456000","signature":"0x...","domainName":"USD Coin","domainVersion":"2"}' \
REPORT_ACTION_TYPE=createMarket \
REPORT_PAYLOAD_HEX=0x... \
bun run cre:execute
```

## Input Parameter Reference

- [FRONTEND_INPUT_PARAMS.md](/home/himxa/Desktop/market/contracts/frontend/minimal-sponsor-ui/FRONTEND_INPUT_PARAMS.md)
