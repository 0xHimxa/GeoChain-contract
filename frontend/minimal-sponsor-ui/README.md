# Minimal CRE Sponsor UI

This folder is configured for CRE policy + execute flow only.

Flow:

1. Frontend calls `/api/sponsor`.
2. Adapter calls CRE policy trigger.
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
- report fields (`Report ActionType`, `Report PayloadHex`, optional receiver)

## Manual execute trigger call

```bash
CRE_EXECUTE_TRIGGER_URL=... \
CRE_APPROVAL_ID=cre_approval_... \
CHAIN_ID=84532 \
REPORT_ACTION_TYPE=createMarket \
REPORT_PAYLOAD_HEX=0x... \
bun run cre:execute
```
