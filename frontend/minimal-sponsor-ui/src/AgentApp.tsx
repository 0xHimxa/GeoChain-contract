import { useCallback, useEffect, useMemo, useState } from "react";
import { BrowserProvider, Contract, SigningKey, TypedDataEncoder, Wallet, keccak256, parseUnits, toUtf8Bytes, type Eip1193Provider } from "ethers";
import {
  agentExecute,
  agentPlan,
  agentRevoke,
  agentSponsor,
  type AgentAction,
  type SessionAuthorizationPayload,
} from "./api-agent";
import { CHAIN_CONFIG, MARKET_FACTORY_ABI, ROUTER_ABI, loadMarketSnapshot, providerForChain, type SupportedChainId } from "./chain";
import { createOrLoadWallet, getStoredWalletMeta } from "./keyVault";
import type { MarketEvent } from "./types";

type AgentMaskItem = {
  bit: number;
  action: AgentAction;
  label: string;
};

const AGENT_MASK_ITEMS: AgentMaskItem[] = [
  { bit: 0, action: "mintCompleteSets", label: "mintCompleteSets" },
  { bit: 1, action: "redeemCompleteSets", label: "redeemCompleteSets" },
  { bit: 2, action: "swapYesForNo", label: "swapYesForNo" },
  { bit: 3, action: "swapNoForYes", label: "swapNoForYes" },
  { bit: 4, action: "addLiquidity", label: "addLiquidity" },
  { bit: 5, action: "removeLiquidity", label: "removeLiquidity" },
  { bit: 6, action: "redeem", label: "redeem" },
  { bit: 7, action: "disputeProposedResolution", label: "disputeProposedResolution" },
];

const ACTION_TYPE_BY_ACTION: Record<AgentAction, string> = {
  mintCompleteSets: "routerAgentMintCompleteSets",
  redeemCompleteSets: "routerAgentRedeemCompleteSets",
  swapYesForNo: "routerAgentSwapYesForNo",
  swapNoForYes: "routerAgentSwapNoForYes",
  addLiquidity: "routerAgentAddLiquidity",
  removeLiquidity: "routerAgentRemoveLiquidity",
  redeem: "routerAgentRedeem",
  disputeProposedResolution: "routerAgentDisputeProposedResolution",
};

const CHAIN_HEX: Record<SupportedChainId, string> = {
  84532: "0x14a34",
  421614: "0x66eee",
};

const marketStateTone: Record<MarketEvent["state"], string> = {
  open: "text-mint-400",
  closed: "text-gold-400",
  review: "text-amber-300",
  resolved: "text-rose-400",
};

const isHexAddress = (value: string): boolean => /^0x[a-fA-F0-9]{40}$/.test(value);
const formatDateTime = (unix: number): string => new Date(unix * 1000).toLocaleString();

const effectiveMarketState = (event: MarketEvent, nowUnix: number): MarketEvent["state"] => {
  if (event.state === "resolved") return "resolved";
  if (event.state === "review") return "review";
  if (event.resolutionOutcome) return "resolved";
  if (nowUnix >= event.closeTimeUnix) return "closed";
  return event.state;
};

const toUsdcRaw = (value: string): string => parseUnits(value || "0", 6).toString();
const SESSION_DOMAIN_NAME = "CRE Session Authorization";
const SESSION_DOMAIN_VERSION = "1";

