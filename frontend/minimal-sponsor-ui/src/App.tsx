import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { AbiCoder, BrowserProvider, Contract, Wallet, formatUnits, keccak256, parseUnits, toUtf8Bytes, type Eip1193Provider } from "ethers";
import { fetchTrackedMarkets, signInWithGoogleAndSession, submitAction, submitExternalDepositFunding, submitFiatPayment, syncPositionSnapshots } from "./api";
import {
  CHAIN_CONFIG,
  ERC20_ABI,
  MARKET_FACTORY_ABI,
  ROUTER_ABI,
  loadMarketSnapshot,
  providerForChain,
  type SupportedChainId,
} from "./chain";
import { clearStoredWallet, createOrLoadWallet, getStoredWalletMeta } from "./keyVault";
import type { MarketEvent, Position, SessionIdentity, UiPage, UserProfile } from "./types";

const ACTIONS = ["mintCompleteSets", "swapYesForNo", "swapNoForYes", "redeemCompleteSets", "redeem", "disputeProposedResolution"] as const;
const ACTION_TYPE_MAP: Record<(typeof ACTIONS)[number], string> = {
  mintCompleteSets: "routerMintCompleteSets",
  swapYesForNo: "routerSwapYesForNo",
  swapNoForYes: "routerSwapNoForYes",
  redeemCompleteSets: "routerRedeemCompleteSets",
  redeem: "routerRedeem",
  disputeProposedResolution: "routerDisputeProposedResolution",
};

const SESSION_DOMAIN_NAME = "CRE Session Authorization";
const SESSION_DOMAIN_VERSION = "1";

const CHAIN_HEX: Record<SupportedChainId, string> = {
  84532: "0x14a34",
  421614: "0x66eee",
};

const formatUsdc = (raw: string): string => {
  try {
    return formatUnits(BigInt(raw || "0"), 6);
  } catch {
    return "0";
  }
};

const formatDateTime = (unix: number): string => new Date(unix * 1000).toLocaleString();

const marketStateTone: Record<MarketEvent["state"], string> = {
  open: "text-mint-400",
  closed: "text-gold-400",
  review: "text-amber-300",
  resolved: "text-rose-400",
};

const encodeRouterPayloadHex = (
  action: (typeof ACTIONS)[number],
  user: string,
  market: string,
  amountUsdcRaw: bigint,
  disputeOutcome: number
): string => {
  const coder = AbiCoder.defaultAbiCoder();
  if (action === "mintCompleteSets" || action === "redeemCompleteSets" || action === "redeem") {
    return coder.encode(["address", "address", "uint256"], [user, market, amountUsdcRaw]);
  }
  if (action === "swapYesForNo" || action === "swapNoForYes") {
    // Keep min out as 0 for now; slippage controls are currently enforced in sponsor policy layer.
    return coder.encode(["address", "address", "uint256", "uint256"], [user, market, amountUsdcRaw, 0n]);
  }
  if (action === "disputeProposedResolution") {
    return coder.encode(["address", "address", "uint8"], [user, market, disputeOutcome]);
  }
  throw new Error(`unsupported action for router payload: ${action}`);
};

const effectiveMarketState = (event: MarketEvent, nowUnix: number): MarketEvent["state"] => {
  if (event.state === "resolved") return "resolved";
  if (event.state === "review") return "review";
  if (event.resolutionOutcome) return "resolved";
  if (nowUnix >= event.closeTimeUnix) return "closed";
  return event.state;
};

