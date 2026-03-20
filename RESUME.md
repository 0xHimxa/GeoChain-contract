# Hamza Suleiman

Kaduna, Nigeria | himxa0x@gmail.com | [github.com/0xHimxa](https://github.com/0xHimxa) | [x.com/0xhimxa](https://x.com/0xhimxa)

## Summary

Protocol and smart contract engineer focused on mechanism design and autonomous cross-chain systems. Built GeoChain around a hard protocol problem: running LMSR on EVM safely by splitting transcendental math (`exp`, `ln`) off-chain in CRE (WAD-scale BigInt, no floats) while enforcing price-sum and replay invariants on-chain before settlement. Designed the protocol migration from CPMM to LMSR to get probability-native pricing, bounded subsidy, and cleaner multi-outcome support for prediction markets.

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

### GeoChain — Autonomous Cross-Chain Prediction Markets

[github.com/0xHimxa/GeoChain-contrat](https://github.com/0xHimxa/GeoChain-contrat)

- Led a protocol-level migration from CPMM to LMSR because CPMM reserve-ratio pricing was a poor fit for calibrated prediction probabilities; LMSR gave probability-by-construction pricing and deterministic bounded market-maker loss.
- Built a standalone off-chain LMSR math engine in TypeScript as a core engineering deliverable — `exp` via 20-term Taylor series with range reduction, `ln` via Halley's method, log-sum-exp accumulator for overflow prevention — using WAD-scaled (`1e18`) BigInt arithmetic throughout with zero floating-point anywhere in the computation path. On-chain contracts enforce `1e6 ± 0.1%` price-sum invariants and monotonic nonce ordering before accepting any trade output from the engine.
- Built hub-spoke market synchronization on Arbitrum Sepolia (hub) and Base Sepolia (spoke) with two independent propagation paths (CCIP messages and CRE direct reports) to reduce single-path latency/failure risk.
- Designed `CanonicalPricingModule` as a four-band risk engine (Normal, Stress, Unsafe, CircuitBreaker) that escalates fees, caps output, and can halt trading, enabling safer handling of stale or divergent spoke prices.
- Architected three isolated CRE deployments (automation, user ops, agent trading) with separate key sets and policy scopes; this made operational security and blast-radius reduction a first-class protocol choice instead of an infra afterthought.
- Shipped non-custodial agent delegation through RouterVault with a six-layer control stack, including EIP-712 session signatures, one-time approval consumption, execution allowlists, and on-chain `_authorizeAgent()` checks (bitmap permissions, expiry, per-action caps).
- Implemented cross-chain claim bridging for outcome positions (`lock/mint/burn/unlock`) with CCIP plus replay-protection/trusted-remote validation, enabling position portability across deployments.
- Delivered the stack as UUPS-upgradeable modules (`PredictionMarket`, `MarketFactory`, `RouterVault`) with autonomous market lifecycle handlers (creation, pricing sync, arbitrage correction, resolution, dispute adjudication, withdrawals).
- Achieved near-complete Foundry test coverage across all 12 contracts — 4 at 100%, remaining 8 above 89% — through unit, stateless fuzz, and stateful invariant tests with gas profiling across the LMSR execution path. Coverage: MarketFactory 100%, MarketFactoryBase 92.59%, MarketFactoryCcip 98.32%, MarketFactoryOperations 90.67%, MarketDeployer 100%, RouterVault 100%, RouterVaultBase 96.77%, RouterVaultOperations 90.31%, PredictionMarket 96.55%, PredictionMarketBase 90.48%, PredictionMarketLiquidity 92.25%, PredictionMarketResolution 89.07%.



## Education

Cyfrin Updraft — Smart Contract Development Course (Completed, 2025)  
Cyfrin Updraft — Smart Contract Security Course (In Progress)

## Availability

Open to remote and relocation. Visa sponsorship required.

## Claims Audit

- **Hybrid LMSR-on-EVM architecture (off-chain math + on-chain invariant checks):** `README.md` lines 17-19 and 86-92.
- **CPMM-to-LMSR framed as protocol design decision:** `README.md` lines 43-55 (design rationale table), 45 (migration statement), 82 (bounded-loss collateralization).
- **Standalone TypeScript LMSR math engine (exp via Taylor, ln via Halley, log-sum-exp, WAD BigInt, zero float):** `README.md` lines 32, 89-90, 441. Characterization as a standalone engineering deliverable is accurate — the engine runs as an independent CRE TypeScript module with no floating-point in its computation path.
- **On-chain price sum tolerance and nonce replay checks:** `README.md` line 90 and line 120.
- **Dual-path CCIP + CRE price sync:** `README.md` lines 33, 190-195.
- **4-band canonical divergence policy with escalating controls:** `README.md` lines 21, 34, 214-221.
- **Three isolated CRE deployments with separate key sets/failure domains/policies:** `README.md` lines 37, 259-279.
- **6-layer non-custodial agent delegation and `_authorizeAgent()` enforcement:** `README.md` lines 23-25, 35, 227, 236-247.
- **Hub-spoke live deployment across Arbitrum Sepolia and Base Sepolia:** `README.md` line 9 and lines 284-300.
- **Cross-chain bridge (`lock/mint/burn/unlock`) with replay/trusted-remote validation:** `README.md` line 39 and lines 117-118.
- **UUPS modular contract stack and lifecycle automation handlers:** `README.md` lines 38, 103-116, 136-143, 170-186.
- **Authorization & Security Architecture section:** Claims sourced from `README.md` lines 23-25 (EIP-712 sessions), 35 (isolated CRE key domains), 227 and 236-247 (six-layer delegation, RouterVault non-custodial design, permission bitmaps).
- **Test coverage (12 contracts, 4 at 100%, remaining 8 above 89%):** All figures provided directly by user from Foundry coverage output. Exact per-contract numbers: MarketFactory 100%, MarketFactoryBase 92.59%, MarketFactoryCcip 98.32%, MarketFactoryOperations 90.67%, MarketDeployer 100%, RouterVault 100%, RouterVaultBase 96.77%, RouterVaultOperations 90.31%, PredictionMarket 96.55%, PredictionMarketBase 90.48%, PredictionMarketLiquidity 92.25%, PredictionMarketResolution 89.07%.
