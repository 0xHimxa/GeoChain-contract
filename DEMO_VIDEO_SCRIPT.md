# GeoChain Demo Video — Complete Production Guide

> **Chainlink Convergence 2026 Hackathon**
> Runtime: 3 minutes 30 seconds · Everything you need is in this file.

---

## 🎬 Before You Record

### Setup Checklist

```
[ ] Screen recorder installed and set to 1080p (OBS, Loom, or QuickTime)
[ ] Microphone tested — record 10 seconds and play back
[ ] Browser open with frontend running (npm run dev in frontend/minimal-sponsor-ui)
[ ] MetaMask installed with Arbitrum Sepolia selected
[ ] MetaMask has testnet USDC (at least 10 USDC)
[ ] At least 2-3 active markets visible in the app
[ ] Browser local wallet cleared (fresh demo — clear localStorage)
[ ] A second browser tab open to https://sepolia.arbiscan.io
[ ] Browser zoom set to 110-125% so text is readable on video
[ ] Close all notifications, Slack, Discord — clean screen
[ ] This script open on a second monitor or printed out
```

### Screen Layout

```
┌──────────────────────────────────────────────────────┐
│                                                      │
│   Your browser (GeoChain frontend) — FULL SCREEN     │
│   at 110-125% zoom                                   │
│                                                      │
│   Keep Arbiscan tab ready but not visible yet         │
│                                                      │
└──────────────────────────────────────────────────────┘

Second monitor (not recorded):
 → This script
 → Notes / timer
```

---

# THE VIDEO

---

## SCENE 1 — Title Card (5 seconds)

### What to show on screen
Open a blank browser tab or use any simple text editor and display:

```
╔══════════════════════════════════════════════════════════╗
║                                                          ║
║                      G E O C H A I N                     ║
║                                                          ║
║     Cross-Chain Prediction Markets Powered by            ║
║     Chainlink CRE                                        ║
║                                                          ║
║     Chainlink Convergence Hackathon 2026                 ║
║                                                          ║
╚══════════════════════════════════════════════════════════╝
```

> **TIP:** You can create this as a simple HTML page with large centered text on a dark background, or just type it in VS Code with a large font. Keep it on screen for 5 seconds while you start talking.

### What to say
> *"This is GeoChain — a cross-chain prediction market protocol powered by Chainlink CRE."*

---

## SCENE 2 — The Problem (25 seconds)

### What to show on screen
Stay on the title screen or switch to a text/slide showing the problem. You can display this in VS Code or a simple HTML page:

```
╔══════════════════════════════════════════════════════════╗
║  THE PROBLEM WITH PREDICTION MARKETS TODAY               ║
║                                                          ║
║  For Users:                                              ║
║  ✗ Need a crypto wallet + seed phrase just to start      ║
║  ✗ Gasless solutions depend on AA bundlers (extra         ║
║    infra, latency, cost)                                 ║
║  ✗ Funds stuck on one chain, no fiat onramp              ║
║                                                          ║
║  For Operators:                                          ║
║  ✗ 5-6 separate backend services to keep markets alive   ║
║  ✗ Prices drift between chains with no sync              ║
║  ✗ Liquidity runs out, markets break silently             ║
║  ✗ Each service fails independently                      ║
║                                                          ║
╚══════════════════════════════════════════════════════════╝
```

### What to say
> *"Prediction markets today still have a broken onboarding and operations model. Users need a crypto wallet and seed phrase just to participate. Even platforms with gasless trading rely on Account Abstraction bundlers — Pimlico, Stackup — which add infrastructure, latency, cost, and another service that can fail.*
>
> *For operators, it's worse. You need five or six separate backend services — a relayer, cron jobs, event listeners, cross-chain sync scripts — all failing independently. We built GeoChain to eliminate all of that. Users sign in with email and password — Web2 style — and CRE sponsors execution directly, no bundler needed."*

---

## SCENE 3 — Architecture Diagram (30 seconds)

### What to show on screen
Display this architecture diagram. You can show it in VS Code, a markdown preview, or create a simple slide:

