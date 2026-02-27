# Minimal CRE Sponsor UI

This folder is configured for CRE policy + execute flow only.

Flow:

1. Frontend calls `/api/sponsor`.
2. Adapter calls CRE policy trigger with session auth + requested amount.
3. If approved, adapter calls CRE execute trigger (`writeReport` onchain).
4. For collateral funding, user approves token to router and calls router `depositCollateral` directly from wallet (user pays gas).

## Setup

```bash
cd /home/himxa/Desktop/market/contracts/frontend/minimal-sponsor-ui
bun install
cp .env.example .env
```

Set:

- `PORT` (optional, default `5173`)
- `CRE_CONFIG_PATH` (absolute path to CRE config JSON used by `/api/chain-config`)

## Run UI

```bash
bun run dev
```

Open:

- `http://localhost:5173`
- `http://localhost:5173/fiat` (new web2 payment mock page)

Fill:

- `CRE HTTP Trigger URL`
- `CRE Execute Trigger URL`
- request fields
- `Collateral Token Address`
- click `Approve Collateral` once
- click `Deposit To Vault` when funding vault balance
- report fields (`Report ActionType`, `Report PayloadHex`, optional receiver)

## Manual execute trigger call

```bash
CRE_EXECUTE_TRIGGER_URL=... \
CRE_APPROVAL_ID=cre_approval_... \
CHAIN_ID=84532 \
AMOUNT_USDC=1000000 \
REPORT_ACTION_TYPE=createMarket \
REPORT_PAYLOAD_HEX=0x... \
bun run cre:execute
```

## Input Parameter Reference

- [FRONTEND_INPUT_PARAMS.md](/home/himxa/Desktop/market/contracts/frontend/minimal-sponsor-ui/FRONTEND_INPUT_PARAMS.md)

## Fiat Mock Endpoint (No CRE Call)

- `POST /api/fiat-payment-success`
- Purpose: simulate provider success, shape payload for `httpFiatCredit`, and log it only.
- No CRE URL/request is used in this endpoint.

Example request:

```json
{
  "chainId": 84532,
  "user": "0x1111111111111111111111111111111111111111",
  "provider": "google_pay",
  "amountUsd": "2.50",
  "paymentId": "pay_demo_001",
  "requestId": "fiat_req_demo_001"
}
```