export function AgentApp() {
  const [selectedChain, setSelectedChain] = useState<SupportedChainId>(84532);
  const [walletPassword, setWalletPassword] = useState("");
  const [walletAddress, setWalletAddress] = useState("");
  const [walletPrivateKey, setWalletPrivateKey] = useState("");
  const [connectedWalletAddress, setConnectedWalletAddress] = useState("");
  const [walletHint, setWalletHint] = useState(() => {
    const meta = getStoredWalletMeta();
    return meta ? `Stored wallet found: ${meta.address}` : "No local wallet loaded.";
  });

  const [events, setEvents] = useState<MarketEvent[]>([]);
  const [selectedEventId, setSelectedEventId] = useState("");

  const [userAddress, setUserAddress] = useState("");
  const [agentAddress, setAgentAddress] = useState("");
  const [action, setAction] = useState<AgentAction>("mintCompleteSets");
  const [amountUsdcInput, setAmountUsdcInput] = useState("10");
  const [slippageBps, setSlippageBps] = useState("120");
  const [proposedOutcome, setProposedOutcome] = useState<"1" | "2" | "3">("1");
  const [lastApprovalId, setLastApprovalId] = useState("");

  const [selectedMaskBits, setSelectedMaskBits] = useState<number[]>([0, 2]);
  const [maxAmountPerAction, setMaxAmountPerAction] = useState("100");
  const [expiresInHours, setExpiresInHours] = useState("24");

  const [nowUnix, setNowUnix] = useState<number>(Math.floor(Date.now() / 1000));
  const [busy, setBusy] = useState(false);
  const [logLine, setLogLine] = useState("Waiting for agent action...");

  const actionMask = useMemo(() => selectedMaskBits.reduce((acc, bit) => acc | (1 << bit), 0), [selectedMaskBits]);

  const groupedEvents = useMemo(() => {
    const active: MarketEvent[] = [];
    const closed: MarketEvent[] = [];
    const review: MarketEvent[] = [];
    const resolved: MarketEvent[] = [];
    for (const item of events) {
      const state = effectiveMarketState(item, nowUnix);
      if (state === "open") active.push(item);
      else if (state === "closed") closed.push(item);
      else if (state === "review") review.push(item);
      else resolved.push(item);
    }
    return { active, closed, review, resolved };
  }, [events, nowUnix]);

  const selectedEvent = useMemo(
    () => events.find((item) => item.id === selectedEventId) || events[0] || null,
    [events, selectedEventId]
  );

  const loadMarkets = useCallback(async () => {
    const provider = providerForChain(selectedChain);
    const factory = new Contract(CHAIN_CONFIG[selectedChain].addresses.marketFactory, MARKET_FACTORY_ABI, provider);
    const [activeEventList, marketCountRaw] = await Promise.all([
      factory.getActiveEventList().catch(() => []),
      factory.marketCount().catch(() => 0n),
    ]);

    const marketCount = Number(marketCountRaw || 0n);
    const indexedMarkets =
      marketCount > 0
        ? await Promise.all(Array.from({ length: marketCount }, (_, index) => factory.marketById(BigInt(index + 1)).catch(() => null)))
        : [];

    const marketAddresses = [...new Set([...(activeEventList as string[]), ...indexedMarkets.filter(Boolean)].map((value) => String(value).toLowerCase()))];

    const snapshots = await Promise.all(
      marketAddresses.map(async (address) => ({
        address,
        snapshot: await loadMarketSnapshot(selectedChain, address).catch(() => null),
      }))
    );

    const nextEvents = snapshots
      .map((item) => item.snapshot)
      .filter((item): item is MarketEvent => item !== null)
      .sort((a, b) => a.closeTimeUnix - b.closeTimeUnix);

    setEvents(nextEvents);
    setSelectedEventId((current) => (current && nextEvents.some((item) => item.id === current) ? current : nextEvents[0]?.id || ""));
  }, [selectedChain]);

  useEffect(() => {
    const timer = setInterval(() => setNowUnix(Math.floor(Date.now() / 1000)), 1000);
    return () => clearInterval(timer);
  }, []);

  useEffect(() => {
    loadMarkets().catch((error) => setLogLine(`Load markets failed: ${String(error)}`));
  }, [loadMarkets]);

  useEffect(() => {
    const timer = setInterval(() => {
      loadMarkets().catch(() => undefined);
    }, 15000);
    return () => clearInterval(timer);
  }, [loadMarkets]);

  const toggleMaskBit = (bit: number) => {
    setSelectedMaskBits((prev) => (prev.includes(bit) ? prev.filter((value) => value !== bit) : [...prev, bit].sort((a, b) => a - b)));
  };

  const ensureWallet = async () => {
    const session = await createOrLoadWallet(walletPassword);
    setWalletAddress(session.address);
    setWalletPrivateKey(session.privateKey || "");
    setWalletHint(`Active local wallet: ${session.address}`);
    if (!userAddress) setUserAddress(session.address);
    if (!agentAddress) setAgentAddress(session.address);
    return session;
  };

  const getFundingProvider = () => {
    const ethereum = (window as Window & { ethereum?: Eip1193Provider }).ethereum;
    if (!ethereum) throw new Error("No external wallet found. Install MetaMask.");
    return new BrowserProvider(ethereum);
  };

  const getExternalSigner = async () => {
    const provider = getFundingProvider();
    await provider.send("eth_requestAccounts", []);
    await provider.send("wallet_switchEthereumChain", [{ chainId: CHAIN_HEX[selectedChain] }]);
    return provider.getSigner();
  };

  const recoverPublicKeyFromExternalSigner = async (
    signer: Awaited<ReturnType<typeof getExternalSigner>>,
    owner: string,
    chainId: number
  ): Promise<string> => {
    const domain = {
      name: SESSION_DOMAIN_NAME,
      version: SESSION_DOMAIN_VERSION,
      chainId,
    };
    const types = {
      SessionPubKeyProbe: [
        { name: "owner", type: "address" },
        { name: "nonce", type: "string" },
      ],
    };
    const message = {
      owner,
      nonce: `probe_${Date.now()}_${Math.random().toString(36).slice(2, 10)}`,
    };
    const signature = await signer.signTypedData(domain, types, message);
    const digest = TypedDataEncoder.hash(domain, types, message);
    const publicKey = SigningKey.recoverPublicKey(digest, signature);
    if (!/^0x04[a-fA-F0-9]{128}$/.test(publicKey)) {
      throw new Error("failed to recover uncompressed public key from connected wallet");
    }
    return publicKey;
  };

  const buildPhasePayloads = () => {
    if (!selectedEvent) throw new Error("Select an event first");
    if (!isHexAddress(userAddress)) throw new Error("user address invalid");
    if (!isHexAddress(agentAddress)) throw new Error("agent address invalid");

    const amountRaw = action === "disputeProposedResolution" ? "0" : toUsdcRaw(amountUsdcInput.trim());
    const slippage = Number(slippageBps);
    if (!Number.isInteger(slippage) || slippage < 0) throw new Error("slippageBps invalid");

    const requestId = `agent_req_${Date.now()}`;
    const plan = {
      requestId,
      chainId: selectedChain,
      sender: userAddress,
      user: userAddress,
      agent: agentAddress,
      market: selectedEvent.marketAddress,
      action,
      amountUsdc: amountRaw,
      slippageBps: slippage,
      yesIn: action === "swapYesForNo" ? amountRaw : undefined,
      minNoOut: action === "swapYesForNo" ? "0" : undefined,
      noIn: action === "swapNoForYes" ? amountRaw : undefined,
      minYesOut: action === "swapNoForYes" ? "0" : undefined,
      yesAmount: action === "addLiquidity" ? amountRaw : undefined,
      noAmount: action === "addLiquidity" ? amountRaw : undefined,
      minShares: action === "addLiquidity" ? "0" : undefined,
      shares: action === "removeLiquidity" ? amountRaw : undefined,
      proposedOutcome: action === "disputeProposedResolution" ? Number(proposedOutcome) : undefined,
    };

    const sponsor = {
      ...plan,
    };

    const execute = {
      ...plan,
      approvalId: lastApprovalId,
    };

    return { plan, sponsor, execute, amountRaw };
  };

  const buildSessionAuthorization = async (input: {
    requestId: string;
    chainId: number;
    action: AgentAction;
    amountUsdcRaw: string;
    slippageBps: number;
    sender: string;
  }): Promise<SessionAuthorizationPayload> => {
    const localSessionSigner = walletPrivateKey ? new Wallet(walletPrivateKey) : null;
    let ownerAddress = "";
    let externalOwnerSigner: Awaited<ReturnType<typeof getExternalSigner>> | null = null;
    let sessionPublicKey = "";
    let requestSignature = "";

    if (localSessionSigner && localSessionSigner.address.toLowerCase() === input.sender.toLowerCase()) {
      ownerAddress = localSessionSigner.address;
      sessionPublicKey = localSessionSigner.signingKey.publicKey;
    } else {
      externalOwnerSigner = await getExternalSigner();
      ownerAddress = await externalOwnerSigner.getAddress();
      setConnectedWalletAddress(ownerAddress);
      if (ownerAddress.toLowerCase() !== input.sender.toLowerCase()) {
        throw new Error("connected wallet must match sender for session validation");
      }
      if (localSessionSigner) {
        sessionPublicKey = localSessionSigner.signingKey.publicKey;
      } else {
        sessionPublicKey = await recoverPublicKeyFromExternalSigner(externalOwnerSigner, ownerAddress, input.chainId);
      }
    }

    const sessionId = `sess_${ownerAddress.slice(2, 10)}_${Date.now()}`;
    const requestNonce = `nonce_${Date.now()}_${Math.random().toString(36).slice(2, 10)}`;
    const expiresAtUnix = Math.floor(Date.now() / 1000) + 3600;
    const maxAmountUsdc = "10000000000";
    const allowedActions = AGENT_MASK_ITEMS.map((item) => item.action);
    const allowedActionsHash = keccak256(toUtf8Bytes([...allowedActions].sort().join(",")));

    const typedDomain = {
      name: SESSION_DOMAIN_NAME,
      version: SESSION_DOMAIN_VERSION,
      chainId: input.chainId,
    };

    const sessionGrantTypes = {
      SessionGrant: [
        { name: "sessionId", type: "string" },
        { name: "owner", type: "address" },
        { name: "sessionPublicKey", type: "bytes" },
        { name: "chainId", type: "uint256" },
        { name: "allowedActionsHash", type: "bytes32" },
        { name: "maxAmountUsdc", type: "uint256" },
        { name: "expiresAtUnix", type: "uint256" },
      ],
    };

    const sponsorIntentTypes = {
      SponsorIntent: [
        { name: "requestId", type: "string" },
        { name: "sessionId", type: "string" },
        { name: "requestNonce", type: "string" },
        { name: "chainId", type: "uint256" },
        { name: "action", type: "string" },
        { name: "amountUsdc", type: "uint256" },
        { name: "slippageBps", type: "uint256" },
        { name: "sender", type: "address" },
      ],
    };

    let grantSignature = "";
    if (localSessionSigner && localSessionSigner.address.toLowerCase() === ownerAddress.toLowerCase()) {
      grantSignature = await localSessionSigner.signTypedData(typedDomain, sessionGrantTypes, {
        sessionId,
        owner: ownerAddress,
        sessionPublicKey,
        chainId: input.chainId,
        allowedActionsHash,
        maxAmountUsdc,
        expiresAtUnix,
      });
    } else {
      if (!externalOwnerSigner) throw new Error("connected wallet is required for owner session grant signature");
      grantSignature = await externalOwnerSigner.signTypedData(typedDomain, sessionGrantTypes, {
        sessionId,
        owner: ownerAddress,
        sessionPublicKey,
        chainId: input.chainId,
        allowedActionsHash,
        maxAmountUsdc,
        expiresAtUnix,
      });
    }

    if (localSessionSigner) {
      requestSignature = await localSessionSigner.signTypedData(typedDomain, sponsorIntentTypes, {
        requestId: input.requestId,
        sessionId,
        requestNonce,
        chainId: input.chainId,
        action: input.action,
        amountUsdc: input.amountUsdcRaw,
        slippageBps: input.slippageBps,
        sender: input.sender,
      });
    } else {
      if (!externalOwnerSigner) throw new Error("connected wallet is required for session request signature");
      requestSignature = await externalOwnerSigner.signTypedData(typedDomain, sponsorIntentTypes, {
        requestId: input.requestId,
        sessionId,
        requestNonce,
        chainId: input.chainId,
        action: input.action,
        amountUsdc: input.amountUsdcRaw,
        slippageBps: input.slippageBps,
        sender: input.sender,
      });
    }

    return {
      sessionId,
      owner: ownerAddress,
      sessionPublicKey,
      chainId: input.chainId,
      allowedActions,
      maxAmountUsdc,
      expiresAtUnix,
      grantSignature,
      requestNonce,
      requestSignature,
    };
  };

  const onLoadLocalWallet = async () => {
    setBusy(true);
    try {
      const session = await ensureWallet();
      setLogLine(`Local wallet ready: ${session.address}`);
    } catch (error) {
      setLogLine(`Load wallet failed: ${String(error)}`);
    } finally {
      setBusy(false);
    }
  };

  const onUseConnectedWalletAsUser = async () => {
    setBusy(true);
    try {
      const signer = await getExternalSigner();
      const signerAddress = await signer.getAddress();
      setConnectedWalletAddress(signerAddress);
      setUserAddress(signerAddress);
      setLogLine(`Connected wallet set as user: ${signerAddress}`);
    } catch (error) {
      setLogLine(`Connect wallet failed: ${String(error)}`);
    } finally {
      setBusy(false);
    }
  };

  const onSetAgentPermission = async () => {
    setBusy(true);
    try {
      if (!isHexAddress(userAddress)) throw new Error("user address invalid");
      if (!isHexAddress(agentAddress)) throw new Error("agent address invalid");
      if (actionMask === 0) throw new Error("select at least one action bit");

      const maxAmountRaw = parseUnits(maxAmountPerAction || "0", 6);
      if (maxAmountRaw <= 0n) throw new Error("max amount must be > 0");

      const hours = Number(expiresInHours);
      if (!Number.isFinite(hours) || hours <= 0) throw new Error("expiresInHours must be > 0");
      const expiresAt = BigInt(Math.floor(Date.now() / 1000) + Math.floor(hours * 3600));

      const provider = getFundingProvider();
      await provider.send("wallet_switchEthereumChain", [{ chainId: CHAIN_HEX[selectedChain] }]);
      const signer = await provider.getSigner();
      const signerAddress = await signer.getAddress();

      const router = new Contract(CHAIN_CONFIG[selectedChain].addresses.router, ROUTER_ABI, signer);
      const tx = await router.setAgentPermission(agentAddress, actionMask, maxAmountRaw, expiresAt);
      const receipt = await tx.wait();

      setLogLine(
        JSON.stringify(
          {
            step: "setAgentPermission",
            chainId: selectedChain,
            signer: signerAddress,
            user: userAddress,
            router: CHAIN_CONFIG[selectedChain].addresses.router,
            txHash: tx.hash,
            receiptStatus: receipt?.status,
            actionMask,
            maxAmountPerAction: maxAmountRaw.toString(),
            expiresAt: expiresAt.toString(),
          },
          null,
          2
        )
      );
    } catch (error) {
      setLogLine(`setAgentPermission failed: ${String(error)}`);
    } finally {
      setBusy(false);
    }
  };

  const onPlan = async () => {
    setBusy(true);
    try {
      const payloads = buildPhasePayloads();
      const res = await agentPlan(payloads.plan);
      setLogLine(JSON.stringify({ phase: "1-plan", scaledAmountUsdcRaw: payloads.amountRaw, payload: payloads.plan, response: res }, null, 2));
    } catch (error) {
      setLogLine(`Plan failed: ${String(error)}`);
    } finally {
      setBusy(false);
    }
  };

  const onSponsor = async () => {
    setBusy(true);
    try {
      const payloads = buildPhasePayloads();
      const session = await buildSessionAuthorization({
        requestId: payloads.sponsor.requestId,
        chainId: payloads.sponsor.chainId,
        action: payloads.sponsor.action,
        amountUsdcRaw: payloads.sponsor.amountUsdc,
        slippageBps: payloads.sponsor.slippageBps,
        sender: payloads.sponsor.sender,
      });
      const res = await agentSponsor({ ...payloads.sponsor, session });
      const approval = String((res.approvalId as string) || "");
      if (approval) setLastApprovalId(approval);
      setLogLine(
        JSON.stringify(
          { phase: "2-sponsor", scaledAmountUsdcRaw: payloads.amountRaw, payload: { ...payloads.sponsor, session }, response: res },
          null,
          2
        )
      );
    } catch (error) {
      setLogLine(`Sponsor failed: ${String(error)}`);
    } finally {
      setBusy(false);
    }
  };

  const onExecute = async () => {
    setBusy(true);
    try {
      if (!lastApprovalId.trim()) throw new Error("approvalId missing. Run sponsor first.");
      const payloads = buildPhasePayloads();
      const res = await agentExecute(payloads.execute);
      setLogLine(
        JSON.stringify(
          { phase: "3-execute", scaledAmountUsdcRaw: payloads.amountRaw, payload: payloads.execute, forceMinOuts: "all zero", response: res },
          null,
          2
        )
      );
    } catch (error) {
      setLogLine(`Execute failed: ${String(error)}`);
    } finally {
      setBusy(false);
    }
  };

  const onRevoke = async () => {
    setBusy(true);
    try {
      if (!isHexAddress(userAddress)) throw new Error("user address invalid");
      if (!isHexAddress(agentAddress)) throw new Error("agent address invalid");
      const res = await agentRevoke({
        requestId: `agent_revoke_${Date.now()}`,
        chainId: selectedChain,
        user: userAddress,
        agent: agentAddress,
        reason: "manual revoke from agent page",
      });
      setLogLine(JSON.stringify({ phase: "4-revoke", response: res }, null, 2));
    } catch (error) {
      setLogLine(`Revoke failed: ${String(error)}`);
    } finally {
      setBusy(false);
    }
  };

  const selectedEventState = selectedEvent ? effectiveMarketState(selectedEvent, nowUnix) : "open";

  return (
    <div className="mx-auto min-h-screen w-full max-w-7xl px-4 py-6 text-slate-100 sm:px-6 lg:px-8">
      <header className="glass mb-6 rounded-2xl border border-white/10 p-5 shadow-glow">
        <h1 className="font-heading text-2xl tracking-tight">Prediction Market Agent Console</h1>
        <p className="mt-1 text-sm text-slate-300">Agent flow with event selection, action typing, and phased plan/sponsor/execute payloads.</p>
      </header>

      <section className="glass mb-4 rounded-2xl border border-white/10 p-4">
        <h2 className="font-heading text-lg">Wallet + Chain</h2>
        <div className="mt-3 grid gap-2 md:grid-cols-5">
          <select
            className="rounded-xl border border-white/10 bg-ink-900 px-3 py-2 text-sm"
            value={selectedChain}
            onChange={(event) => setSelectedChain(Number(event.target.value) as SupportedChainId)}
          >
            <option value={84532}>Base Sepolia</option>
            <option value={421614}>Arbitrum Sepolia</option>
          </select>
          <input
            className="rounded-xl border border-white/10 bg-ink-900 px-3 py-2 text-sm"
            value={walletPassword}
            onChange={(event) => setWalletPassword(event.target.value)}
            placeholder="Wallet Password"
            type="password"
          />
          <button
            type="button"
            disabled={busy}
            onClick={onLoadLocalWallet}
            className="rounded-xl bg-mint-500 px-4 py-2 text-sm font-semibold text-ink-950 disabled:opacity-40"
          >
            Load Local Wallet
          </button>
          <button
            type="button"
            disabled={busy}
            onClick={onUseConnectedWalletAsUser}
            className="rounded-xl bg-sky-400 px-4 py-2 text-sm font-semibold text-ink-950 disabled:opacity-40"
          >
            Use Connected Wallet As User
          </button>
          <a className="rounded-xl bg-white/10 px-4 py-2 text-center text-sm font-semibold text-slate-100 hover:bg-white/20" href="/">
            Open Main App
          </a>
        </div>
        <div className="mt-2 text-xs text-slate-300">{walletHint}</div>
        <div className="mt-2 text-xs text-slate-300">Local Wallet: {walletAddress || "not loaded"}</div>
        <div className="mt-2 text-xs text-slate-300">Connected Wallet: {connectedWalletAddress || "not connected"}</div>
      </section>

      <section className="glass mb-4 rounded-2xl border border-white/10 p-4">
        <h2 className="font-heading text-lg">Router Agent Permission</h2>
        <div className="mt-3 grid gap-2 md:grid-cols-3">
          <input
            className="rounded-xl border border-white/10 bg-ink-900 px-3 py-2 text-sm"
            value={agentAddress}
            onChange={(event) => setAgentAddress(event.target.value)}
            placeholder="Agent Address (required before trade)"
          />
          <input
            className="rounded-xl border border-white/10 bg-ink-900 px-3 py-2 text-sm"
            value={maxAmountPerAction}
            onChange={(event) => setMaxAmountPerAction(event.target.value)}
            placeholder="Max amount per action (USDC decimal)"
          />
          <input
            className="rounded-xl border border-white/10 bg-ink-900 px-3 py-2 text-sm"
            value={expiresInHours}
            onChange={(event) => setExpiresInHours(event.target.value)}
            placeholder="Expires in hours"
          />
        </div>

        <div className="mt-3 grid gap-2 sm:grid-cols-2 lg:grid-cols-4">
          {AGENT_MASK_ITEMS.map((item) => (
            <label key={item.bit} className="flex items-center gap-2 rounded-xl border border-white/10 bg-ink-900/70 px-3 py-2 text-xs">
              <input type="checkbox" checked={selectedMaskBits.includes(item.bit)} onChange={() => toggleMaskBit(item.bit)} />
              <span>
                {item.bit + 1}. {item.label}
              </span>
            </label>
          ))}
        </div>

        <div className="mt-3 flex flex-wrap items-center gap-2 text-xs text-slate-300">
          <span>Action Mask Decimal: {actionMask}</span>
          <button
            type="button"
            disabled={busy}
            onClick={onSetAgentPermission}
            className="rounded-xl bg-sky-400 px-4 py-2 text-sm font-semibold text-ink-950 disabled:opacity-40"
          >
            Add Agent To Router
          </button>
        </div>
      </section>

      <section className="grid gap-4 lg:grid-cols-[340px_minmax(0,1fr)]">
        <div className="glass rounded-2xl border border-white/10 p-4">
          <h2 className="font-heading text-lg">Onchain Events</h2>
          <p className="mb-3 text-xs text-slate-300">Loaded from MarketFactory + market snapshots.</p>
          <div className="space-y-4">
            {([
              ["Active", groupedEvents.active, "open"],
              ["Closed", groupedEvents.closed, "closed"],
              ["Review", groupedEvents.review, "review"],
              ["Resolved", groupedEvents.resolved, "resolved"],
            ] as const).map(([label, list, state]) => (
              <div key={label}>
                <div className="mb-2 flex items-center justify-between">
                  <p className={`text-xs font-semibold uppercase tracking-wide ${marketStateTone[state]}`}>{label}</p>
                  <span className="text-xs text-slate-400">{list.length}</span>
                </div>
                <div className="space-y-2">
                  {list.map((item) => {
                    const itemState = effectiveMarketState(item, nowUnix);
                    return (
                      <button
                        key={item.id}
                        type="button"
                        onClick={() => setSelectedEventId(item.id)}
                        className={`w-full rounded-xl border p-3 text-left transition ${
                          item.id === selectedEvent?.id ? "border-mint-400 bg-mint-500/10" : "border-white/10 bg-ink-900/70 hover:border-sky-300/60"
                        }`}
                      >
                        <p className="line-clamp-2 text-sm font-medium">{item.question}</p>
                        <p className={`mt-2 text-xs uppercase ${marketStateTone[itemState]}`}>{itemState}</p>
                        <p className="mt-1 text-xs text-slate-300">Close: {formatDateTime(item.closeTimeUnix)}</p>
                      </button>
                    );
                  })}
                </div>
              </div>
            ))}
          </div>
        </div>

        <div className="glass rounded-2xl border border-white/10 p-4">
          {selectedEvent ? (
            <>
              <h2 className="font-heading text-xl">{selectedEvent.question}</h2>
              <div className="mt-1 text-xs text-slate-400">Market: {selectedEvent.marketAddress}</div>
              <div className={`mt-2 text-xs ${marketStateTone[selectedEventState]}`}>State: {selectedEventState}</div>

              <div className="mt-4 grid gap-2 md:grid-cols-2">
                <input
                  className="rounded-xl border border-white/10 bg-ink-900 px-3 py-2 text-sm"
                  value={userAddress}
                  onChange={(event) => setUserAddress(event.target.value)}
                  placeholder="User Address (sender/user)"
                />
                <input
                  className="rounded-xl border border-white/10 bg-ink-900 px-3 py-2 text-sm"
                  value={agentAddress}
                  onChange={(event) => setAgentAddress(event.target.value)}
                  placeholder="Agent Address (required)"
                />

                <select
                  className="rounded-xl border border-white/10 bg-ink-900 px-3 py-2 text-sm"
                  value={action}
                  onChange={(event) => setAction(event.target.value as AgentAction)}
                >
                  {AGENT_MASK_ITEMS.map((item) => (
                    <option key={item.action} value={item.action}>
                      {item.bit + 1}. {item.action}
                    </option>
                  ))}
                </select>

                <input
                  className="rounded-xl border border-white/10 bg-ink-900 px-3 py-2 text-sm"
                  value={amountUsdcInput}
                  onChange={(event) => setAmountUsdcInput(event.target.value)}
                  placeholder="Amount USDC (human, e.g. 10)"
                  disabled={action === "disputeProposedResolution"}
                />

                <input
                  className="rounded-xl border border-white/10 bg-ink-900 px-3 py-2 text-sm"
                  value={slippageBps}
                  onChange={(event) => setSlippageBps(event.target.value)}
                  placeholder="Slippage bps"
                />

                <input
                  className="rounded-xl border border-white/10 bg-ink-900 px-3 py-2 text-sm"
                  value={lastApprovalId}
                  onChange={(event) => setLastApprovalId(event.target.value)}
                  placeholder="approvalId (from sponsor phase)"
                />
              </div>

              {action === "disputeProposedResolution" ? (
                <div className="mt-2">
                  <select
                    className="rounded-xl border border-white/10 bg-ink-900 px-3 py-2 text-sm"
                    value={proposedOutcome}
                    onChange={(event) => setProposedOutcome(event.target.value as "1" | "2" | "3")}
                  >
                    <option value="1">Propose YES</option>
                    <option value="2">Propose NO</option>
                    <option value="3">Propose INCONCLUSIVE</option>
                  </select>
                </div>
              ) : null}

              <div className="mt-3 rounded-xl border border-white/10 bg-ink-900/60 p-3 text-xs text-slate-200">
                <p>Agent actionType: {ACTION_TYPE_BY_ACTION[action]}</p>
                <p>Amount scaled to raw E6 before send (example: 10 to 10000000).</p>
                <p>For execute payload, all min-out fields are forced to 0.</p>
              </div>

              <div className="mt-4 flex flex-wrap gap-2">
                <button type="button" disabled={busy} onClick={onPlan} className="rounded-xl bg-mint-500 px-4 py-2 text-sm font-semibold text-ink-950 disabled:opacity-40">
                  1. Plan
                </button>
                <button type="button" disabled={busy} onClick={onSponsor} className="rounded-xl bg-sky-400 px-4 py-2 text-sm font-semibold text-ink-950 disabled:opacity-40">
                  2. Sponsor
                </button>
                <button type="button" disabled={busy} onClick={onExecute} className="rounded-xl bg-gold-400 px-4 py-2 text-sm font-semibold text-ink-950 disabled:opacity-40">
                  3. Execute
                </button>
                <button type="button" disabled={busy} onClick={onRevoke} className="rounded-xl bg-rose-400 px-4 py-2 text-sm font-semibold text-ink-950 disabled:opacity-40">
                  4. Revoke
                </button>
              </div>
            </>
          ) : (
            <p className="text-sm text-slate-300">No events found.</p>
          )}
        </div>
      </section>

      <section className="mt-4">
        <div className="glass rounded-2xl border border-white/10 p-4">
          <h3 className="font-heading text-base">Response / Logs</h3>
          <pre className="mt-2 overflow-x-auto rounded-xl border border-white/10 bg-black/30 p-3 text-xs text-slate-200">{logLine}</pre>
        </div>
      </section>
    </div>
  );
}
