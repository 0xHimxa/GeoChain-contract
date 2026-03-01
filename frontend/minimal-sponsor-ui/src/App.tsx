import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { BrowserProvider, Contract, Wallet, formatUnits, parseUnits, type Eip1193Provider } from "ethers";
import { signInWithGoogleAndSession, submitAction, submitExternalDepositFunding, submitFiatPayment } from "./api";
import {
  CHAIN_CONFIG,
  ERC20_ABI,
  MARKET_CREATED_TOPIC,
  MARKET_FACTORY_ABI,
  ROUTER_ABI,
  decodeMarketCreatedLog,
  loadMarketSnapshot,
  providerForChain,
  type SupportedChainId,
} from "./chain";
import { clearStoredWallet, createOrLoadWallet, getStoredWalletMeta } from "./keyVault";
import type { MarketEvent, Position, SessionIdentity, UiPage, UserProfile } from "./types";

const ACTIONS = ["mintCompleteSets", "swapYesForNo", "swapNoForYes", "redeemCompleteSets", "redeem"] as const;
const ACTION_TYPE_MAP: Record<(typeof ACTIONS)[number], string> = {
  mintCompleteSets: "routerMintCompleteSets",
  swapYesForNo: "routerSwapYesForNo",
  swapNoForYes: "routerSwapNoForYes",
  redeemCompleteSets: "routerRedeemCompleteSets",
  redeem: "routerRedeem",
};

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
  resolved: "text-rose-400",
};

const encodeJsonHex = (payload: unknown): string => {
  const asBytes = new TextEncoder().encode(JSON.stringify(payload));
  const hex = Array.from(asBytes)
    .map((value) => value.toString(16).padStart(2, "0"))
    .join("");
  return `0x${hex}`;
};

