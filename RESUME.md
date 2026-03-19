# Hamza Suleiman

Kaduna, Nigeria | himxa0x@gmail.com | [github.com/0xHimxa](https://github.com/0xHimxa) | [x.com/0xhimxa](https://x.com/0xhimxa)

Open to remote and relocation | Visa sponsorship required

---

## Summary

Smart contract and protocol engineer specializing in DeFi mechanism design, cross-chain architecture, and autonomous on-chain systems. Primary body of work is GeoChain — an LMSR-based prediction market protocol with Chainlink CRE-driven lifecycle automation, CCIP hub-spoke cross-chain state synchronization, and a 6-layer agent delegation security model, deployed across Arbitrum Sepolia and Base Sepolia. The defining technical challenge solved in this work: implementing LMSR pricing on the EVM — where no native exp()/ln() opcodes exist — via off-chain WAD-scaled (1e18) fixed-point approximation in CRE with on-chain invariant validation.

---

## Technical Skills

**Languages:** Solidity 0.8.x, TypeScript

**Smart Contract Patterns:** UUPS and Transparent Proxy, ReentrancyGuard, Pausable, Access Control, EIP-712 Typed Data Signatures, Fixed-Point Arithmetic (WAD 1e18)

**Protocols and Infrastructure:** Chainlink CRE (cron, HTTP, EVM-log triggers), Chainlink CCIP, Chainlink VRF, Chainlink Price Feeds, OpenZeppelin Contracts, Firebase Firestore

**Testing and Tooling:** Foundry (Forge, Anvil, Cast), Unit Testing, Stateless Fuzz Testing, Stateful Invariant Testing, Gas Profiling, Deployment Scripting, UUPS Proxy Deployment and Upgrade Management, Multi-chain Contract Verification

**Chains:** Arbitrum, Base, Ethereum (testnet deployment and testing)

---

## Projects

### GeoChain — Autonomous Cross-Chain Prediction Markets

LMSR-based prediction market protocol with CRE-driven lifecycle automation, cross-chain state synchronization, and bounded agent delegation. 12+ Solidity contracts deployed behind UUPS proxies across two chains.

[github.com/0xHimxa/GeoChain-contrat](https://github.com/0xHimxa/GeoChain-contrat)

- Migrated the AMM pricing engine from Constant Product Market Maker (CPMM) to Logarithmic Market Scoring Rule (LMSR), implementing the cost function C(q) = b * ln(sum(exp(q_i / b))) with bounded market-maker subsidy, replacing an architecture unsuited for prediction market probability pricing.
- Implemented off-chain LMSR math in TypeScript using WAD-scaled (1e18) BigInt arithmetic — 20-term Taylor series with range reduction for exp(), Halley's method for ln(), and the log-sum-exp trick for overflow prevention — with no floating-point anywhere in the computation path.
- Built on-chain validation layer in LMSRLib.sol that verifies CRE-reported prices sum to 1e6 within 0.1% tolerance, enforces monotonic trade nonces to prevent replay, and computes max subsidy loss at market creation.
- Designed and deployed a hub-spoke cross-chain architecture using Chainlink CCIP with dual-path price propagation (CCIP messages and CRE direct writeReport calls), ensuring spoke markets maintain canonical price consistency with the hub.
- Engineered a 4-band canonical deviation policy engine (CanonicalPricingModule.sol) that classifies hub-spoke price divergence into Normal, Stress, Unsafe, and CircuitBreaker bands — progressively applying fee surcharges, output caps, direction restrictions, and full trading halts.
- Architected three independently deployed CRE workflows (15+ handlers across cron, HTTP, and EVM-log triggers) with isolated key sets, failure domains, and policy scopes — automating the full market lifecycle from AI-powered creation through resolution, dispute adjudication, and LP withdrawal processing.
- Designed a 6-layer agent delegation security model enabling AI agents to trade on behalf of users without custodial risk — layering HTTP key gates, EIP-712 session signatures, one-time Firestore approval consumption with nonce replay protection, execute policy allowlists, on-chain action-mask bitfield authorization, and router balance guards.
- Implemented gasless user operations via EIP-712 typed data signatures validated in CRE, enabling minting, trading, redeeming, and disputing without users paying gas.
- Built a cross-chain position bridge (PredictionMarketBridge.sol) supporting lock/mint/burn/unlock of outcome token claims via CCIP with replay protection and trusted-remote validation.

### FortuneFlip — Stable Token and On-Chain Raffle Engine

ERC-20 stable token pegged to ETH via Chainlink Price Feeds with an integrated raffle engine using Chainlink VRF for verifiable winner selection.

[github.com/0xHimxa/FortuneFlip](https://github.com/0xHimxa/FortuneFlip)

- Implemented an ERC-20 token with algorithmic ETH/USD price derivation via Chainlink Price Feeds, embedding asymmetric fee mechanics (10% buy / 15% sell at 100 basis point precision) directly into the transfer logic to fund protocol operations without external fee routers.
- Built a multi-round on-chain raffle engine with Chainlink VRF V2.5 for provably fair winner selection, implementing ticket-based entry with pooled token distribution and automated round lifecycle management via Chainlink Automation.
- Developed a comprehensive Foundry test suite covering unit, integration, and fuzz testing with multi-network deployment scripting (Anvil local, Sepolia testnet).

---

## Education

**Cyfrin Updraft** — Smart Contract Development Course | Completed 2025

**Cyfrin Updraft** — Smart Contract Security Course | In Progress

**Independent research** — AMM mechanism design, fixed-point arithmetic, and DeFi protocol security; applied directly in the CPMM-to-LMSR migration in GeoChain.
