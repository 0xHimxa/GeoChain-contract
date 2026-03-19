# 0xHimxa

I build autonomous on-chain protocols — prediction markets, cross-chain pricing infrastructure, and agent-native DeFi systems that run without human operators.
Currently focused on mechanism design at the intersection of market microstructure, Chainlink's off-chain compute layer, and multi-chain state consistency.

---

## What I Build

- **Prediction market mechanisms** — designed and implemented LMSR pricing on the EVM with WAD-scaled (1e18) fixed-point arithmetic to replace a constant-product AMM, computing `exp()` and `ln()` off-chain in Chainlink CRE and validating invariants on-chain
- **Cross-chain protocol architecture** — hub-spoke CCIP topology with dual-path canonical price sync and a 4-band deviation policy engine (fee surcharges, direction locks, circuit breakers) protecting spoke markets across Arbitrum and Base
- **Autonomous on-chain systems** — 15+ Chainlink CRE handlers across cron, HTTP, and EVM-log triggers that automate the full market lifecycle from AI-powered creation through resolution, dispute adjudication, and LP withdrawal processing
- **Agent delegation infrastructure** — 6-layer defense-in-depth security model for on-chain AI agent trading without custodial risk, from EIP-712 session signatures through on-chain action-mask bitfield authorization

---

## Featured Work

### GeoChain — Autonomous Cross-Chain Prediction Markets

An LMSR-based prediction market protocol with CRE-driven lifecycle automation, cross-chain state synchronization, and bounded agent delegation.

- On-chain LMSR engine with off-chain BigInt `exp()`/`ln()` (Taylor series + Halley's method) — no native EVM opcodes exist for these
- Hub-spoke cross-chain architecture with dual-path price propagation (CCIP + CRE direct writes) and progressive circuit breakers
- 6-layer agent security model — funds never leave the router; agents are scoped executors, not custodians
- Three independently deployed CRE workflows isolating operational automation, user operations, and agent trading by key set and failure domain

`Solidity` `Chainlink CRE` `Chainlink CCIP` `Foundry` `TypeScript` `Firebase`

[View Repository →](https://github.com/0xHimxa/GeoChain-contrat)

---

## Technical Stack

| Smart Contracts | Infrastructure and Tooling |
|---|---|
| Solidity 0.8.x | Chainlink CRE (cron, HTTP, EVM-log triggers) |
| UUPS Proxy Pattern | Chainlink CCIP |
| ERC-20 | Foundry (Forge, Anvil, Cast) |
| Fixed-Point Arithmetic (WAD 1e18) | TypeScript |
| AMM Design (LMSR, CPMM) | Firebase Firestore |
| EIP-712 Typed Data | Multi-chain Deployment (Arbitrum, Base) |

---

## Currently

- **Building** → LMSR prediction markets with autonomous CRE workflows
- **Exploring** → cross-chain state consistency and MEV-aware pricing
- **Open to** → smart contract, protocol, and DeFi infrastructure roles

---

## Contact

Reach out via **[your email or Telegram]**.
Interested in protocol roles, mechanism design problems, and cross-chain infrastructure challenges.
