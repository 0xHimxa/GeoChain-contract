# 🎬 GeoChain — 4-Minute Demo Video Guide

> **Target**: Chainlink Convergence Hackathon judges. **Time**: 4:00 flat. **Goal**: Show the problem, your solution, and a live demo that proves it works.

---

## Golden Rules

1. **Lead with the problem, not the tech** — judges fund solutions, not features
2. **Show, don't tell** — every claim needs a live screen moment
3. **CRE is your headline** — this is a Chainlink hackathon; CRE usage must be front-and-center
4. **Cut everything that isn't essential** — 4 minutes goes fast; rehearse and time yourself

---

## Timeline Breakdown

| Time | Section | Duration | What's On Screen |
|---|---|---|---|
| 0:00–0:30 | **Hook + Problem** | 30s | Slides or you speaking to camera |
| 0:30–1:15 | **Solution Overview** | 45s | Architecture diagram |
| 1:15–2:30 | **Live Demo — Core Flow** | 75s | Frontend + blockchain explorer |
| 2:30–3:15 | **Live Demo — Agent Trading** | 45s | AgentApp UI + CRE logs |
| 3:15–3:45 | **CRE + Chainlink Deep Moment** | 30s | Code / workflow / CCIP explorer |
| 3:45–4:00 | **Closing + What's Next** | 15s | You speaking / slide |

---

## Section-by-Section Script

### 1. Hook + Problem (0:00 – 0:30)

> **What to say (paraphrased — use your own voice):**
>
> "Prediction markets are a $X billion opportunity, but they're broken. In late 2025, whales manipulated Polymarket's oracle to force a false resolution. Markets are stuck on single chains with fragmented liquidity. And every operational step — creating markets, resolving them, syncing prices — requires a human watching a dashboard 24/7.
>
> We built GeoChain to fix all of this."

**Screen**: Can be you on camera, or a simple slide with the 3 problems listed as bullet points. Keep it visual and fast.

**Timing tip**: Practice this to exactly 30 seconds. Cut words ruthlessly.

---

### 2. Solution Overview (0:30 – 1:15)

> **What to say:**
>
> "GeoChain is an autonomous prediction market protocol built on Chainlink CRE. Let me walk you through the architecture.
>
> At the core, we have smart contracts deployed on Arbitrum Sepolia and Base Sepolia — a MarketFactory that creates prediction markets, a RouterVault that holds user funds and enables gasless trading, and a Bridge for cross-chain position portability.
>
> The magic is in the automation layer. We run TWO dedicated CRE workflows:
> - A **market-workflow** that handles the full market lifecycle — creating markets with Gemini AI, resolving them with AI-powered evidence evaluation, syncing prices across chains via CCIP, and monitoring liquidity.
> - An **agents-workflow** purpose-built for AI agent trading — with a plan-sponsor-execute pipeline and Gemini-powered autonomous trading decisions.
>
> Everything is connected through Chainlink CRE for automation, CCIP for cross-chain messaging, and ReceiverTemplateUpgradeable for secure on-chain report delivery."

**Screen**: Show your architecture diagram. Point at components as you speak. If possible, use a pre-made slide with arrows highlighting the data flow.

**Pre-make this diagram** — the ASCII ones from the README won't look great on video. Use Excalidraw, Figma, or even a labeled screenshot.

---

### 3. Live Demo — Core Flow (1:15 – 2:30)

This is the heart of the demo. Show a real transaction flow.

**Pre-setup checklist** (do these BEFORE recording):
- [ ] Frontend running locally (`bun run dev`)
- [ ] MetaMask connected to Arbitrum Sepolia with test funds
- [ ] At least one active market visible in the UI
- [ ] Have the blockchain explorer (Arbiscan Sepolia) open in another tab
- [ ] Have Firestore console open (optional — shows AI audit trail)

**Demo sequence:**

| Step | Action | What to say | Time |
|---|---|---|---|
| 1 | Show the market list in the UI | "Here's our frontend. You can see live prediction markets — each one was created automatically by our CRE workflow using Gemini AI to generate unique event ideas." | 10s |
| 2 | Click into a market, show YES/NO prices | "Each market has a constant-product AMM. Users can trade YES or NO outcome tokens. Prices are derived from the AMM reserves." | 10s |
| 3 | Do a trade — mint complete sets or swap | "Let me do a live trade. I'll mint some complete sets — this deposits USDC into the market and gives me both YES and NO tokens." → Execute the transaction | 20s |
| 4 | Show the transaction on Arbiscan | "Here's the confirmed transaction on Arbiscan. Fully on-chain, verified." | 5s |
| 5 | Show a resolved market | "This market was resolved automatically by CRE. Our workflow called Gemini AI, which evaluated the question with Google Search grounding, and delivered a signed resolution report on-chain." | 15s |
| 6 | (Optional) Show Firestore | "Every AI decision is stored in Firestore with the source URL and confidence score — a complete audit trail." | 10s |
| 7 | Show cross-chain (if time) | "And prices are synced to our Base Sepolia deployment via CCIP — same market, same canonical price, two chains." | 5s |

**Timing tip**: This is 75 seconds. Rehearse this flow 3–4 times. Pre-load all pages. Don't wait for transactions — if needed, pre-execute and show the result.

> [!TIP]
> **Pro move**: Pre-execute the transaction and have the Arbiscan confirmation ready in a background tab. Live transactions can fail or be slow on testnets. Show the flow in the UI, then switch to the "confirmed" tab.

---