```
╔══════════════════════════════════════════════════════════╗
║                    HOW GEOCHAIN WORKS                    ║
║                                                          ║
║  ┌──────────────────────────────────────────────────┐    ║
║  │              FRONTEND (React App)                │    ║
║  │   • Session wallet (zero gas trading)            │    ║
║  │   • Multi-chain (Arbitrum + Base)                │    ║
║  │   • Fiat / ETH / USDC funding                   │    ║
║  └────────────────────┬─────────────────────────────┘    ║
║                       │ HTTP triggers                    ║
║  ┌────────────────────▼─────────────────────────────┐    ║
║  │         CHAINLINK CRE WORKFLOW (1 runtime)       │    ║
║  │                                                  │    ║
║  │   CRON: Market creation (Gemini AI)              │    ║
║  │   CRON: Cross-chain price sync                   │    ║
║  │   CRON: Arbitrage correction                     │    ║
║  │   CRON: Auto-resolution                          │    ║
║  │   CRON: Liquidity top-ups                        │    ║
║  │   CRON: Withdrawal processing                    │    ║
║  │   HTTP: Sponsor policy (approve)                 │    ║
║  │   HTTP: Execute report (consume + write)         │    ║
║  │   HTTP: Fiat credit                              │    ║
║  │   LOG:  ETH deposit credit                       │    ║
║  │                                                  │    ║
║  │   13 handlers · 3 trigger types · 1 workflow     │    ║
║  └────────────────────┬─────────────────────────────┘    ║
║                       │ On-chain reports                 ║
║  ┌────────────────────▼─────────────────────────────┐    ║
║  │        SMART CONTRACTS (Multi-Chain EVM)          │    ║
║  │                                                  │    ║
║  │   Arbitrum Sepolia (HUB)  ◄── CCIP ──►  Base     │    ║
║  │   • MarketFactory                    (SPOKE)     │    ║
║  │   • PredictionMarket (AMM)                       │    ║
║  │   • Router Vault (user credits)                  │    ║
║  │   • Canonical Pricing Module                     │    ║
║  └──────────────────────────────────────────────────┘    ║
║                                                          ║
╚══════════════════════════════════════════════════════════╝
```

### What to say
> *"GeoChain has three layers. At the top, a React frontend where users trade with zero gas using a browser-local session wallet.*
>
> *In the middle — this is the key — one single Chainlink CRE workflow with 13 handlers. It replaces all those backend services. Cron triggers handle market creation using Gemini AI, cross-chain price synchronization, arbitrage correction, auto-resolution, liquidity top-ups, and withdrawal processing. HTTP triggers handle sponsored trade execution and funding. EVM log triggers handle ETH deposit crediting.*
>
> *At the bottom, Solidity smart contracts deployed on Arbitrum Sepolia as the hub and Base Sepolia as the spoke, connected via Chainlink CCIP."*

---

## SCENE 4 — Live Demo: Sign In (15 seconds)

### What to show on screen
Switch to the **GeoChain frontend** in your browser.

### Step-by-step screen actions
1. **Point your mouse** at the top header that says "Prediction Market Console"
2. Type a name in the **Name** field (e.g., "Demo User")
3. Type an email in the **Email** field (e.g., "demo@geochain.io")
4. Type a password in the **Password** field (at least 8 characters)
5. Click **"Sign In + Unlock Local Wallet"**
6. **Wait** — the wallet hint should update to show "Active local wallet: 0x..."

### What to say
> *"Let me show you the user experience. I sign in with email and password — Web2 onboarding. Behind the scenes, it creates a browser-local encrypted wallet. No MetaMask extension, no seed phrase, no AA bundler. This wallet signs trade intents locally, and CRE sponsors the execution on-chain."*

---

## SCENE 5 — Live Demo: Show Markets (15 seconds)

### What to show on screen
You should now be on the **Markets** page. Markets should be visible in the left panel.

### Step-by-step screen actions
1. **Point your mouse** at the active markets in the left panel
2. **Click on a market** to select it
3. **Point** at the YES/NO price display on the right
4. **Point** at the close time and resolution time

### What to say
> *"These markets were created automatically by our CRE workflow. Every 30 seconds, CRE pulls trending events, uses Gemini AI to generate unique market questions, and deploys them to both Arbitrum and Base simultaneously. You can see live YES and NO probabilities from the on-chain AMM, and the close and resolution times."*

---

## SCENE 6 — Live Demo: Fund the Vault (20 seconds)

### What to show on screen
Click the **"Deposit"** tab in the navigation.

### Step-by-step screen actions
1. Click **"Deposit"** in the top nav bar
2. Click **"Connect MetaMask"** — MetaMask popup appears → approve connection
3. Type **"5"** in the USDC amount field
4. Click **"DepositFor Local Wallet"**
5. MetaMask popup appears → confirm the transaction
6. **Wait for confirmation** — vault balance should update

