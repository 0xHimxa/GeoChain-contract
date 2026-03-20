# Hamza Suleiman

Kaduna, Nigeria | himxa0x@gmail.com | [github.com/0xHimxa](https://github.com/0xHimxa) | [x.com/0xhimxa](https://x.com/0xhimxa)

## Summary

Protocol engineer specializing in prediction market design and cross-chain systems. Sole architect and developer of GeoChain — an autonomous cross-chain prediction market protocol featuring LMSR-based pricing, dual-path price synchronization, and non-custodial agent execution. Single-handedly designed and shipped the full stack: smart contracts, off-chain compute engine, CRE automation, cross-chain messaging, and comprehensive Foundry test suite.

## Core Skills

**Protocol Design:** LMSR market design and CPMM-to-LMSR migration strategy, bounded-loss market maker design (`b * ln(N)`), cross-chain canonical pricing policy (Normal/Stress/Unsafe/CircuitBreaker), agent-delegated execution with non-custodial constraints  
**Cross-Chain and Automation:** Chainlink CCIP hub-spoke messaging, Chainlink CRE (cron/HTTP/EVM-log) lifecycle automation, dual-path price sync (CCIP + CRE report path), autonomous dispute and resolution flows  
**Authorization & Security Architecture:**  
- EIP-712 session sponsorship with signature validation  
- One-time approval consumption with nonce replay protection  
- On-chain permission bitmaps with per-action amount caps and expiry enforcement  
- Six-layer agent delegation control stack  
- Isolated CRE workflow key domains with scoped failure boundaries  
- Non-custodial RouterVault design  
**Implementation:** Solidity 0.8.33, TypeScript, Foundry, UUPS proxy architecture, Firebase Firestore

## Protocol Engineering Experience

### GeoChain — Autonomous Cross-Chain Prediction Markets (Sole Engineer)

[github.com/0xHimxa/GeoChain-contrat](https://github.com/0xHimxa/GeoChain-contrat)

- Sole-designed and executed a protocol-level migration from CPMM to LMSR because CPMM reserve-ratio pricing was a poor fit for calibrated prediction probabilities; LMSR gave probability-by-construction pricing and deterministic bounded market-maker loss.
- Built a deterministic LMSR math engine in TypeScript using WAD-scaled BigInt (no floating point), implementing `exp` (Taylor + range reduction) and `ln` (Halley's method) with log-sum-exp stabilization.
- Integrated off-chain computation with on-chain enforcement of price-sum (±0.1%) and nonce ordering invariants, enabling safe execution of transcendental math on EVM without native floating-point support.
- Built hub-spoke market synchronization on Arbitrum Sepolia (hub) and Base Sepolia (spoke) with two independent propagation paths (CCIP messages and CRE direct reports) to reduce single-path latency/failure risk.
- Designed `CanonicalPricingModule` as a four-band risk engine (Normal, Stress, Unsafe, CircuitBreaker) that escalates fees, caps output, and can halt trading, enabling safer handling of stale or divergent spoke prices.
- Architected three isolated CRE deployments (automation, user ops, agent trading) with separate key sets and policy scopes; this made operational security and blast-radius reduction a first-class protocol choice instead of an infra afterthought.
- Shipped non-custodial agent delegation through RouterVault with a six-layer control stack, including EIP-712 session signatures, one-time approval consumption, execution allowlists, and on-chain `_authorizeAgent()` checks (bitmap permissions, expiry, per-action caps).
- Implemented cross-chain claim bridging for outcome positions (`lock/mint/burn/unlock`) with CCIP plus replay-protection/trusted-remote validation, enabling position portability across deployments.
- Solo-delivered the entire stack as UUPS-upgradeable modules (`PredictionMarket`, `MarketFactory`, `RouterVault`) with autonomous market lifecycle handlers (creation, pricing sync, arbitrage correction, resolution, dispute adjudication, withdrawals).
- Achieved near-complete Foundry test coverage across all 12 contracts — 4 at 100%, remaining 8 above 89% — through unit, stateless fuzz, and stateful invariant tests with gas profiling across the LMSR execution path. Coverage: MarketFactory 100%, MarketFactoryBase 92.59%, MarketFactoryCcip 98.32%, MarketFactoryOperations 90.67%, MarketDeployer 100%, RouterVault 100%, RouterVaultBase 96.77%, RouterVaultOperations 90.31%, PredictionMarket 96.55%, PredictionMarketBase 90.48%, PredictionMarketLiquidity 92.25%, PredictionMarketResolution 89.07%.



## Education

Cyfrin Updraft — Smart Contract Development Course (Completed, 2025)  
Cyfrin Updraft — Smart Contract Security Course (Completed, 2025)

## Availability

Available for remote contract engagements immediately. Open to full-time roles with relocation support where relevant.