### 4. Live Demo — Agent Trading (2:30 – 3:15)

This is your differentiator. No other hackathon project has this.

**Demo sequence:**

| Step | Action | What to say | Time |
|---|---|---|---|
| 1 | Switch to AgentApp UI | "Now here's what makes GeoChain truly agent-native. We have a dedicated agents-workflow — a separate CRE deployment just for AI trading." | 8s |
| 2 | Show the agent permission UI | "Users authorize an AI agent on-chain — they set which actions are allowed, a per-trade amount cap, and an expiration. Funds never leave the router." | 10s |
| 3 | Show the Plan step | "The agent calls our Plan endpoint to validate the trade intent against policy — action, chain, amount, slippage all checked." | 7s |
| 4 | Show the Sponsor step | "Then Sponsor — this reuses our session-signature verification. The same security path as human trades, no shortcuts." | 7s |
| 5 | Show the Execute step | "And Execute — the payload is built, the approval is consumed, and the report goes on-chain. Six security layers in total." | 8s |
| 6 | Mention Gemini auto-trade | "We also have a one-shot Gemini endpoint — you send market context and Gemini decides what to trade, then Plan-Sponsor-Execute runs automatically. The AI can also decide to hold." | 5s |

**Timing tip**: 45 seconds. You don't need to execute every step live — showing the UI and explaining the flow is enough. If you have time, trigger one real plan/execute.

---

### 5. CRE + Chainlink Deep Moment (3:15 – 3:45)

Judges want to see **real CRE usage**, not wrapper usage. Show the code.

> **What to say:**
>
> "Let me show you how deeply we integrate CRE. Here's our market-workflow main.ts — we compose cron triggers, HTTP triggers, and EVM log triggers into a single workflow graph. Each handler runs on Chainlink's decentralized infrastructure.
>
> Our contracts implement ReceiverTemplateUpgradeable — both MarketFactory and PredictionMarket have `_processReport` functions that decode CRE-delivered reports and execute actions like CreateMarket, ResolveMarket, or PriceCorrection.
>
> And our agents-workflow is a completely separate CRE deployment with its own authorized keys and config — operational automation and agent trading are isolated by design."

**Screen**: Show `main.ts` briefly (the workflow graph), then flash `_processReport` in the contract. Don't linger — 30 seconds total.

---

### 6. Closing (3:45 – 4:00)

> **What to say:**
>
> "GeoChain makes prediction markets autonomous, cross-chain, and agent-native — all powered by Chainlink CRE and CCIP. We're deployed on Arbitrum Sepolia and Base Sepolia today.
>
> Thanks for watching."

**Screen**: Final slide with project name, GitHub link, deployed chain logos.

---

## Pre-Recording Checklist

- [ ] **Frontend running** with markets loaded
- [ ] **MetaMask** on Arbitrum Sepolia with test USDC
- [ ] **Arbiscan tabs** pre-loaded with a confirmed tx and a resolved market
- [ ] **Architecture diagram** as an image (not ASCII)
- [ ] **Code tabs** pre-opened: `market-workflow/main.ts`, `agents-workflow/main.ts`, `_processReport` in `MarketFactoryOperations.sol`
- [ ] **Screen recording software** set to 1080p, good audio
- [ ] **Close notifications** — Slack, Discord, email, OS popups
- [ ] **Practice 3 full runs** — aim for 3:50 to leave buffer
- [ ] **Have a backup plan** if a testnet tx fails (pre-recorded fallback clip of the tx confirming)

---

## What to SKIP (not enough time)

- ❌ Detailed AMM math explanation
- ❌ Code walkthrough of every contract
- ❌ Full dispute mechanism demo
- ❌ Bridge demo (mention it, don't show it)
- ❌ Deployment instructions
- ❌ Test coverage discussion
- ❌ Security audit details

---

## Key Phrases to Hit (judges listen for these)

- "Built on **Chainlink CRE**"
- "Two dedicated **CRE workflows** — market automation and agent trading"
- "**ReceiverTemplateUpgradeable** for secure on-chain report delivery"
- "Cross-chain via **Chainlink CCIP**"
- "**Gemini AI** with Google Search grounding for resolution"
- "Fully autonomous — market creation, resolution, price sync, liquidity top-up"
- "Agent-native — **6-layer security**, non-custodial delegation"
- "Deployed on **Arbitrum Sepolia** and **Base Sepolia**"

---

## Recording Tips

| Tip | Why |
|---|---|
| **Record audio separately** if possible | Post-processing is easier; you can re-record voice without re-recording screen |
| **Use a script but don't read it** | Write notes per section, practice until natural |
| **Zoom your browser to 125–150%** | Text is hard to read in screen recordings |
| **Use dark mode** everywhere | Looks more polished and professional |
| **Mouse movements should be slow and deliberate** | Fast mouse = confusing |
| **Edit out dead time** | Cut pauses, loading screens, waiting for tx confirmation |
| **Add a 2-second title card** at the start | "GeoChain — Autonomous Prediction Markets" |

---

## Bare Minimum If You're Short on Time

If you can't hit everything above, prioritize in this order:

1. **Problem statement** (30s) — without this, judges don't care about the solution
2. **Live trade on the UI** (30s) — proves it's real
3. **CRE workflow code** (20s) — proves CRE integration is meaningful
4. **Agent trading mention** (20s) — your differentiator
5. **Architecture slide** (20s) — shows the scope
6. **Closing** (10s)

That's 2:30 — leaves 1:30 of buffer for a relaxed pace.

---

*Good luck! 🚀*
