# Frontend Input Parameters

This file describes input fields in `minimal-sponsor-ui/index.html` after permit removal.

## Trigger URLs

- `CRE HTTP Trigger URL` (`creTriggerUrl`)
  - Used for sponsor policy decision (`httpSponsorPolicy.ts`).
- `CRE Execute Trigger URL` (`creExecuteTriggerUrl`)
  - Used for onchain report execution (`httpExecuteReport.ts`).
- `CRE Session Revoke Trigger URL` (`creRevokeTriggerUrl`)
  - Used to revoke active sessions.

## Chain + Routing

- `Chain ID` (`chainId`)
  - Drives policy checks and execute chain selection.
  - Also used by `/api/chain-config` to auto-fill:
    - `Execute Receiver Address`
    - `Collateral Token Address`

- `Execute Receiver Address` (`executeReceiverAddress`)
  - The contract that receives CRE `writeReport` calls.
  - For router actions, this should be your router receiver.

- `Target Event Market Address` (`targetMarketAddress`)
  - The specific market/event contract for router actions.
  - Encoded inside `reportPayloadHex` when `auto` mode is used.

## Trading Inputs

- `Action` (`action`)
  - Sponsor policy action label.
- `Amount (USDC 6dp as integer string)` (`amountUsdc`)
  - Amount used for both sponsor request and router payload encoding.
- `Slippage (bps)` (`slippageBps`)
  - Checked by sponsor policy and included in session intent signature.

## Vault Funding Inputs

- `Collateral Token Address` (`collateralTokenAddress`)
  - ERC20 collateral token used for approve/deposit.

Buttons:
- `Approve Collateral`
  - Sends ERC20 `approve(executeReceiverAddress, amountUsdc)` from wallet.
- `Deposit To Vault`
  - Calls router `depositCollateral(amountUsdc)` from wallet.
  - User pays gas for this direct transaction.

## Session Inputs

- `Session Max Amount`, `Session Duration`, `Session Key Password`, `Session Allowed Actions`
  - Used to create EIP-712 session grant and local encrypted session key.

- `Session JSON`
  - Stores session grant + latest request nonce/signature used in sponsor request.

## Report Execution Inputs

- `Report ActionType` (`reportActionType`)
  - Must be allowed in `executePolicy.allowedActionTypes`.
- `Report PayloadHex` (`reportPayloadHex`)
  - `auto` builds router payload from current form fields.
- `Router Outcome Token` (`routerOutcomeToken`)
  - Used only for `routerWithdrawOutcomeFor` payload encoding.

## UserOp Input

- `UserOp JSON` (`userOp`)
  - Structural metadata checked by sponsor policy (`sender`, `callData`, `signature`).

## Request Sponsorship Flow

- `Request Sponsorship`
  1. Signs session intent locally with session key.
  2. Calls `/api/sponsor`.
  3. Adapter calls sponsor policy trigger.
  4. If approved, adapter calls execute trigger to submit `writeReport`.