export function App() {
  const [page, setPage] = useState<UiPage>("markets");
  const [user, setUser] = useState<UserProfile | null>(null);
  const [sessionIdentity, setSessionIdentity] = useState<SessionIdentity | null>(null);
  const [events, setEvents] = useState<MarketEvent[]>([]);
  const [selectedEventId, setSelectedEventId] = useState<string>("");
  const [positions, setPositions] = useState<Position[]>([]);
  const [trackedMarketSnapshots, setTrackedMarketSnapshots] = useState<MarketEvent[]>([]);
  const [vaultBalanceUsdc, setVaultBalanceUsdc] = useState<string>("0");
  const [email, setEmail] = useState("trader@example.com");
  const [name, setName] = useState("Market Trader");
  const [password, setPassword] = useState("");
  const [walletHint, setWalletHint] = useState<string>("");
  const [fundingWalletAddress, setFundingWalletAddress] = useState("");
  const [selectedChain, setSelectedChain] = useState<SupportedChainId>(84532);
  const [amountUsdc, setAmountUsdc] = useState("1");
  const [fiatUsd, setFiatUsd] = useState("15");
  const [provider, setProvider] = useState("google_pay");
  const [activeAction, setActiveAction] = useState<(typeof ACTIONS)[number]>("mintCompleteSets");
  const [disputeOutcome, setDisputeOutcome] = useState<"1" | "2" | "3">("1");
  const [nowUnix, setNowUnix] = useState<number>(Math.floor(Date.now() / 1000));
  const [busy, setBusy] = useState(false);
  const [logLine, setLogLine] = useState("Waiting for action...");

  useEffect(() => {
    const meta = getStoredWalletMeta();
    if (meta) {
      setWalletHint(`Stored wallet found: ${meta.address}`);
    }
  }, []);

  useEffect(() => {
    const timer = setInterval(() => setNowUnix(Math.floor(Date.now() / 1000)), 1000);
    return () => clearInterval(timer);
  }, []);

  useEffect(() => {
    // Prevent stale market cards from previous chain/address config while reloading.
    setEvents([]);
    setTrackedMarketSnapshots([]);
    setSelectedEventId("");
  }, [selectedChain]);

  const walletAddress = sessionIdentity?.address || "";

  const getFundingProvider = useCallback(() => {
    const ethereum = (window as Window & { ethereum?: Eip1193Provider }).ethereum;
    if (!ethereum) throw new Error("No external wallet found. Install MetaMask.");
    return new BrowserProvider(ethereum);
  }, []);

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

  const visibleMarkets = useMemo(() => [...groupedEvents.active, ...groupedEvents.closed, ...groupedEvents.review, ...groupedEvents.resolved], [
    groupedEvents.active,
    groupedEvents.closed,
    groupedEvents.review,
    groupedEvents.resolved,
  ]);

  const knownMarkets = useMemo(() => {
    const map = new Map<string, MarketEvent>();
    for (const item of [...events, ...trackedMarketSnapshots]) {
      map.set(item.id, item);
    }
    return [...map.values()];
  }, [events, trackedMarketSnapshots]);

  const selectedEvent = useMemo(
    () => visibleMarkets.find((item) => item.id === selectedEventId) || visibleMarkets[0] || null,
    [visibleMarkets, selectedEventId]
  );

  useEffect(() => {
    if (!visibleMarkets.length) {
      if (selectedEventId) setSelectedEventId("");
      return;
    }
    const exists = visibleMarkets.some((item) => item.id === selectedEventId);
    if (!exists) setSelectedEventId(visibleMarkets[0].id);
  }, [visibleMarkets, selectedEventId]);

  const refreshVaultBalance = useCallback(async () => {
    if (!walletAddress) {
      setVaultBalanceUsdc("0");
      return;
    }
    const cfg = CHAIN_CONFIG[selectedChain];
    const provider = providerForChain(selectedChain);
    const router = new Contract(cfg.addresses.router, ROUTER_ABI, provider);
    const balance = await router.collateralCredits(walletAddress);
    setVaultBalanceUsdc(String(balance));
  }, [selectedChain, walletAddress]);

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
        ? await Promise.all(
            Array.from({ length: marketCount }, (_, index) =>
              factory.marketById(BigInt(index + 1)).catch(() => null)
            )
          )
        : [];
    const marketAddresses = [...new Set([...(activeEventList as string[]), ...indexedMarkets.filter(Boolean)].map((value) => String(value).toLowerCase()))];
    const snapshots = await Promise.all(
      marketAddresses.map(async (address) => ({
        address,
        snapshot: await loadMarketSnapshot(selectedChain, address).catch(() => null),
      }))
    );
    const snapshotByAddress = new Map(
      snapshots
        .filter((item): item is { address: string; snapshot: MarketEvent } => item.snapshot !== null)
        .map((item) => [item.address, item.snapshot])
    );

    const nextEvents = marketAddresses
      .map((address) => snapshotByAddress.get(address) || null)
      .filter((item): item is MarketEvent => item !== null)
      .sort((a, b) => a.closeTimeUnix - b.closeTimeUnix);
    setEvents(nextEvents);

    setSelectedEventId((currentSelected) => {
      if (currentSelected) return currentSelected;
      const first = snapshots.find((item) => item.snapshot !== null)?.snapshot;
      return first?.id || "";
    });
  }, [selectedChain]);

  const refreshPositions = useCallback(async () => {
    if (!walletAddress) {
      setPositions([]);
      return;
    }

    let trackedSnapshots: MarketEvent[] = [];
    if (user?.sessionToken) {
      const tracked = await fetchTrackedMarkets(user.sessionToken, selectedChain).catch(() => ({ trackedMarkets: [] }));
      trackedSnapshots = (
        await Promise.all(
          tracked.trackedMarkets.map((entry) =>
            loadMarketSnapshot(selectedChain, entry.marketAddress).catch(() => null)
          )
        )
      ).filter((item): item is MarketEvent => item !== null);
    }
    setTrackedMarketSnapshots(trackedSnapshots);

    const marketsForPositions = [...events, ...trackedSnapshots];
    if (!marketsForPositions.length) {
      setPositions([]);
      return;
    }

    const cfg = CHAIN_CONFIG[selectedChain];
    const provider = providerForChain(selectedChain);
    const router = new Contract(cfg.addresses.router, ROUTER_ABI, provider);

    const rows = await Promise.all(
      marketsForPositions.map(async (event) => {
        if (!event.yesToken || !event.noToken) return null;
        const [yes, no] = await Promise.all([
          router.tokenCredits(walletAddress, event.yesToken),
          router.tokenCredits(walletAddress, event.noToken),
        ]);
        const yesShares = String(yes);
        const noShares = String(no);
        if (BigInt(yesShares) === 0n && BigInt(noShares) === 0n) return null;

        const complete = BigInt(yesShares) < BigInt(noShares) ? BigInt(yesShares) : BigInt(noShares);
        const redeemable =
          event.resolutionOutcome === "yes"
            ? BigInt(yesShares)
            : event.resolutionOutcome === "no"
              ? BigInt(noShares)
              : 0n;

        return {
          eventId: event.id,
          question: event.question,
          yesShares,
          noShares,
          completeSetsMinted: complete.toString(),
          redeemableUsdc: redeemable.toString(),
        } satisfies Position;
      })
    );

    const deduped = new Map<string, Position>();
    for (const row of rows) {
      if (!row) continue;
      deduped.set(row.eventId, row);
    }
    const nextPositions = [...deduped.values()];
    setPositions(nextPositions);
    if (user?.sessionToken) {
      await syncPositionSnapshots(user.sessionToken, { positions: nextPositions }).catch(() => undefined);
    }
  }, [events, selectedChain, user?.sessionToken, walletAddress]);

  useEffect(() => {
    loadMarkets().catch((error) => setLogLine(`Load markets failed: ${String(error)}`));
  }, [loadMarkets]);

  useEffect(() => {
    refreshVaultBalance().catch((error) => setLogLine(`Load vault balance failed: ${String(error)}`));
    refreshPositions().catch((error) => setLogLine(`Load positions failed: ${String(error)}`));
  }, [refreshVaultBalance, refreshPositions]);

  useEffect(() => {
    const timer = setInterval(() => {
      loadMarkets().catch(() => undefined);
      refreshVaultBalance().catch(() => undefined);
      refreshPositions().catch(() => undefined);
    }, 15000);

    return () => clearInterval(timer);
  }, [loadMarkets, refreshPositions, refreshVaultBalance]);

  const onSignIn = async () => {
    setBusy(true);
    try {
      const session = await createOrLoadWallet(password);
      setSessionIdentity(session);

      const res = await signInWithGoogleAndSession(email, name, {
        walletAddress: session.address,
        sessionAddress: session.address,
        sessionPublicKey: session.publicKey,
      });

      const userLocal: UserProfile = {
        ...res.user,
        walletAddress: session.address,
        wallet: {
          address: session.address,
          publicKey: session.publicKey,
        },
        session,
      };
      setUser(userLocal);
      setWalletHint(`Active local wallet: ${session.address}`);
      await refreshVaultBalance();
      setLogLine(JSON.stringify({ backend: res, localWallet: { address: session.address, publicKey: session.publicKey } }, null, 2));
    } catch (error) {
      setLogLine(`Sign-in failed: ${String(error)}`);
    } finally {
      setBusy(false);
    }
  };

  const onResetWallet = () => {
    clearStoredWallet();
    setSessionIdentity(null);
    setUser(null);
    setWalletHint("Stored wallet cleared. Sign in again to generate a new one.");
    setVaultBalanceUsdc("0");
    setPositions([]);
    setTrackedMarketSnapshots([]);
  };

  const onConnectFundingWallet = async () => {
    setBusy(true);
    try {
      const provider = getFundingProvider();
      const accounts = (await provider.send("eth_requestAccounts", [])) as string[];
      const account = accounts[0] || "";
      if (!account) throw new Error("No account selected");
      setFundingWalletAddress(account);
      setLogLine(`Funding wallet connected: ${account}`);
    } catch (error) {
      setLogLine(`Funding wallet connection failed: ${String(error)}`);
    } finally {
      setBusy(false);
    }
  };

  const onDepositForWithExternal = async () => {
    if (!sessionIdentity) {
      setLogLine("Sign in first to create your local wallet.");
      return;
    }

    setBusy(true);
    try {
      const provider = getFundingProvider();
      await provider.send("wallet_switchEthereumChain", [{ chainId: CHAIN_HEX[selectedChain] }]);
      const signer = await provider.getSigner();
      const from = await signer.getAddress();
      setFundingWalletAddress(from);

      const cfg = CHAIN_CONFIG[selectedChain];
      const amount = parseUnits(amountUsdc || "0", 6);
      if (amount <= 0n) throw new Error("invalid amount");

      const collateral = new Contract(cfg.addresses.collateral, ERC20_ABI, signer);
      const router = new Contract(cfg.addresses.router, ROUTER_ABI, signer);
      const allowance = await collateral.allowance(from, cfg.addresses.router);
      if (BigInt(allowance) < amount) {
        const approveTx = await collateral.approve(cfg.addresses.router, amount);
        setLogLine(`Approve sent: ${approveTx.hash}`);
        await approveTx.wait();
      }

      const depositTx = await router.depositFor(sessionIdentity.address, amount);
      setLogLine(`DepositFor sent: ${depositTx.hash}`);
      await depositTx.wait();

      const backendLog = await submitExternalDepositFunding({
        chainId: selectedChain,
        funder: from,
        beneficiary: sessionIdentity.address,
        amountUsdc: amount.toString(),
        txHash: depositTx.hash,
      });

      await refreshVaultBalance();
      await refreshPositions();
      setLogLine(JSON.stringify({ depositTxHash: depositTx.hash, backendLog }, null, 2));
    } catch (error) {
      setLogLine(`DepositFor failed: ${String(error)}`);
    } finally {
      setBusy(false);
    }
  };

  const onFiat = async () => {
    if (!user) {
      setLogLine("Sign in first.");
      return;
    }
    setBusy(true);
    try {
      const res = await submitFiatPayment(user.sessionToken, {
        amountUsd: fiatUsd,
        provider,
        chainId: selectedChain,
      });
      setLogLine(JSON.stringify(res, null, 2));
    } catch (error) {
      setLogLine(`Fiat failed: ${String(error)}`);
    } finally {
      setBusy(false);
    }
  };

  const onPrepareRedeemFromPosition = (position: Position) => {
    const market = knownMarkets.find((item) => item.id === position.eventId);
    if (!market) {
      setLogLine("Cannot prepare redeem: market snapshot is missing.");
      return;
    }

    const redeemable = BigInt(position.redeemableUsdc || "0");
    if (redeemable <= 0n) {
      setLogLine("No redeemable collateral for this position.");
      return;
    }

    setSelectedEventId(market.id);
    setActiveAction("redeem");
    setAmountUsdc(formatUsdc(position.redeemableUsdc));
    setPage("markets");
    setLogLine(
      `Redeem prepared for "${market.question}". Click "Sign + Submit Action" to redeem ${formatUsdc(position.redeemableUsdc)} USDC.`
    );
  };

  const onPrepareDisputeFromPosition = (position: Position) => {
    const market = knownMarkets.find((item) => item.id === position.eventId);
    if (!market) {
      setLogLine("Cannot prepare dispute: market snapshot is missing.");
      return;
    }
    if (effectiveMarketState(market, nowUnix) !== "review") {
      setLogLine("This market is not in review/dispute state.");
      return;
    }
    setSelectedEventId(market.id);
    setActiveAction("disputeProposedResolution");
    setAmountUsdc("0");
    setPage("markets");
    setLogLine(`Dispute prepared for "${market.question}". Select your outcome and click "Sign + Submit Action".`);
  };

  const onAction = async () => {
    if (!selectedEvent || !sessionIdentity?.privateKey) {
      setLogLine("Select event and sign in first.");
      return;
    }

    const stateNow = effectiveMarketState(selectedEvent, nowUnix);
    if (stateNow === "closed") {
      setLogLine("Market closed. You cannot trade this market now.");
      return;
    }
    if (stateNow === "resolved" && activeAction !== "redeem") {
      setLogLine("Market resolved. Only redeem action is allowed.");
      return;
    }
    if (stateNow === "review" && activeAction !== "disputeProposedResolution") {
      setLogLine("Market is in dispute review. Only dispute action is allowed.");
      return;
    }
    if (stateNow !== "review" && activeAction === "disputeProposedResolution") {
      setLogLine("Dispute action is only available when market is in review state.");
      return;
    }

    setBusy(true);
    try {
      const amount = activeAction === "disputeProposedResolution" ? 0n : parseUnits(amountUsdc || "0", 6);
      if (activeAction !== "disputeProposedResolution" && amount <= 0n) {
        throw new Error("Amount must be greater than zero");
      }
      const actionType = ACTION_TYPE_MAP[activeAction];
      const requestId = `ui_${Date.now()}`;
      const reportPayloadHex = encodeRouterPayloadHex(
        activeAction,
        sessionIdentity.address,
        selectedEvent.marketAddress,
        amount,
        Number(disputeOutcome)
      );

      const signer = new Wallet(sessionIdentity.privateKey);
      const sessionId = `session_${sessionIdentity.address.slice(2, 10)}_${Date.now()}`;
      const requestNonce = `nonce_${Date.now()}_${Math.random().toString(36).slice(2, 10)}`;
      const expiresAtUnix = nowUnix + 3600;
      const maxAmountUsdc = "10000000000";
      const allowedActions = [...ACTIONS];
      const sortedActions = [...allowedActions].sort();
      const allowedActionsHash = keccak256(toUtf8Bytes(sortedActions.join(",")));

      const typedDomain = {
        name: SESSION_DOMAIN_NAME,
        version: SESSION_DOMAIN_VERSION,
        chainId: selectedChain,
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
      const sessionGrantValue = {
        sessionId,
        owner: sessionIdentity.address,
        sessionPublicKey: sessionIdentity.publicKey,
        chainId: selectedChain,
        allowedActionsHash,
        maxAmountUsdc,
        expiresAtUnix,
      };
      const grantSignature = await signer.signTypedData(typedDomain, sessionGrantTypes, sessionGrantValue);

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
      const sponsorIntentValue = {
        requestId,
        sessionId,
        requestNonce,
        chainId: selectedChain,
        action: activeAction,
        amountUsdc: amount.toString(),
        slippageBps: 120,
        sender: sessionIdentity.address,
      };
      const requestSignature = await signer.signTypedData(typedDomain, sponsorIntentTypes, sponsorIntentValue);

      const res = await submitAction({
        requestId,
        chainId: selectedChain,
        action: activeAction,
        actionType,
        amountUsdc: amount.toString(),
        sender: sessionIdentity.address,
        slippageBps: 120,
        reportPayloadHex,
        session: {
          sessionId,
          owner: sessionIdentity.address,
          sessionPublicKey: sessionIdentity.publicKey,
          chainId: selectedChain,
          allowedActions,
          maxAmountUsdc,
          expiresAtUnix,
          grantSignature,
          requestNonce,
          requestSignature,
        },
        market: {
          chainId: selectedChain,
          marketAddress: selectedEvent.marketAddress,
          marketId: selectedEvent.marketId,
          question: selectedEvent.question,
          yesToken: selectedEvent.yesToken,
          noToken: selectedEvent.noToken,
        },
      });

      setLogLine(JSON.stringify(res, null, 2));
      await refreshVaultBalance();
      await refreshPositions();
    } catch (error) {
      setLogLine(`Action failed: ${String(error)}`);
    } finally {
      setBusy(false);
    }
  };

  const eventPosition = useMemo(
    () => (selectedEvent ? positions.find((item) => item.eventId === selectedEvent.id) : null),
    [positions, selectedEvent]
  );

  const selectedEventState = selectedEvent ? effectiveMarketState(selectedEvent, nowUnix) : "open";

  const actionDisabled = useMemo(() => {
    if (!selectedEvent) return true;
    if (selectedEventState === "closed") return true;
    if (selectedEventState === "resolved" && activeAction !== "redeem") return true;
    if (selectedEventState === "review" && activeAction !== "disputeProposedResolution") return true;
    if (selectedEventState !== "review" && activeAction === "disputeProposedResolution") return true;
    if (selectedEventState === "open" && activeAction === "disputeProposedResolution") return true;
    if (activeAction === "redeem") {
      const redeemable = BigInt(eventPosition?.redeemableUsdc || "0");
      if (redeemable <= 0n) return true;
    }
    return false;
  }, [selectedEvent, selectedEventState, activeAction, eventPosition]);

  return (
    <div className="mx-auto min-h-screen w-full max-w-7xl px-4 py-6 text-slate-100 sm:px-6 lg:px-8">
      <header className="glass mb-6 rounded-2xl border border-white/10 p-5 shadow-glow">
        <h1 className="font-heading text-2xl tracking-tight">Prediction Market Console</h1>
        <p className="mt-1 text-sm text-slate-300">Local encrypted key wallet for trading/signing, with MetaMask used only for deposit payment.</p>

        <div className="mt-4 grid gap-3 md:grid-cols-4">
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
            value={name}
            onChange={(event) => setName(event.target.value)}
            placeholder="Name"
          />
          <input
            className="rounded-xl border border-white/10 bg-ink-900 px-3 py-2 text-sm"
            value={email}
            onChange={(event) => setEmail(event.target.value)}
            placeholder="Google Email"
          />
          <input
            className="rounded-xl border border-white/10 bg-ink-900 px-3 py-2 text-sm"
            value={password}
            onChange={(event) => setPassword(event.target.value)}
            placeholder="Wallet Password (min 8)"
            type="password"
          />
        </div>

        <div className="mt-3 flex flex-wrap gap-2">
          <button
            type="button"
            disabled={busy}
            onClick={onSignIn}
            className="rounded-xl bg-mint-500 px-4 py-2 text-sm font-semibold text-ink-950 transition hover:bg-mint-400 disabled:cursor-not-allowed disabled:opacity-50"
          >
            Sign In + Unlock Local Wallet
          </button>
          <button
            type="button"
            onClick={onResetWallet}
            className="rounded-xl bg-white/10 px-4 py-2 text-sm font-semibold text-slate-100 hover:bg-white/20"
          >
            Reset Local Wallet
          </button>
        </div>

        <div className="mt-2 text-xs text-slate-300">{walletHint || "No local wallet yet."}</div>

        <div className="mt-4 grid gap-2 rounded-xl border border-white/10 bg-black/20 p-3 text-xs sm:grid-cols-2">
          <div>Chain: {CHAIN_CONFIG[selectedChain].name}</div>
          <div>Wallet: {walletAddress || "locked"}</div>
          <div>Router: {CHAIN_CONFIG[selectedChain].addresses.router}</div>
          <div>Router Vault Balance: {formatUsdc(vaultBalanceUsdc)} USDC</div>
          {sessionIdentity ? <div>Session PubKey: {sessionIdentity.publicKey.slice(0, 34)}...</div> : null}
          <div className="text-slate-400">Private key is encrypted in browser storage and used locally for signing.</div>
        </div>
      </header>

      <nav className="mb-4 flex flex-wrap gap-2">
        {([
          ["markets", "Markets"],
          ["deposit", "Deposit"],
          ["fiat", "Fiat"],
          ["positions", "Positions"],
        ] as const).map(([value, label]) => (
          <button
            key={value}
            type="button"
            onClick={() => setPage(value)}
            className={`rounded-full px-4 py-2 text-sm ${
              page === value ? "bg-sky-400/90 text-ink-950" : "bg-white/10 text-slate-200 hover:bg-white/20"
            }`}
          >
            {label}
          </button>
        ))}
      </nav>

      {page === "markets" ? (
        <section className="grid gap-4 lg:grid-cols-[340px_minmax(0,1fr)]">
          <div className="glass rounded-2xl border border-white/10 p-4">
            <h2 className="font-heading text-lg">Onchain Markets</h2>
            <p className="mb-3 text-xs text-slate-300">Live from MarketFactory logs + periodic snapshot refresh.</p>
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
                    {list.length === 0 ? (
                      <p className="rounded-lg border border-white/5 bg-ink-900/40 px-3 py-2 text-xs text-slate-500">No {label.toLowerCase()} markets.</p>
                    ) : null}
                    {list.map((item) => {
                      const itemState = effectiveMarketState(item, nowUnix);
                      return (
                        <button
                          key={item.id}
                          type="button"
                          onClick={() => setSelectedEventId(item.id)}
                          className={`w-full rounded-xl border p-3 text-left transition ${
                            item.id === selectedEvent?.id
                              ? "border-mint-400 bg-mint-500/10"
                              : "border-white/10 bg-ink-900/70 hover:border-sky-300/60"
                          }`}
                        >
                          <p className="line-clamp-2 text-sm font-medium">{item.question}</p>
                          <p className={`mt-2 text-xs uppercase ${marketStateTone[itemState]}`}>{itemState}</p>
                          <p className="mt-1 text-xs text-slate-300">Close: {formatDateTime(item.closeTimeUnix)}</p>
                          <p className="text-xs text-slate-400">Resolve: {formatDateTime(item.resolutionTimeUnix)}</p>
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
                <div className="mt-3 grid gap-2 sm:grid-cols-2">
                  <div className="rounded-xl border border-white/10 bg-ink-900/70 p-3">
                    <p className="text-xs text-slate-400">Yes Price</p>
                    <p className="text-xl font-semibold text-mint-400">{(selectedEvent.yesPriceBps / 100).toFixed(2)}%</p>
                  </div>
                  <div className="rounded-xl border border-white/10 bg-ink-900/70 p-3">
                    <p className="text-xs text-slate-400">No Price</p>
                    <p className="text-xl font-semibold text-rose-400">{(selectedEvent.noPriceBps / 100).toFixed(2)}%</p>
                  </div>
                </div>

                <div className="mt-4 rounded-xl border border-white/10 bg-black/20 p-3 text-sm">
                  <p>Close Time: {formatDateTime(selectedEvent.closeTimeUnix)}</p>
                  <p>Resolution Time: {formatDateTime(selectedEvent.resolutionTimeUnix)}</p>
                  <p className={marketStateTone[selectedEventState]}>State: {selectedEventState}</p>
                  {selectedEvent.resolutionOutcome ? <p>Outcome: {selectedEvent.resolutionOutcome}</p> : null}
                  {selectedEvent.proposedResolutionOutcome ? <p>Proposed Outcome: {selectedEvent.proposedResolutionOutcome}</p> : null}
                  {selectedEvent.disputeDeadlineUnix ? <p>Dispute Deadline: {formatDateTime(selectedEvent.disputeDeadlineUnix)}</p> : null}
                  {selectedEvent.resolutionDisputed ? <p>Disputed: yes</p> : null}
                  {selectedEvent.questionProofUrl ? (
                    <p>
                      Proof URL:{" "}
                      <a
                        className="text-sky-300 underline underline-offset-2 hover:text-sky-200"
                        href={selectedEvent.questionProofUrl}
                        target="_blank"
                        rel="noreferrer"
                      >
                        {selectedEvent.questionProofUrl}
                      </a>
                    </p>
                  ) : null}
                </div>

                <div className="mt-4 grid gap-2 md:grid-cols-3">
                  <select
                    className="rounded-xl border border-white/10 bg-ink-900 px-3 py-2 text-sm"
                    value={activeAction}
                    onChange={(event) => setActiveAction(event.target.value as (typeof ACTIONS)[number])}
                  >
                    {ACTIONS.map((value) => (
                      <option key={value} value={value}>
                        {value}
                      </option>
                    ))}
                  </select>

                  <input
                    className="rounded-xl border border-white/10 bg-ink-900 px-3 py-2 text-sm"
                    value={amountUsdc}
                    onChange={(event) => setAmountUsdc(event.target.value)}
                    placeholder="Amount in USDC"
                    disabled={activeAction === "disputeProposedResolution"}
                  />

                  <button
                    type="button"
                    disabled={busy || actionDisabled}
                    onClick={onAction}
                    className="rounded-xl bg-sky-400 px-4 py-2 text-sm font-semibold text-ink-950 disabled:cursor-not-allowed disabled:opacity-40"
                  >
                    Sign + Submit Action
                  </button>
                </div>
                {activeAction === "disputeProposedResolution" ? (
                  <div className="mt-2">
                    <select
                      className="rounded-xl border border-white/10 bg-ink-900 px-3 py-2 text-sm"
                      value={disputeOutcome}
                      onChange={(event) => setDisputeOutcome(event.target.value as "1" | "2" | "3")}
                    >
                      <option value="1">Propose YES</option>
                      <option value="2">Propose NO</option>
                      <option value="3">Propose INCONCLUSIVE</option>
                    </select>
                  </div>
                ) : null}

                {selectedEventState === "closed" ? (
                  <p className="mt-2 text-xs text-gold-400">Market closed. Trading disabled.</p>
                ) : null}
                {selectedEventState === "review" && activeAction !== "disputeProposedResolution" ? (
                  <p className="mt-2 text-xs text-amber-300">Market is under review. Select disputeProposedResolution to submit your dispute.</p>
                ) : null}
                {selectedEventState === "resolved" && activeAction !== "redeem" ? (
                  <p className="mt-2 text-xs text-rose-400">Market resolved. Select redeem to claim winnings.</p>
                ) : null}
                {selectedEventState === "resolved" && activeAction === "redeem" && BigInt(eventPosition?.redeemableUsdc || "0") <= 0n ? (
                  <p className="mt-2 text-xs text-rose-400">No redeemable collateral for this position.</p>
                ) : null}

                <div className="mt-4 rounded-xl border border-white/10 bg-ink-900/70 p-3 text-xs text-slate-200">
                  <p>
                    Position: Yes {formatUsdc(eventPosition?.yesShares || "0")} / No {formatUsdc(eventPosition?.noShares || "0")}
                  </p>
                  <p>Complete set estimate: {formatUsdc(eventPosition?.completeSetsMinted || "0")}</p>
                  <p>Redeemable: {formatUsdc(eventPosition?.redeemableUsdc || "0")} USDC</p>
                </div>
              </>
            ) : (
              <p className="text-sm text-slate-300">No events available yet.</p>
            )}
          </div>
        </section>
      ) : null}

      {page === "deposit" ? (
        <section className="glass rounded-2xl border border-white/10 p-4">
          <h2 className="font-heading text-xl">Deposit Into Vault</h2>
          <p className="mt-1 text-sm text-slate-300">
            MetaMask pays for `depositFor(beneficiary, amount)` while your beneficiary is the local app wallet.
          </p>
          <div className="mt-4 flex flex-wrap gap-2">
            <button
              type="button"
              disabled={busy}
              onClick={onConnectFundingWallet}
              className="rounded-xl bg-white/10 px-4 py-2 text-sm font-semibold text-slate-100 hover:bg-white/20 disabled:opacity-40"
            >
              {fundingWalletAddress ? "MetaMask Connected" : "Connect MetaMask (Deposit only)"}
            </button>
            {fundingWalletAddress ? (
              <span className="self-center text-xs text-slate-400">{fundingWalletAddress}</span>
            ) : null}
          </div>
          <div className="mt-4 flex flex-wrap gap-2">
            <input
              className="min-w-48 rounded-xl border border-white/10 bg-ink-900 px-3 py-2 text-sm"
              value={amountUsdc}
              onChange={(event) => setAmountUsdc(event.target.value)}
              placeholder="USDC"
            />
            <button
              type="button"
              disabled={busy || !sessionIdentity}
              onClick={onDepositForWithExternal}
              className="rounded-xl bg-gold-400 px-4 py-2 text-sm font-semibold text-ink-950 disabled:opacity-40"
            >
              DepositFor Local Wallet
            </button>
          </div>
          {sessionIdentity ? (
            <p className="mt-2 text-xs text-slate-400">Beneficiary local wallet: {sessionIdentity.address}</p>
          ) : null}
        </section>
      ) : null}

      {page === "fiat" ? (
        <section className="glass rounded-2xl border border-white/10 p-4">
          <h2 className="font-heading text-xl">Buy With Fiat</h2>
          <p className="mt-1 text-sm text-slate-300">Sends fiat payload to backend in CRE-compatible shape.</p>
          <div className="mt-4 grid gap-2 sm:grid-cols-3">
            <select
              className="rounded-xl border border-white/10 bg-ink-900 px-3 py-2 text-sm"
              value={provider}
              onChange={(event) => setProvider(event.target.value)}
            >
              <option value="google_pay">google_pay</option>
              <option value="card">card</option>
              <option value="stripe">stripe</option>
            </select>
            <input
              className="rounded-xl border border-white/10 bg-ink-900 px-3 py-2 text-sm"
              value={fiatUsd}
              onChange={(event) => setFiatUsd(event.target.value)}
              placeholder="Amount USD"
            />
            <button
              type="button"
              disabled={busy || !user}
              onClick={onFiat}
              className="rounded-xl bg-gold-400 px-4 py-2 text-sm font-semibold text-ink-950 disabled:opacity-40"
            >
              Simulate Fiat Success
            </button>
          </div>
        </section>
      ) : null}

      {page === "positions" ? (
        <section className="glass rounded-2xl border border-white/10 p-4">
          <h2 className="font-heading text-xl">Your Router Positions</h2>
          <p className="mt-1 text-sm text-slate-300">Read from router tokenCredits using your local wallet address.</p>
          <div className="mt-4 space-y-2">
            {positions.map((item) => (
              (() => {
                const market = knownMarkets.find((entry) => entry.id === item.eventId) || null;
                const currentState = market ? effectiveMarketState(market, nowUnix) : "open";
                const resolved = currentState === "resolved";
                const review = currentState === "review";
                const outcome = market?.resolutionOutcome || null;
                const yesShares = BigInt(item.yesShares || "0");
                const noShares = BigInt(item.noShares || "0");
                const redeemable = BigInt(item.redeemableUsdc || "0");
                const isWinner =
                  outcome === "yes" ? yesShares > 0n : outcome === "no" ? noShares > 0n : false;
                const tokenWorth = resolved ? (isWinner ? redeemable : 0n) : redeemable;

                return (
                  <div key={item.eventId} className="rounded-xl border border-white/10 bg-ink-900/70 p-3 text-sm">
                    <p className="font-medium">{item.question}</p>
                    <p className="text-xs text-slate-300">Yes: {formatUsdc(item.yesShares)} / No: {formatUsdc(item.noShares)}</p>
                    <p className="text-xs text-slate-300">Complete set estimate: {formatUsdc(item.completeSetsMinted)}</p>
                    {resolved ? (
                      <>
                        <p className="text-xs text-slate-300">Resolution: {outcome || "unknown"}</p>
                        <p className={isWinner ? "text-xs text-mint-300" : "text-xs text-rose-300"}>
                          Result: {isWinner ? "correct (winning side)" : "wrong (losing side)"}
                        </p>
                        <p className="text-xs text-slate-300">Token Worth: {formatUsdc(tokenWorth.toString())} USDC</p>
                        <p className="text-xs text-slate-300">Redeemable Collateral: {formatUsdc(tokenWorth.toString())} USDC</p>
                        {market?.questionProofUrl ? (
                          <p className="text-xs text-slate-300">
                            Proof URL:{" "}
                            <a
                              className="text-sky-300 underline underline-offset-2 hover:text-sky-200"
                              href={market.questionProofUrl}
                              target="_blank"
                              rel="noreferrer"
                            >
                              {market.questionProofUrl}
                            </a>
                          </p>
                        ) : (
                          <p className="text-xs text-slate-500">Proof URL: not provided</p>
                        )}
                        <button
                          type="button"
                          disabled={busy || tokenWorth <= 0n}
                          onClick={() => onPrepareRedeemFromPosition(item)}
                          className="mt-2 rounded-xl bg-mint-500 px-3 py-1.5 text-xs font-semibold text-ink-950 hover:bg-mint-400 disabled:cursor-not-allowed disabled:opacity-40"
                        >
                          Prepare Redeem
                        </button>
                      </>
                    ) : review ? (
                      <>
                        <p className="text-xs text-amber-300">State: review/dispute window open</p>
                        <button
                          type="button"
                          disabled={busy}
                          onClick={() => onPrepareDisputeFromPosition(item)}
                          className="mt-2 rounded-xl bg-amber-300 px-3 py-1.5 text-xs font-semibold text-ink-950 hover:bg-amber-200 disabled:cursor-not-allowed disabled:opacity-40"
                        >
                          Prepare Dispute
                        </button>
                      </>
                    ) : (
                      <p className="text-xs text-slate-300">Redeemable: {formatUsdc(item.redeemableUsdc)} USDC</p>
                    )}
                  </div>
                );
              })()
            ))}
            {!positions.length ? <p className="text-sm text-slate-300">No router positions yet.</p> : null}
          </div>
        </section>
      ) : null}

      <section className="mt-4">
        <div className="glass rounded-2xl border border-white/10 p-4">
          <h3 className="font-heading text-base">Response / Logs</h3>
          <pre className="mt-2 overflow-x-auto rounded-xl border border-white/10 bg-black/30 p-3 text-xs text-slate-200">{logLine}</pre>
        </div>
      </section>
    </div>
  );
}
