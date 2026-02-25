# Frontend Input Parameters

This file describes all input fields in `minimal-sponsor-ui/index.html` and how each value is used.

## Trigger URLs

- `CRE HTTP Trigger URL` (`creTriggerUrl`)
  - Used by the local adapter (`server.ts`) for the policy request.
  - Sent in the first call body to `httpSponsorPolicy.ts`.
- `CRE Execute Trigger URL` (`creExecuteTriggerUrl`)
  - Used by the local adapter for the execute request after policy approval.
  - Sent in the second call body to `httpExecuteReport.ts`.

## Request Context

- `Chain ID` (`chainId`)
  - Target chain for policy and execute checks.
  - Must match supported chains in CRE config.
- `Action` (`action`)
  - Policy action label (for sponsor policy allowlist checks).
- `Amount (USDC 6dp as integer string)` (`amountUsdc`)
  - Requested token amount for the operation.
  - Used by CRE to enforce amount policy.
  - Used by CRE permit validation to ensure:
    - permit `value >= amountUsdc`
    - owner token `balanceOf >= amountUsdc`
- `Slippage (bps)` (`slippageBps`)
  - Used by sponsor policy to enforce max slippage.

## Permit Signing Inputs

- `Permit Token Address` (`permitToken`)
  - ERC20 token contract for EIP-2612 permit.
  - Used as `verifyingContract` in typed data domain.
- `Permit Spender Address` (`permitSpender`)
  - Spender authorized by permit.
  - Editable so you can change spender later.
  - Should match `sponsorPolicy.permitSpender` if that policy value is set.
- `Permit Domain Name` (`permitDomainName`)
  - EIP-712 domain `name` used for signing/verification.
  - Must match token's permit domain name.
- `Permit Domain Version` (`permitDomainVersion`)
  - EIP-712 domain `version` used for signing/verification.
- `Permit Deadline (unix sec)` (`permitDeadline`)
  - Permit expiry timestamp.
  - If empty, UI auto-sets `now + 20 minutes`.

## Report Execution Inputs

- `Report ActionType` (`reportActionType`)
  - Action encoded into CRE `writeReport` payload.
  - Must be in `executePolicy.allowedActionTypes`.
- `Report PayloadHex` (`reportPayloadHex`)
  - Hex payload bytes passed to `writeReport`.
- `Report Receiver` (`reportReceiver`, optional)
  - Optional receiver override.
  - If omitted, CRE uses chain config default receiver (`marketFactoryAddress`).

## JSON Inputs

- `Permit JSON` (`permit`)
  - Auto-populated when you click `Sign Permit`.
  - Also editable manually if needed.
  - Expected shape:
    - `token`, `owner`, `spender`, `value`, `nonce`, `deadline`, `signature`, `domainName`, `domainVersion`
- `UserOp JSON` (`userOp`)
  - Structural request metadata currently validated in policy:
    - `sender`, `callData`, `signature`
  - UI sets `userOp.sender` to connected wallet during permit signing.

## Buttons and Flow

- `Connect Wallet`
  - Connects injected wallet and stores selected account.
- `Sign Permit`
  - Reads token `nonces(owner)`.
  - Builds EIP-712 Permit typed data.
  - Requests wallet signature (`eth_signTypedData_v4`).
  - Writes signed object into `Permit JSON`.
- `Request Sponsorship`
  - Sends all fields to local adapter `/api/sponsor`.
  - Adapter performs:
    1. policy call (`httpSponsorPolicy`)
    2. execute call (`httpExecuteReport`) if approved.

## Payload Mapping (Adapter -> CRE)

Policy request body:

```json
{
  "requestId": "ui_...",
  "chainId": 84532,
  "action": "swapYesForNo",
  "amountUsdc": "1000000",
  "slippageBps": 150,
  "permit": {},
  "userOp": {}
}
```

Execute request body:

```json
{
  "requestId": "exec_...",
  "approvalId": "cre_approval_...",
  "chainId": 84532,
  "amountUsdc": "1000000",
  "permit": {},
  "actionType": "createMarket",
  "payloadHex": "0x...",
  "receiver": "0x...",
  "gasLimit": "10000000"
}
```
