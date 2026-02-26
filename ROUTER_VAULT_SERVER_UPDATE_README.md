# Router Vault + Server Update README

This document explains the latest changes made in this repo, with exact file-level details.

## 1) Permit path removed from sponsorship flow

What changed:
- Removed permit validation from sponsor policy.
- Removed permit handler file.
- Removed permit payload from frontend adapter.
- Removed permit fields/buttons from UI.

Files:
- `cre/market-workflow/handlers/httpSponsorPolicy.ts`
- `cre/market-workflow/handlers/permitValidation.ts` (deleted)
- `cre/market-workflow/Constant-variable/config.ts`
- `cre/market-workflow/config.staging.json`
- `cre/market-workflow/config.production.json`
- `frontend/minimal-sponsor-ui/index.html`
- `frontend/minimal-sponsor-ui/server.ts`

Result:
- Sponsorship approval now depends on session auth + policy checks only.

## 2) Router receiver is now chain-config driven

What changed:
- Execute handler now auto-selects router receiver from config for router actions.
- For action types starting with `router`, handler prefers `evms[].routerReceiverAddress`.

File:
- `cre/market-workflow/handlers/httpExecuteReport.ts`

Config fields now used:
- `evms[].routerReceiverAddress`
- `evms[].collateralTokenAddress`

Result:
- Users no longer need to manually type router receiver every time when chain config is set.

## 3) UI now supports direct approve/deposit (user pays gas)

What changed:
- Added `Approve Collateral` button:
  - Calls collateral ERC20 `approve(executeReceiverAddress, amountUsdc)`.
- Added `Deposit To Vault` button:
  - Calls router `depositCollateral(amountUsdc)`.
- Added `Collateral Token Address` input.
- Added chain config auto-load from `/api/chain-config?chainId=...`.

File:
- `frontend/minimal-sponsor-ui/index.html`

Result:
- Funding vault is now explicit wallet tx flow.
- This matches your requirement that user pays gas for deposit.

## 4) Added server env configuration example

What changed:
- Updated env example for local Bun server.

File:
- `frontend/minimal-sponsor-ui/.env.example`

Current variables:
- `PORT=5173`
- `CRE_CONFIG_PATH=/absolute/path/to/cre/market-workflow/config.staging.json`

How to use:
1. Create `.env` in `frontend/minimal-sponsor-ui`.
2. Copy values from `.env.example`.
3. Set a real absolute path for `CRE_CONFIG_PATH`.

## 5) Router now tracks accounted vs untracked collateral

What changed:
- Added state variable:
  - `uint256 public totalCollateralCredits;`
- Updated accounting updates on:
  - deposit
  - withdraw collateral
  - mint complete sets (collateral credit consumed)
  - redeem complete sets (collateral credit restored)
- Added view helper:
  - `getUntrackedCollateral()`

File:
- `contract/src/router/PredictionMarketRouterVault.sol`

Why:
- If someone sends collateral token directly to the router contract address (without deposit flow),
  that amount is visible as untracked collateral.

How to interpret:
- `totalCollateralCredits` = total collateral credited to users.
- `collateralToken.balanceOf(router)` = actual collateral in router wallet.
- `getUntrackedCollateral()` = actual balance minus credited balance (if positive).

## 6) What you must configure before using

In CRE config (`config.staging.json` / production):
- Set each chain `routerReceiverAddress` to deployed router address.
- Set each chain `collateralTokenAddress` to chain collateral ERC20.

In UI:
- Select correct `chainId`.
- Confirm auto-filled receiver/collateral values.
- Approve collateral once.
- Deposit as needed.
- Use sponsored router actions for trading.
