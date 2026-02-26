# CRE + Router/Vault Changes Explained

This is the current state after permit removal.

## What is now required

1. Session auth is required.
- User signs one EIP-712 session grant.
- Per-request intent is signed by session key (no wallet popup each request).

2. One-time collateral approval to router.
- User sends ERC20 `approve(router, amount)` from wallet.
- Then user can deposit collateral to router vault.

3. Direct deposit is user-paid gas.
- User calls router `depositCollateral(amount)` from wallet.

## What was removed

- Sponsor policy permit requirement removed.
- Permit validation handler removed.
- Permit UI fields/buttons/JSON removed.
- Adapter no longer sends permit payload.

## Router interaction model

- CRE executes router actions through `writeReport` to router receiver.
- Router holds real tokens onchain.
- Router tracks per-user balances internally (`collateralCredits`, `tokenCredits`, `lpShareCredits`).
- Event/market selection comes from payload `market` address in router action payload.

## Chain-based receiver resolution

- Execute flow now prefers `evms[].routerReceiverAddress` for router action types.
- UI also loads chain config from `/api/chain-config?chainId=...` and auto-fills:
  - execute receiver address
  - collateral token address

## Files changed

- `contract/src/router/PredictionMarketRouterVault.sol`
- `cre/market-workflow/handlers/httpSponsorPolicy.ts`
- `cre/market-workflow/handlers/httpExecuteReport.ts`
- `cre/market-workflow/Constant-variable/config.ts`
- `cre/market-workflow/config.staging.json`
- `cre/market-workflow/config.production.json`
- `frontend/minimal-sponsor-ui/index.html`
- `frontend/minimal-sponsor-ui/server.ts`
- `frontend/minimal-sponsor-ui/README.md`
- `frontend/minimal-sponsor-ui/FRONTEND_INPUT_PARAMS.md`