const effectiveMarketState = (event: MarketEvent, nowUnix: number): MarketEvent["state"] => {
  if (event.state === "resolved") return "resolved";
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
  const [nowUnix, setNowUnix] = useState<number>(Math.floor(Date.now() / 1000));
  const [busy, setBusy] = useState(false);
  const [logLine, setLogLine] = useState("Waiting for action...");

  const seenMarketSetRef = useRef<Set<string>>(new Set());
  const lastSeenBlockRef = useRef<bigint>(0n);

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

  const walletAddress = sessionIdentity?.address || "";

  const getFundingProvider = useCallback(() => {
    const ethereum = (window as Window & { ethereum?: Eip1193Provider }).ethereum;
    if (!ethereum) throw new Error("No external wallet found. Install MetaMask.");
    return new BrowserProvider(ethereum);
  }, []);

  const selectedEvent = useMemo(
    () => events.find((item) => item.id === selectedEventId) || events[0] || null,
    [events, selectedEventId]
  );

  const groupedEvents = useMemo(() => {
    const active: MarketEvent[] = [];
    const closed: MarketEvent[] = [];
    const resolved: MarketEvent[] = [];
    for (const item of events) {
      const state = effectiveMarketState(item, nowUnix);
      if (state === "open") active.push(item);
      else if (state === "closed") closed.push(item);
      else resolved.push(item);
    }
    return { active, closed, resolved };
  }, [events, nowUnix]);

  useEffect(() => {
    if (!events.length) {
      if (selectedEventId) setSelectedEventId("");
      return;
    }
    const exists = events.some((item) => item.id === selectedEventId);
    if (!exists) setSelectedEventId(events[0].id);
  }, [events, selectedEventId]);

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
    const cfg = CHAIN_CONFIG[selectedChain];
    const provider = providerForChain(selectedChain);
    const factory = new Contract(cfg.addresses.marketFactory, MARKET_FACTORY_ABI, provider);

    let marketAddresses: string[] = [];
    try {
      const marketCount = Number(await factory.marketCount());
      const ids = Array.from({ length: marketCount }, (_, index) => index + 1);
      const byId = await Promise.all(
        ids.map(async (id) => {
          try {
            return String(await factory.marketById(id)).toLowerCase();
          } catch {
            return "";
          }
        })
      );
      marketAddresses = byId.filter(
        (address): address is string =>
          Boolean(address) && address !== "0x0000000000000000000000000000000000000000"
      );
    } catch {
      try {
        // Fallback for older deployments where marketById/marketCount is unstable.
        marketAddresses = ((await factory.getActiveEventList()) as string[]).map((value) => value.toLowerCase());
      } catch {
        const latest = await provider.getBlockNumber();
        const logs = await provider.getLogs({
          address: cfg.addresses.marketFactory,
          topics: [MARKET_CREATED_TOPIC],
          fromBlock: 0,
          toBlock: latest,
        });
        marketAddresses = logs
          .map((log) => decodeMarketCreatedLog(log)?.market.toLowerCase() || "")
          .filter((address): address is string => Boolean(address));
      }
    }

    marketAddresses = [...new Set(marketAddresses)];
    seenMarketSetRef.current = new Set(marketAddresses);
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

    setEvents((current) => {
      const currentByAddress = new Map(current.map((item) => [item.marketAddress.toLowerCase(), item]));
      const merged: MarketEvent[] = [];

      for (const address of marketAddresses) {
        const next = snapshotByAddress.get(address) || currentByAddress.get(address);
        if (next) merged.push(next);
      }

      merged.sort((a, b) => a.closeTimeUnix - b.closeTimeUnix);
      return merged;
    });

    setSelectedEventId((currentSelected) => {
      if (currentSelected) return currentSelected;
      const first = snapshots.find((item) => item.snapshot !== null)?.snapshot;
      return first?.id || "";
    });
    lastSeenBlockRef.current = BigInt(await provider.getBlockNumber());
  }, [selectedChain]);

  const refreshPositions = useCallback(async () => {
    if (!walletAddress || !events.length) {
      setPositions([]);
      return;
    }

    const cfg = CHAIN_CONFIG[selectedChain];
    const provider = providerForChain(selectedChain);
    const router = new Contract(cfg.addresses.router, ROUTER_ABI, provider);

    const rows = await Promise.all(
      events.map(async (event) => {
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

    setPositions(rows.filter((value): value is Position => Boolean(value)));
  }, [events, selectedChain, walletAddress]);

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

  useEffect(() => {
    const timer = setInterval(async () => {
      try {
        const cfg = CHAIN_CONFIG[selectedChain];
        const provider = providerForChain(selectedChain);
        const latest = BigInt(await provider.getBlockNumber());
        const fromBlock = lastSeenBlockRef.current + 1n;
        if (latest < fromBlock) return;

        const logs = await provider.getLogs({
          address: cfg.addresses.marketFactory,
          topics: [MARKET_CREATED_TOPIC],
          fromBlock,
          toBlock: latest,
        });

        lastSeenBlockRef.current = latest;
        if (!logs.length) return;

        for (const log of logs) {
          const decoded = decodeMarketCreatedLog(log);
          if (!decoded) continue;
          const marketLower = decoded.market.toLowerCase();
          if (seenMarketSetRef.current.has(marketLower)) continue;
          seenMarketSetRef.current.add(marketLower);

          const snapshot = await loadMarketSnapshot(selectedChain, decoded.market);
          setEvents((current) => [snapshot, ...current]);
          setSelectedEventId((current) => current || snapshot.id);
          setLogLine(`New market detected onchain: ${snapshot.question}`);
        }
      } catch {
        // retry on next poll
      }
    }, 8000);

    return () => clearInterval(timer);
  }, [selectedChain]);

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
      });
      setLogLine(JSON.stringify(res, null, 2));
    } catch (error) {
      setLogLine(`Fiat failed: ${String(error)}`);
    } finally {
      setBusy(false);
    }
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

    setBusy(true);
    try {
      const amount = parseUnits(amountUsdc || "0", 6);
      const actionType = ACTION_TYPE_MAP[activeAction];
      const operation = {
        marketAddress: selectedEvent.marketAddress,
        marketId: selectedEvent.marketId,
        chainId: selectedChain,
        action: activeAction,
        amountUsdc: amount.toString(),
        atUnix: nowUnix,
      };

      const signer = new Wallet(sessionIdentity.privateKey);
      const nonce = `${nowUnix}_${Math.random().toString(16).slice(2, 10)}`;
      const deadline = nowUnix + 360;
      const typedDomain = {
        name: "CRE Session Authorization",
        version: "1",
        chainId: selectedChain,
        verifyingContract: CHAIN_CONFIG[selectedChain].addresses.router,
      };
      const typedTypes = {
        SessionRequest: [
          { name: "sessionId", type: "string" },
          { name: "owner", type: "address" },
          { name: "action", type: "string" },
          { name: "actionType", type: "string" },
          { name: "market", type: "address" },
          { name: "amountUsdc", type: "uint256" },
          { name: "slippageBps", type: "uint256" },
          { name: "nonce", type: "string" },
          { name: "deadline", type: "uint256" },
        ],
      };
      const typedValue = {
        sessionId: `sess_${sessionIdentity.address.slice(2, 10)}`,
        owner: sessionIdentity.address,
        action: activeAction,
        actionType,
        market: selectedEvent.marketAddress,
        amountUsdc: amount.toString(),
        slippageBps: 120,
        nonce,
        deadline,
      };
      const requestSignature = await signer.signTypedData(typedDomain, typedTypes, typedValue);

      const res = await submitAction({
        chainId: selectedChain,
        action: activeAction,
        actionType,
        amountUsdc: amount.toString(),
        sender: sessionIdentity.address,
        slippageBps: 120,
        reportPayloadHex: encodeJsonHex(operation),
        session: {
          sessionId: typedValue.sessionId,
          owner: sessionIdentity.address,
          sessionPublicKey: sessionIdentity.publicKey,
          requestNonce: nonce,
          deadline,
          typedData: {
            domain: typedDomain,
            types: typedTypes,
            value: typedValue,
          },
          requestSignature,
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
    return false;
  }, [selectedEvent, selectedEventState, activeAction]);

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

                {selectedEventState === "closed" ? (
                  <p className="mt-2 text-xs text-gold-400">Market closed. Trading disabled.</p>
                ) : null}
                {selectedEventState === "resolved" && activeAction !== "redeem" ? (
                  <p className="mt-2 text-xs text-rose-400">Market resolved. Select redeem to claim winnings.</p>
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
              <div key={item.eventId} className="rounded-xl border border-white/10 bg-ink-900/70 p-3 text-sm">
                <p className="font-medium">{item.question}</p>
                <p className="text-xs text-slate-300">Yes: {formatUsdc(item.yesShares)} / No: {formatUsdc(item.noShares)}</p>
                <p className="text-xs text-slate-300">Complete set estimate: {formatUsdc(item.completeSetsMinted)}</p>
                <p className="text-xs text-slate-300">Redeemable: {formatUsdc(item.redeemableUsdc)} USDC</p>
              </div>
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
