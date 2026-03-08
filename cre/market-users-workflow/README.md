<p align="center">
  <h1 align="center">👤 Market Users Workflow — User Ops + Credits</h1>
  <p align="center">
    <strong>Dedicated CRE workflow for human user sponsorship, execution, session control, and deposit crediting</strong>
  </p>
</p>

---

## Overview

The **market-users-workflow** is the CRE deployment that handles **human user requests** and **credit ingestion** for GeoChain.

It owns the request/approval path for:

- sponsored user actions
- execution of approved reports
- session revocation
- fiat crediting
- ETH deposit crediting from on-chain logs

This workflow exists separately from:

- `market-automation-workflow`, which owns cron-based market operations
- `agents-workflow`, which owns agent-specific trade planning and execution

That split keeps user-facing HTTP traffic isolated from cron automation and agent trading policies.

## Triggers

| Handler | Trigger | Purpose |
|---|---|---|
| `sponsorUserOpPolicyHandler` | HTTP | Validate session signatures and create one-time approvals for user actions |
| `executeReportHttpHandler` | HTTP | Consume approvals and submit the authorized report on-chain |
| `revokeSessionHttpHandler` | HTTP | Revoke an active session |
| `fiatCreditHttpHandler` | HTTP | Credit user balances from supported fiat providers |
| `ethCreditFromLogsHandler` | EVM Log | Detect ETH deposits and convert them into router credits |

## Architecture

```
market-users-workflow/
├── main.ts                          # Workflow graph entry point
├── config.staging.json              # Staging config
├── config.production.json           # Production config
├── workflow.yaml                    # CRE CLI targets
├── Constant-variable/
│   └── config.ts                    # Workflow config types
├── handlers/
│   ├── httpHandlers/
│   │   ├── httpSponsorPolicy.ts     # User sponsor approval pipeline
│   │   ├── httpExecuteReport.ts     # Report execution
│   │   ├── httpRevokeSession.ts     # Session termination
│   │   └── httpFiatCredit.ts        # Fiat crediting
│   ├── eventsHandler/
│   │   └── ethCreditFromLogs.ts     # ETH deposit log crediting
│   └── utils/
│       ├── agentAction.ts           # Shared action mapping helpers
│       ├── sessionMessage.ts        # Session message formatting
│       └── sessionValidation.ts     # EIP-712 validation helpers
├── firebase/
│   ├── sessionStore.ts              # Approval/session persistence
│   └── signUp.ts                    # Firebase auth
└── payload/
    ├── fiat.json
    ├── positions.json
    └── sponser.json
```

## Handler Notes

### `sponsorUserOpPolicyHandler`

Validates the incoming request against `sponsorPolicy`, verifies session authorization, and stores a one-time approval record.

### `executeReportHttpHandler`

Consumes a stored approval, enforces `executePolicy`, and delivers the report to the configured on-chain receiver.

### `revokeSessionHttpHandler`

Terminates a session through the same validation path used by user approvals, avoiding policy drift.

### `fiatCreditHttpHandler`

Validates provider, amount, and chain support through `fiatCreditPolicy`, then credits the user's balance.

### `ethCreditFromLogsHandler`

Listens for ETH deposit logs from configured router receivers and credits the corresponding user balance when the chain is allowed by `ethCreditPolicy`.

## Configuration

Important config fields in `config.staging.json` / `config.production.json`:

| Key | Purpose |
|---|---|
| `evms[]` | Per-chain factory, router receiver, collateral, and gas settings |
| `httpTriggerAuthorizedKeys` | Authorized keys for sponsor + revoke endpoints |
| `httpExecutionAuthorizedKeys` | Authorized keys for execute endpoint |
| `httpFiatCreditAuthorizedKeys` | Authorized keys for fiat credit endpoint |
| `sponsorPolicy` | Allowed actions, chain scope, max amount, slippage, session rules |
| `executePolicy` | Allowed on-chain action types |
| `fiatCreditPolicy` | Supported providers, chains, and max amount |
| `ethCreditPolicy` | Supported chains and max ETH-credit amount |

## Getting Started

```bash
cd cre/market-users-workflow
bun install
cre workflow simulate ./ --target staging-settings --non-interactive
cre workflow deploy --target staging-settings
```

For targeted HTTP simulation, use the payload files in `payload/` with the relevant `--trigger-index`.
