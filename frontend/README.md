# Frontend Workspace

This folder contains local frontend tooling for testing sponsored transaction flows.

## Structure

- `minimal-sponsor-ui/`: main test app for:
  - CRE HTTP policy trigger (approve/deny)
  - optional CRE execute trigger (`writeReport` onchain)
  - ERC-4337 paymaster/bundler test scripts
- `index.ts`: placeholder Bun entry from initial scaffold

## Quick Start

```bash
cd /home/himxa/Desktop/market/contracts/frontend/minimal-sponsor-ui
bun install
cp .env.example .env
```

Then run one of the flows below.

## Flow A: AA Paymaster (ERC-4337)

1. Fill `.env`:
   - `AA_RPC_URL`
   - `AA_BUNDLER_URL`
   - `AA_PAYMASTER_URL`
   - `AA_OWNER_PRIVATE_KEY`
   - `AA_CHAIN` (`baseSepolia`, `arbitrumSepolia`, `sepolia`)

2. Preflight checks:

```bash
bun run aa:check-bundler
bun run aa:check-paymaster
```

3. Send one sponsored UserOp:

```bash
bun run aa:test-sponsored
```

## Flow B: CRE HTTP Trigger Policy + Execute

1. In CRE workflow config (`cre/market-workflow/config.staging.json`):
   - set `sponsorPolicy.enabled = true`
   - set `executePolicy.enabled = true`
   - set `httpTriggerAuthorizedKeys`
   - set `httpExecutionAuthorizedKeys`

2. Deploy/update the CRE workflow.

3. Run UI:

```bash
bun run dev
```

4. Open `http://localhost:5173` and fill:
   - `CRE HTTP Trigger URL`
   - optional `CRE Execute Trigger URL`
   - action/payload fields

If execute trigger URL is provided, adapter calls:
- policy trigger first
- then execute trigger to submit `writeReport` tx.

## Useful Scripts

From `minimal-sponsor-ui/`:

- `bun run aa:setup:pimlico`  
  Generates `.env` using Pimlico URL format.
- `bun run aa:check-bundler`  
  Verifies bundler supports configured EntryPoint.
- `bun run aa:check-paymaster`  
  Verifies paymaster methods and gas price response.
- `bun run aa:test-sponsored`  
  Sends a sponsored test UserOp.
- `bun run cre:execute`  
  Manually trigger CRE execute endpoint with env vars.

## Notes

- Default EntryPoint is v0.7:  
  `0x0000000071727de22e5e9d8baf0edac6f37da032`
- On public testnets you typically do not deploy your own EntryPoint.
- Full details and examples live in:
  - `minimal-sponsor-ui/README.md`