### What to say
> *"I fund my vault — here I'm using MetaMask to deposit USDC, but users can also pay with fiat through Google Pay or card, or send ETH directly to the router contract. All three funding sources go through CRE handlers with replay protection, and they all credit the same unified vault. No bundler infrastructure involved."*

---

## SCENE 7 — Live Demo: Execute a Sponsored Trade (30 seconds)

### What to show on screen
Click back to the **"Markets"** tab.

### Step-by-step screen actions
1. Click **"Markets"** in the top nav
2. **Select an active market** from the left panel
3. In the action dropdown, select **"mintCompleteSets"** (or **"swapYesForNo"**)
4. Type **"1"** in the amount field
5. Click **"Sign + Submit Action"**
6. **Wait** — watch the log output at the bottom update with the response
7. **Point** at the position display showing your YES/NO token balances

### What to say
> *"Now the core flow. I select a market, choose an action — let's mint complete sets for 1 USDC — and click one button.*
>
> *Here's what's different from other gasless platforms. There is no Account Abstraction bundler in this pipeline. My local wallet signs the trade intent. CRE's sponsor policy handler validates the session, checks action allowlists, verifies amount limits, and writes a one-time approval. Then the execute handler consumes that approval exactly once and submits the on-chain report directly.*
>
> *No bundler queue, no UserOp mempool, no Paymaster contract. CRE IS the execution infrastructure. That's the key difference."*

---

## SCENE 8 — CRE Automation Behind the Scenes (30 seconds)

### What to show on screen
You have two options here — pick whichever you've prepared:

**Option A: Show the CRE code**
Open `cre/market-workflow/main.ts` in VS Code and scroll through the handler registrations.

**Option B: Show this diagram**
Display this in VS Code or markdown preview:

```
╔══════════════════════════════════════════════════════════╗
║          CRE AUTOMATED OPERATIONS (every 30 sec)         ║
║                                                          ║
║  ┌─────────────────────────────────────────────────┐     ║
║  │                                                 │     ║
║  │  📄 Market Creation                             │     ║
║  │     Firestore events + Gemini AI → deploy to    │     ║
║  │     ALL chains simultaneously                   │     ║
║  │                                                 │     ║
║  │  📊 Price Sync                                  │     ║
║  │     Read hub AMM prices → push to all spokes    │     ║
║  │     with 15-min validity windows                │     ║
║  │                                                 │     ║
║  │  ⚖️  Arbitrage Correction                       │     ║
║  │     Detect unsafe price deviation → auto-fix    │     ║
║  │     with bounded spend limits                   │     ║
║  │                                                 │     ║
║  │  ✅ Auto-Resolution                             │     ║
║  │     Check resolution time → submit resolve      │     ║
║  │     report → no human operator needed           │     ║
║  │                                                 │     ║
║  │  💰 Liquidity Top-Up                            │     ║
║  │     Monitor factory/bridge/router balances      │     ║
║  │     → auto-mint USDC when below 50K threshold   │     ║
║  │                                                 │     ║
║  │  🏦 Withdrawal Processing                      │     ║
║  │     Drain post-resolution queues in batches     │     ║
║  │                                                 │     ║
║  └─────────────────────────────────────────────────┘     ║
║                                                          ║
║  All 6 jobs = 1 CRE workflow (not 6 separate services)   ║
║                                                          ║
╚══════════════════════════════════════════════════════════╝
```

### What to say
> *"What makes GeoChain different from other projects is what's running in the background without any human intervention.*
>
> *Our CRE workflow runs every 30 seconds. It creates new markets using Gemini AI. It syncs canonical prices from the hub chain to all spoke chains. It auto-corrects unsafe price deviations with bounded arbitrage trades. It resolves markets when their resolution time passes. It monitors collateral balances and mints fresh USDC when they drop below threshold. And it processes withdrawal queues after resolution.*
>
> *Normally this would be six separate cron jobs, each with its own deployment and failure mode. We have one CRE workflow."*

---

## SCENE 9 — Cross-Chain & Security (20 seconds)

### What to show on screen
Display this diagram or switch to Arbiscan to show deployed contracts:

