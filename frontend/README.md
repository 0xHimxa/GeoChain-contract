# Frontend Workspace

This folder contains local frontend tooling for CRE policy + execute testing.

## Structure

- `minimal-sponsor-ui/`: local UI and adapter for:
  - CRE HTTP policy trigger (approve/deny)
  - CRE execute trigger (`writeReport` onchain)
- `index.ts`: placeholder Bun entry from initial scaffold

## Quick Start

```bash
cd /home/himxa/Desktop/market/contracts/frontend/minimal-sponsor-ui
bun install
cp .env.example .env
bun run dev
```

Open:

- `http://localhost:5173`

## Useful Script

From `minimal-sponsor-ui/`:

- `bun run cre:execute`  
  Manually trigger CRE execute endpoint with env vars.

## Notes

- Full details and examples live in:
  - `minimal-sponsor-ui/README.md`
