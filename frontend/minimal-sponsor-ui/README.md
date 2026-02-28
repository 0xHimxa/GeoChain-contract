# Minimal Sponsor UI (React + TS + Tailwind)

This folder now has:

- React/TypeScript/Tailwind frontend (`src/`, Vite dev server)
- Bun backend (`server.ts`) with mock endpoints and CRE-shaped logs

## Features Implemented

- Google-style sign-in + local encrypted wallet in browser (no extension wallet required)
- Live market feed with SSE (`/api/events/stream`) and auto-created events
- Clear market close and resolution times in UI
- Event details with YES/NO price display
- Action flow through backend: sponsor payload log then execute payload log
- Action signature now uses EIP-712 typed-data (`CRE Session Authorization`)
- Enforced rule: user must `mintCompleteSets` before swap
- Closed markets block trading; resolved markets allow `redeem`
- Vault funding flows:
  - MetaMask deposit for local wallet beneficiary (approve + `depositFor(beneficiary, amount)`)
  - External-deposit log endpoint (`/api/funding/external-deposit`)
  - Fiat mock (`/api/fiat-payment-success`) logs provider payload + CRE fiat payload
- Positions page with holdings and redeemable amount

## Local Wallet Security Model

- Private key is generated in browser and encrypted with AES-GCM using your password.
- Encrypted payload is stored in `localStorage`.
- Private key is never sent to backend in auth payload.
- User signs operation intents locally and only signatures/public key are sent.

## Run

```bash
cd /home/himxa/Desktop/market/contracts/frontend/minimal-sponsor-ui
bun install
```

Terminal 1 (backend API):

```bash
bun run dev
```

Terminal 2 (frontend):

```bash
bun run frontend:dev
```

Open `http://localhost:5174`.

## Backend Log Tags

- `[MOCK_GOOGLE_SIGNIN]`
- `[MOCK_VAULT_DEPOSIT]`
- `[MOCK_CRE_POLICY]`
- `[MOCK_CRE_EXECUTE]`
- `[MOCK_PROVIDER_SUCCESS]`
- `[MOCK_CRE_FIAT_CREDIT]`