```
╔══════════════════════════════════════════════════════════╗
║              CROSS-CHAIN HUB-SPOKE DESIGN                ║
║                                                          ║
║   Arbitrum Sepolia (HUB)          Base Sepolia (SPOKE)   ║
║   ┌──────────────────┐           ┌──────────────────┐    ║
║   │ MarketFactory    │◄── CCIP ──►│ MarketFactory    │    ║
║   │ 0x145A...918Ec   │  price +  │ 0x54DD...8651    │    ║
║   │                  │ resolution│                  │    ║
║   │ Router Vault     │   sync    │ Router Vault     │    ║
║   │ 0x3E62...94A8   │           │ 0x1381...D525    │    ║
║   └──────────────────┘           └──────────────────┘    ║
║                                                          ║
║   Security:                                              ║
║   • Session auth (EIP-712 signatures)                    ║
║   • One-time approval consumption (no replay)            ║
║   • Canonical pricing deviation bands                    ║
║   • Risk exposure caps (10K USDC per user)               ║
║   • Market allowlisting in Router                        ║
║                                                          ║
╚══════════════════════════════════════════════════════════╝
```

### What to say
> *"We're deployed on two chains — Arbitrum Sepolia as the hub and Base Sepolia as the spoke — connected through Chainlink CCIP for price and resolution sync.*
>
> *Security is layered. CRE enforces session signatures, one-time approval consumption, and policy limits. On-chain, canonical pricing deviation bands restrict or halt trading when spoke prices drift too far from the hub. Every funding source has replay protection."*

---

## SCENE 10 — Closing (10 seconds)

### What to show on screen
Display the closing card:

```
╔══════════════════════════════════════════════════════════╗
║                                                          ║
║                      G E O C H A I N                     ║
║                                                          ║
║   "We replaced 5 backend services with 1 CRE workflow   ║
║    — making prediction markets self-operating,           ║
║    cross-chain, and zero-gas for users."                 ║
║                                                          ║
║   13 handlers · 3 trigger types · 2 chains · 1 workflow  ║
║                                                          ║
║   Built for Chainlink Convergence 2026                   ║
║                                                          ║
╚══════════════════════════════════════════════════════════╝
```

### What to say
> *"GeoChain is a self-operating prediction market protocol. We used Chainlink CRE as the operational backbone — not as an add-on, but as the system that makes everything work. Thank you."*

---

# TIMING SUMMARY

| Scene | Duration | Running Total | What's On Screen |
|---|---|---|---|
| 1. Title card | 5 sec | 0:05 | Project name + hackathon |
| 2. Problem | 25 sec | 0:30 | Problem statement text |
| 3. Architecture | 30 sec | 1:00 | Architecture diagram |
| 4. Sign in | 15 sec | 1:15 | Frontend — sign in flow |
| 5. Markets | 15 sec | 1:30 | Frontend — market list + prices |
| 6. Fund vault | 20 sec | 1:50 | Frontend — MetaMask deposit |
| 7. Sponsored trade | 30 sec | 2:20 | Frontend — trade + position update |
| 8. CRE automation | 30 sec | 2:50 | Code or automation diagram |
| 9. Cross-chain | 20 sec | 3:10 | Cross-chain diagram + security |
| 10. Closing | 10 sec | 3:20 | Closing card |
| **Buffer** | **10 sec** | **3:30** | — |

---

# QUICK REFERENCE: What You Need Open

```
Tab 1: GeoChain Frontend        → http://localhost:5173
Tab 2: Arbiscan                  → https://sepolia.arbiscan.io
Tab 3: VS Code with main.ts     → cre/market-workflow/main.ts (optional)

Second monitor: This script

MetaMask: Arbitrum Sepolia selected, has testnet USDC
```

---

# IF SOMETHING GOES WRONG

| Problem | Fix |
|---|---|
| Markets not loading | Refresh the page, check console for RPC errors |
| MetaMask on wrong chain | Manually switch to Arbitrum Sepolia (Chain ID 421614) |
| Transaction takes too long | Pause recording, wait, resume. Edit out the wait later |
| Vault balance not updating | Click to another tab and back, or wait 15 seconds for auto-refresh |
| Frontend won't start | Run `cd frontend/minimal-sponsor-ui && npm run dev` |
| No markets visible | The CRE workflow may not have created any yet. Use the mock server: `bun run server.ts` |
| Sign-in fails | Check that password is at least 8 characters |

---

# RECORDING TIPS

1. **Do a dry run first** — practice the whole flow once without recording
2. **Speak slowly** — judges need to process what you're saying while reading the screen
3. **Move your mouse deliberately** — point at things you're talking about
4. **Pause 1 second** between scenes — gives you clean edit points
5. **If you mess up a line** — pause, take a breath, say it again. Edit out the mistake later
6. **Keep your voice confident** — you built something real, own it
