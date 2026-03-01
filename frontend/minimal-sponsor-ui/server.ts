import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { join, normalize } from "node:path";
import { AbiCoder } from "ethers";

type WalletIdentity = {
  address: string;
  privateKey: string;
  publicKey: string;
};

type UserSession = {
  sessionToken: string;
  name: string;
  email: string;
  walletAddress: string;
  wallet: WalletIdentity;
  sessionWallet: WalletIdentity;
  sessionAuth: {
    sessionId: string;
    owner: string;
    sessionPublicKey: string;
    chainId: number;
    allowedActions: string[];
    maxAmountUsdc: string;
    expiresAtUnix: number;
    grantSignature: string;
    requestNonce: string;
    requestSignature: string;
  };
  vaultBalanceUsdc: bigint;
};

type MarketEvent = {
  id: string;
  marketAddress: string;
  question: string;
  closeTimeUnix: number;
  resolutionTimeUnix: number;
  state: "open" | "closed" | "resolved";
  resolutionOutcome: "yes" | "no" | null;
  yesPriceBps: number;
  noPriceBps: number;
  createdAtUnix: number;
};

type Position = {
  eventId: string;
  yesShares: bigint;
  noShares: bigint;
  completeSetsMinted: bigint;
  redeemableUsdc: bigint;
};

type SponsorApiRequest = {
  requestId?: string;
  chainId: number;
  action: string;
  actionType?: string;
  reportActionType?: string;
  amountUsdc: string;
  sender: string;
  slippageBps: number;
  reportPayloadHex?: string;
  session?: Record<string, unknown>;
};

type RevokeSessionApiRequest = {
  requestId?: string;
  sessionId: string;
  owner: string;
  chainId: number;
  revokeSignature: string;
};

type FiatPaymentSuccessApiRequest = {
  requestId?: string;
  chainId?: number;
  user?: string;
  provider?: string;
  amountUsd?: string;
  paymentId?: string;
};

type ExternalDepositFundingRequest = {
  chainId?: number;
  funder?: string;
  beneficiary?: string;
  amountUsdc?: string;
  txHash?: string;
};

type CreFiatCreditPayload = {
  requestId: string;
  paymentId: string;
  chainId: number;
  user: string;
  amountUsdc: string;
  provider: string;
};

const FALLBACK_CHAIN_CONFIG: Record<number, { executeReceiverAddress: string; collateralTokenAddress: string }> = {
  421614: {
    executeReceiverAddress: "0x3E6206fa635C74288C807ee3ba90C603a82B94A8",
    collateralTokenAddress: "0x28dF0b4CD6d0627134b708CCAfcF230bC272a663",
  },
  84532: {
    executeReceiverAddress: "0x1381A3b6d81BA62bb256607Cc2BfBBd5271DD525",
    collateralTokenAddress: "0x15a6D5380397644076f13D76B648A45B29e754bc",
  },
};

const CRE_SPONSOR_JSON_PATH = process.env.CRE_SPONSOR_JSON_PATH || join(import.meta.dir, "..", "..", "cre", "market-workflow", "sponsor.json");
const CRE_SPONSER_JSON_COMPAT_PATH = join(import.meta.dir, "..", "..", "cre", "market-workflow", "sponser.json");
const CRE_EXECUTE_JSON_PATH = process.env.CRE_EXECUTE_JSON_PATH || join(import.meta.dir, "..", "..", "cre", "market-workflow", "execute.json");
const CRE_FIAT_JSON_PATH = process.env.CRE_FIAT_JSON_PATH || join(import.meta.dir, "..", "..", "cre", "market-workflow", "fiat.json");

const ACTION_TO_REPORT_ACTION_TYPE: Record<string, string> = {
  addLiquidity: "routerAddLiquidity",
  removeLiquidity: "routerRemoveLiquidity",
  swapYesForNo: "routerSwapYesForNo",
  swapNoForYes: "routerSwapNoForYes",
  mintCompleteSets: "routerMintCompleteSets",
  redeemCompleteSets: "routerRedeemCompleteSets",
  redeem: "routerRedeem",
};

const HEX_ADDRESS_REGEX = /^0x[a-fA-F0-9]{40}$/;
const PROVIDERS = new Set(["google_pay", "card", "stripe", "mock"]);
const ALLOWED_ACTIONS = new Set(Object.keys(ACTION_TO_REPORT_ACTION_TYPE));

const sessions = new Map<string, UserSession>();
const markets = new Map<string, MarketEvent>();
const positions = new Map<string, Map<string, Position>>();
const sseControllers = new Map<number, ReadableStreamDefaultController<Uint8Array>>();
let sseId = 0;

const encoder = new TextEncoder();

const nowUnix = (): number => Math.floor(Date.now() / 1000);
const randomId = (prefix: string): string => `${prefix}_${Date.now()}_${Math.random().toString(16).slice(2, 10)}`;

const json = (status: number, payload: unknown): Response =>
  new Response(JSON.stringify(payload, null, 2), {
    status,
    headers: {
      "content-type": "application/json; charset=utf-8",
      "access-control-allow-origin": "*",
      "access-control-allow-headers": "content-type, x-session-token",
      "access-control-allow-methods": "GET,POST,OPTIONS",
    },
  });

const toErrorMessage = (error: unknown): string => (error instanceof Error ? error.message : String(error));

const toBytesHex = (length: number): string => {
  const bytes = new Uint8Array(length);
  crypto.getRandomValues(bytes);
  return Buffer.from(bytes).toString("hex");
};

const parseUsdcInteger = (value: string): bigint => {
  const raw = String(value || "").trim();
  if (!/^\d+$/.test(raw)) {
    throw new Error("amountUsdc must be a numeric string");
  }
  const amount = BigInt(raw);
  if (amount <= 0n) {
    throw new Error("amountUsdc must be greater than zero");
  }
  return amount;
};

const parseUsdToUsdcE6 = (value: string): string => {
  const raw = String(value || "").trim();
  if (!/^\d+(\.\d{1,6})?$/.test(raw)) {
    throw new Error("amountUsd must be numeric with up to 6 decimals");
  }
  const [whole, fraction = ""] = raw.split(".");
  const wholePart = BigInt(whole) * 1_000_000n;
  const fractionPart = BigInt((fraction + "000000").slice(0, 6));
  const amount = wholePart + fractionPart;
  if (amount <= 0n) {
    throw new Error("amountUsd must be greater than zero");
  }
  return amount.toString();
};

const sanitizeId = (value: string, fallbackPrefix: string): string => {
  const raw = String(value || "").trim();
  if (!raw) return `${fallbackPrefix}_${Date.now()}`;
  if (!/^[a-zA-Z0-9._:-]{6,128}$/.test(raw)) {
    throw new Error(`invalid ${fallbackPrefix}`);
  }
  return raw;
};

const normalizeSponsorSession = (session: unknown): Record<string, unknown> | undefined => {
  if (!session || typeof session !== "object") return undefined;
  const obj = session as Record<string, unknown>;
  const normalized: Record<string, unknown> = {};
  const keys = [
    "sessionId",
    "owner",
    "sessionPublicKey",
    "chainId",
    "allowedActions",
    "maxAmountUsdc",
    "expiresAtUnix",
    "grantSignature",
    "requestNonce",
    "requestSignature",
  ];
  for (const key of keys) {
    if (typeof obj[key] !== "undefined") normalized[key] = obj[key];
  }
  if (Object.keys(normalized).length === 0) return undefined;
  return normalized;
};

const buildCreSponsorRequestPayload = (body: SponsorApiRequest, actionType: string) => {
  return {
    requestId: body.requestId || `ui_${Date.now()}`,
    chainId: body.chainId,
    action: body.action,
    actionType,
    amountUsdc: body.amountUsdc,
    sender: body.sender,
    slippageBps: body.slippageBps,
    ...(normalizeSponsorSession(body.session) ? { session: normalizeSponsorSession(body.session) } : {}),
  };
};

const writeCreSponsorRequestJson = (payload: Record<string, unknown>): void => {
  const jsonText = JSON.stringify(payload, null, 2);
  writeFileSync(CRE_SPONSOR_JSON_PATH, jsonText);
  // Keep backward compatibility with the old misspelled filename already present in this repo.
  writeFileSync(CRE_SPONSER_JSON_COMPAT_PATH, jsonText);
};

const writeCreExecuteRequestJson = (payload: Record<string, unknown>): void => {
  const jsonText = JSON.stringify(payload, null, 2);
  writeFileSync(CRE_EXECUTE_JSON_PATH, jsonText);
};

const writeCreFiatRequestJson = (payload: Record<string, unknown>): void => {
  const jsonText = JSON.stringify(payload, null, 2);
  writeFileSync(CRE_FIAT_JSON_PATH, jsonText);
};

const decodeHexJson = (hex: string): Record<string, unknown> | null => {
  try {
    const clean = hex.startsWith("0x") ? hex.slice(2) : hex;
    if (!clean || clean.length % 2 !== 0) return null;
    const raw = Buffer.from(clean, "hex").toString("utf8");
    const parsed = JSON.parse(raw) as Record<string, unknown>;
    return parsed && typeof parsed === "object" ? parsed : null;
  } catch {
    return null;
  }
};

const normalizeExecutePayloadHex = (
  actionType: string,
  payloadHex: string,
  sender: string,
  amountUsdc: string
): string => {
  const raw = String(payloadHex || "").trim();
  if (!raw.startsWith("0x")) return raw;
  if (!actionType.startsWith("router")) return raw;

  const maybeJson = decodeHexJson(raw);
  if (!maybeJson) return raw;

  const marketAddress = String(maybeJson.marketAddress || "").trim();
  if (!HEX_ADDRESS_REGEX.test(sender) || !HEX_ADDRESS_REGEX.test(marketAddress) || !/^\d+$/.test(amountUsdc)) {
    return raw;
  }

  const amount = BigInt(amountUsdc);
  const coder = AbiCoder.defaultAbiCoder();
  if (actionType === "routerMintCompleteSets" || actionType === "routerRedeemCompleteSets" || actionType === "routerRedeem") {
    return coder.encode(["address", "address", "uint256"], [sender, marketAddress, amount]);
  }
  if (actionType === "routerSwapYesForNo" || actionType === "routerSwapNoForYes") {
    return coder.encode(["address", "address", "uint256", "uint256"], [sender, marketAddress, amount, 0n]);
  }
  return raw;
};

const createWallet = async (): Promise<WalletIdentity> => {
  const privateKey = `0x${toBytesHex(32)}`;
  const publicKey = `0x04${toBytesHex(64)}${toBytesHex(64)}`;
  const digest = await crypto.subtle.digest("SHA-256", encoder.encode(publicKey));
  const address = `0x${Buffer.from(digest).subarray(12).toString("hex")}`;
  return { address, privateKey, publicKey };
};

const seedMarket = (index: number): MarketEvent => {
  const start = nowUnix() + index * 120;
  const close = start + 3600;
  const resolution = close + 3600;
  const yes = 4200 + index * 350;
  return {
    id: `evt_${index}`,
    marketAddress: `0x${toBytesHex(20)}`,
    question: [
      "Will ETH close above $4,000 by Sunday?",
      "Will Base daily transactions exceed 3M this week?",
      "Will BTC ETF net inflows stay positive today?",
    ][index % 3],
    closeTimeUnix: close,
    resolutionTimeUnix: resolution,
    state: "open",
    resolutionOutcome: null,
    yesPriceBps: yes,
    noPriceBps: 10000 - yes,
    createdAtUnix: nowUnix(),
  };
};

for (let i = 0; i < 3; i += 1) {
  const item = seedMarket(i);
  markets.set(item.id, item);
}

const serializeMarket = (item: MarketEvent): MarketEvent => ({ ...item });

const serializePosition = (item: Position, question: string) => ({
  eventId: item.eventId,
  question,
  yesShares: item.yesShares.toString(),
  noShares: item.noShares.toString(),
  completeSetsMinted: item.completeSetsMinted.toString(),
  redeemableUsdc: item.redeemableUsdc.toString(),
});

const sendSse = (eventName: string, payload: unknown): void => {
  const message = encoder.encode(`event: ${eventName}\ndata: ${JSON.stringify(payload)}\n\n`);
  for (const [id, controller] of sseControllers.entries()) {
    try {
      controller.enqueue(message);
    } catch {
      sseControllers.delete(id);
    }
  }
};

const updateMarketStates = (): void => {
  const now = nowUnix();
  for (const market of markets.values()) {
    let changed = false;

    if (market.state === "open" && now >= market.closeTimeUnix) {
      market.state = "closed";
      changed = true;
    }

    if (market.state !== "resolved" && now >= market.resolutionTimeUnix) {
      market.state = "resolved";
      if (!market.resolutionOutcome) {
        market.resolutionOutcome = market.yesPriceBps >= 5000 ? "yes" : "no";
      }
      changed = true;
    }

    if (market.state === "open") {
      const drift = Math.floor(Math.random() * 360) - 180;
      market.yesPriceBps = Math.max(500, Math.min(9500, market.yesPriceBps + drift));
      market.noPriceBps = 10000 - market.yesPriceBps;
      changed = true;
    }

    if (changed) {
      sendSse("market.updated", serializeMarket(market));
    }
  }
};

setInterval(updateMarketStates, 15000);

setInterval(() => {
  const eventIndex = markets.size + 1;
  const market = {
    ...seedMarket(eventIndex),
    id: `evt_live_${Date.now()}`,
    question: `Will event #${eventIndex} settle YES by deadline?`,
  } satisfies MarketEvent;
  markets.set(market.id, market);
  sendSse("market.created", serializeMarket(market));
}, 90000);

setInterval(() => {
  for (const [id, controller] of sseControllers.entries()) {
    try {
      controller.enqueue(encoder.encode(`event: ping\ndata: ${nowUnix()}\n\n`));
    } catch {
      sseControllers.delete(id);
    }
  }
}, 25000);

const getSessionFromRequest = (req: Request): UserSession | null => {
  const url = new URL(req.url);
  const token = req.headers.get("x-session-token") || url.searchParams.get("sessionToken") || "";
  return sessions.get(token) || null;
};

const getOrCreatePosition = (session: UserSession, eventId: string): Position => {
  let userPositions = positions.get(session.sessionToken);
  if (!userPositions) {
    userPositions = new Map();
    positions.set(session.sessionToken, userPositions);
  }

  let position = userPositions.get(eventId);
  if (!position) {
    position = {
      eventId,
      yesShares: 0n,
      noShares: 0n,
      completeSetsMinted: 0n,
      redeemableUsdc: 0n,
    };
    userPositions.set(eventId, position);
  }

  return position;
};

const computePayloadHex = (payload: unknown): string => `0x${Buffer.from(JSON.stringify(payload)).toString("hex")}`;

const handleSignIn = async (req: Request): Promise<Response> => {
  const body = (await req.json().catch(() => ({}))) as {
    email?: string;
    name?: string;
    walletAddress?: string;
    sessionAddress?: string;
    sessionPublicKey?: string;
  };
  const email = String(body.email || "").trim().toLowerCase();
  const name = String(body.name || "").trim() || "Market User";
  if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) {
    return json(400, { error: "invalid email" });
  }

  const fallbackWallet = await createWallet();
  const walletAddress = String(body.walletAddress || "").trim();
  const ownerAddress = HEX_ADDRESS_REGEX.test(walletAddress) ? walletAddress : fallbackWallet.address;

  const sessionAddressRaw = String(body.sessionAddress || "").trim();
  const sessionPublicKeyRaw = String(body.sessionPublicKey || "").trim();
  const sessionWallet: WalletIdentity = {
    address: HEX_ADDRESS_REGEX.test(sessionAddressRaw) ? sessionAddressRaw : fallbackWallet.address,
    publicKey: sessionPublicKeyRaw || fallbackWallet.publicKey,
    privateKey: fallbackWallet.privateKey,
  };

  const wallet: WalletIdentity = {
    address: ownerAddress,
    publicKey: fallbackWallet.publicKey,
    privateKey: fallbackWallet.privateKey,
  };
  const sessionToken = randomId("sess");
  const sessionAuth = {
    sessionId: randomId("session"),
    owner: ownerAddress,
    sessionPublicKey: sessionWallet.publicKey,
    chainId: 84532,
    allowedActions: [...ALLOWED_ACTIONS],
    maxAmountUsdc: "10000000000",
    expiresAtUnix: nowUnix() + 86400,
    grantSignature: `0x${toBytesHex(65)}`,
    requestNonce: randomId("nonce"),
    requestSignature: `0x${toBytesHex(65)}`,
  };

  sessions.set(sessionToken, {
    sessionToken,
    name,
    email,
    walletAddress: ownerAddress,
    wallet,
    sessionWallet,
    sessionAuth,
    vaultBalanceUsdc: 0n,
  });

  console.log(
    "[MOCK_GOOGLE_SIGNIN] payload=",
    JSON.stringify({
      name,
      email,
      sessionToken,
      walletAddress: ownerAddress,
      sessionAddress: sessionWallet.address,
      sessionPublicKey: sessionWallet.publicKey,
    })
  );

  return json(200, {
    ok: true,
    user: {
      sessionToken,
      name,
      email,
      walletAddress: ownerAddress,
      vaultBalanceUsdc: "0",
      wallet: {
        address: ownerAddress,
        publicKey: wallet.publicKey,
      },
      session: {
        address: sessionWallet.address,
        publicKey: sessionWallet.publicKey,
      },
    },
  });
};

const handleExternalDepositFunding = async (req: Request): Promise<Response> => {
  const body = (await req.json().catch(() => ({}))) as ExternalDepositFundingRequest;
  const chainId = Number(body.chainId);
  const funder = String(body.funder || "").trim();
  const beneficiary = String(body.beneficiary || "").trim();
  const txHash = String(body.txHash || "").trim();

  if (!Number.isInteger(chainId) || chainId <= 0) return json(400, { error: "invalid chainId" });
  if (!HEX_ADDRESS_REGEX.test(funder)) return json(400, { error: "invalid funder address" });
  if (!HEX_ADDRESS_REGEX.test(beneficiary)) return json(400, { error: "invalid beneficiary address" });
  if (!/^0x[a-fA-F0-9]{64}$/.test(txHash)) return json(400, { error: "invalid txHash" });

  let amount: bigint;
  try {
    amount = parseUsdcInteger(String(body.amountUsdc || ""));
  } catch (error) {
    return json(400, { error: toErrorMessage(error) });
  }

  const requestId = randomId("fund_req");
  const policyPayload = {
    requestId,
    chainId,
    action: "creditFromFiat",
    actionType: "routerCreditFromFiat",
    amountUsdc: amount.toString(),
    sender: funder,
    slippageBps: 0,
    beneficiary,
    fundingTxHash: txHash,
  };
  const executePayload = {
    requestId: `${requestId}_execute`,
    chainId,
    actionType: "routerCreditFromFiat",
    payload: {
      user: beneficiary,
      amountUsdc: amount.toString(),
    },
    fundingTxHash: txHash,
  };

  console.log("[MOCK_EXTERNAL_DEPOSIT_FUNDING] payload=", JSON.stringify(policyPayload));
  console.log("[MOCK_CRE_EXECUTE] payload=", JSON.stringify(executePayload));

  return json(200, {
    ok: true,
    reason: "external funding observed; payload structured for CRE credit flow",
    policyPayload,
    executePayload,
  });
};

const handleEvents = (req: Request): Response => {
  const session = getSessionFromRequest(req);
  if (!session) return json(401, { error: "missing or invalid session" });

  updateMarketStates();
  const items = [...markets.values()]
    .sort((a, b) => b.createdAtUnix - a.createdAtUnix)
    .map((item) => serializeMarket(item));

  return json(200, {
    events: items,
    vaultBalanceUsdc: session.vaultBalanceUsdc.toString(),
  });
};

const handleEventStream = (req: Request): Response => {
  const session = getSessionFromRequest(req);
  if (!session) return json(401, { error: "missing or invalid session" });

  let streamClientId = 0;
  const stream = new ReadableStream<Uint8Array>({
    start(controller) {
      streamClientId = ++sseId;
      sseControllers.set(streamClientId, controller);
      controller.enqueue(encoder.encode(`event: ready\ndata: ${JSON.stringify({ sessionToken: session.sessionToken })}\n\n`));
      for (const market of markets.values()) {
        controller.enqueue(encoder.encode(`event: market.updated\ndata: ${JSON.stringify(serializeMarket(market))}\n\n`));
      }
    },
    cancel() {
      if (streamClientId) sseControllers.delete(streamClientId);
    },
  });

  return new Response(stream, {
    headers: {
      "content-type": "text/event-stream; charset=utf-8",
      "cache-control": "no-cache",
      connection: "keep-alive",
      "access-control-allow-origin": "*",
    },
  });
};

const handlePositions = (req: Request): Response => {
  const session = getSessionFromRequest(req);
  if (!session) return json(401, { error: "missing or invalid session" });

  const userPositions = positions.get(session.sessionToken) || new Map<string, Position>();
  const response = [...userPositions.values()].map((entry) => {
    const market = markets.get(entry.eventId);
    const question = market?.question || "Unknown market";
    return serializePosition(entry, question);
  });

  return json(200, {
    positions: response,
    vaultBalanceUsdc: session.vaultBalanceUsdc.toString(),
  });
};

const handleVaultDeposit = async (req: Request): Promise<Response> => {
  const session = getSessionFromRequest(req);
  if (!session) return json(401, { error: "missing or invalid session" });

  const body = (await req.json().catch(() => ({}))) as { amountUsdc?: string };
  let amount: bigint;
  try {
    amount = parseUsdcInteger(String(body.amountUsdc || ""));
  } catch (error) {
    return json(400, { error: toErrorMessage(error) });
  }

  session.vaultBalanceUsdc += amount;

  console.log(
    "[MOCK_VAULT_DEPOSIT] payload=",
    JSON.stringify({
      sessionToken: session.sessionToken,
      user: session.walletAddress,
      amountUsdc: amount.toString(),
      requiresUserGas: true,
      note: "structured like direct approve+deposit, credited in mock backend",
    })
  );

  return json(200, {
    ok: true,
    note: "deposit intent logged; mock credited in backend",
    vaultBalanceUsdc: session.vaultBalanceUsdc.toString(),
  });
};

const handleFiatPaymentSuccess = async (req: Request): Promise<Response> => {
  const session = getSessionFromRequest(req);
  if (!session) return json(401, { error: "missing or invalid session" });

  const body = (await req.json().catch(() => ({}))) as FiatPaymentSuccessApiRequest;
  const chainId = Number(body.chainId);
  if (!Number.isInteger(chainId) || chainId <= 0) {
    return json(400, { error: "invalid chainId" });
  }

  const provider = String(body.provider || "").trim().toLowerCase();
  if (!PROVIDERS.has(provider)) {
    return json(400, { error: "invalid provider" });
  }

  let requestId: string;
  let paymentId: string;
  let amountUsdc: string;
  try {
    requestId = sanitizeId(body.requestId || "", "fiat_req");
    paymentId = sanitizeId(body.paymentId || "", "pay");
    amountUsdc = parseUsdToUsdcE6(String(body.amountUsd || ""));
  } catch (error) {
    return json(400, { error: toErrorMessage(error) });
  }

  const providerSuccess = {
    provider,
    paymentId,
    status: "success",
    user: session.walletAddress,
    chainId,
    amountUsd: String(body.amountUsd || "").trim(),
    settledAtUnix: nowUnix(),
  };

  const crePayload: CreFiatCreditPayload = {
    requestId,
    paymentId,
    chainId,
    user: session.walletAddress,
    amountUsdc,
    provider,
  };

  session.vaultBalanceUsdc += BigInt(amountUsdc);
  writeCreFiatRequestJson(crePayload);

  console.log("[MOCK_PROVIDER_SUCCESS] payload=", JSON.stringify(providerSuccess));
  console.log("[MOCK_CRE_FIAT_CREDIT] payload=", JSON.stringify(crePayload));
  console.log("[MOCK_CRE_FIAT_CREDIT] wrote fiat request json:", CRE_FIAT_JSON_PATH);

  return json(200, {
    ok: true,
    sentToCre: false,
    reason: "payload structured and written for CRE fiat HTTP handler",
    providerSuccess,
    crePayload,
    fiatJsonPath: CRE_FIAT_JSON_PATH,
    vaultBalanceUsdc: session.vaultBalanceUsdc.toString(),
  });
};

const handleSponsor = async (req: Request): Promise<Response> => {
  const body = (await req.json().catch(() => null)) as SponsorApiRequest | null;
  if (!body) return json(400, { error: "invalid JSON body" });

  const actionType = (body.actionType || body.reportActionType || "").trim();
  if (!actionType || !body.reportPayloadHex) {
    return json(400, {
      approved: false,
      stage: "cre-execute",
      error: "missing actionType/reportPayloadHex",
    });
  }

  const policyPayload = buildCreSponsorRequestPayload(body, actionType);
  writeCreSponsorRequestJson(policyPayload);
  console.log("[MOCK_CRE_POLICY] payload=", JSON.stringify(policyPayload));
  console.log("[MOCK_CRE_POLICY] wrote sponsor request json:", CRE_SPONSOR_JSON_PATH);

  const creDecision = {
    approved: true,
    approvalId: `mock_approval_${Date.now()}`,
    reason: "mocked policy approval",
    requestId: policyPayload.requestId,
  };

  const executePayload = {
    requestId: `${policyPayload.requestId}_exec`,
    approvalId: creDecision.approvalId,
    chainId: body.chainId,
    amountUsdc: body.amountUsdc,
    actionType,
    payloadHex: normalizeExecutePayloadHex(actionType, body.reportPayloadHex, body.sender, body.amountUsdc),
  };
  writeCreExecuteRequestJson(executePayload);
  console.log("[MOCK_CRE_EXECUTE] payload=", JSON.stringify(executePayload));
  console.log("[MOCK_CRE_EXECUTE] wrote execute request json:", CRE_EXECUTE_JSON_PATH);

  return json(200, {
    approved: true,
    stage: "cre-execute",
    creDecision,
    sponsorJsonPath: CRE_SPONSOR_JSON_PATH,
    executeJsonPath: CRE_EXECUTE_JSON_PATH,
    execute: {
      submitted: true,
      requestId: executePayload.requestId,
      reason: "mocked execute submission",
    },
  });
};

const handleMarketAction = async (req: Request): Promise<Response> => {
  const session = getSessionFromRequest(req);
  if (!session) return json(401, { error: "missing or invalid session" });

  const body = (await req.json().catch(() => null)) as
    | { eventId?: string; action?: string; amountUsdc?: string; slippageBps?: number }
    | null;
  if (!body) return json(400, { error: "invalid JSON body" });

  const eventId = String(body.eventId || "").trim();
  const action = String(body.action || "").trim();
  const market = markets.get(eventId);
  if (!market) return json(404, { error: "event not found" });
  if (!ALLOWED_ACTIONS.has(action)) return json(400, { error: "action not allowed" });

  updateMarketStates();

  if (market.state === "closed") {
    return json(400, { error: "event closed; no actions allowed until resolution" });
  }
  if (market.state === "resolved" && action !== "redeem") {
    return json(400, { error: "only redeem is allowed after resolution" });
  }
  if (market.state === "open" && action === "redeem") {
    return json(400, { error: "redeem is only allowed after resolution" });
  }

  let amount: bigint;
  try {
    amount = parseUsdcInteger(String(body.amountUsdc || ""));
  } catch (error) {
    return json(400, { error: toErrorMessage(error) });
  }

  const position = getOrCreatePosition(session, eventId);

  if ((action === "mintCompleteSets" || action === "redeemCompleteSets") && session.vaultBalanceUsdc < amount && action === "mintCompleteSets") {
    return json(400, { error: "insufficient vault collateral" });
  }

  if ((action === "swapYesForNo" || action === "swapNoForYes") && position.completeSetsMinted <= 0n) {
    return json(400, { error: "mint complete sets first before swapping" });
  }

  if (action === "mintCompleteSets") {
    session.vaultBalanceUsdc -= amount;
    position.yesShares += amount;
    position.noShares += amount;
    position.completeSetsMinted += amount;
  } else if (action === "swapYesForNo") {
    if (position.yesShares < amount) return json(400, { error: "not enough YES shares" });
    const out = (amount * BigInt(market.yesPriceBps)) / BigInt(Math.max(market.noPriceBps, 1));
    position.yesShares -= amount;
    position.noShares += out > 0n ? out : 1n;
  } else if (action === "swapNoForYes") {
    if (position.noShares < amount) return json(400, { error: "not enough NO shares" });
    const out = (amount * BigInt(market.noPriceBps)) / BigInt(Math.max(market.yesPriceBps, 1));
    position.noShares -= amount;
    position.yesShares += out > 0n ? out : 1n;
  } else if (action === "redeemCompleteSets") {
    if (position.yesShares < amount || position.noShares < amount) {
      return json(400, { error: "not enough complete sets to redeem" });
    }
    position.yesShares -= amount;
    position.noShares -= amount;
    position.completeSetsMinted = position.completeSetsMinted > amount ? position.completeSetsMinted - amount : 0n;
    session.vaultBalanceUsdc += amount;
  } else if (action === "redeem") {
    const winning = market.resolutionOutcome === "yes" ? position.yesShares : position.noShares;
    if (winning <= 0n) return json(400, { error: "no winning shares to redeem" });
    const redeemAmount = amount > winning ? winning : amount;
    if (market.resolutionOutcome === "yes") {
      position.yesShares -= redeemAmount;
    } else {
      position.noShares -= redeemAmount;
    }
    session.vaultBalanceUsdc += redeemAmount;
  }

  if (market.state === "resolved") {
    position.redeemableUsdc = market.resolutionOutcome === "yes" ? position.yesShares : position.noShares;
  } else {
    position.redeemableUsdc = 0n;
  }

  const actionType = ACTION_TO_REPORT_ACTION_TYPE[action] || "routerUnknown";
  const requestId = randomId("req");
  const payloadHex = computePayloadHex({
    eventId: market.id,
    marketAddress: market.marketAddress,
    action,
    amountUsdc: amount.toString(),
    yesPriceBps: market.yesPriceBps,
    noPriceBps: market.noPriceBps,
    atUnix: nowUnix(),
  });

  const policyPayload = {
    requestId,
    chainId: 84532,
    action,
    actionType,
    reportActionType: actionType,
    amountUsdc: amount.toString(),
    sender: session.walletAddress,
    slippageBps: Number.isFinite(body.slippageBps) ? Number(body.slippageBps) : 120,
    session: session.sessionAuth,
  };

  const creDecision = {
    approved: true,
    reason: "approved by mock policy",
    requestId,
    approvalId: `cre_approval_${Date.now()}_${requestId.slice(-8)}`,
    approvalExpiresAtUnix: nowUnix() + 360,
  };

  const executePayload = {
    requestId: `${requestId}_execute`,
    approvalId: creDecision.approvalId,
    chainId: 84532,
    amountUsdc: amount.toString(),
    actionType,
    payloadHex,
  };

  console.log("[MOCK_CRE_POLICY] payload=", JSON.stringify(policyPayload));
  console.log("[MOCK_CRE_EXECUTE] payload=", JSON.stringify(executePayload));

  return json(200, {
    ok: true,
    reason: "action accepted and mocked through sponsor+execute",
    requestId,
    policyPayload,
    executePayload,
    decision: creDecision,
    position: serializePosition(position, market.question),
    vaultBalanceUsdc: session.vaultBalanceUsdc.toString(),
  });
};

const handleChainConfig = (req: Request): Response => {
  const chainIdRaw = new URL(req.url).searchParams.get("chainId");
  const chainId = chainIdRaw ? Number(chainIdRaw) : NaN;
  if (!Number.isInteger(chainId) || chainId <= 0) {
    return json(400, { error: "invalid chainId" });
  }

  const fallback = FALLBACK_CHAIN_CONFIG[chainId];
  return json(200, {
    chainId,
    executeReceiverAddress: fallback?.executeReceiverAddress || "",
    collateralTokenAddress: fallback?.collateralTokenAddress || "",
  });
};

const handleSessionRevoke = async (req: Request): Promise<Response> => {
  const body = (await req.json().catch(() => null)) as RevokeSessionApiRequest | null;
  if (!body) return json(400, { error: "invalid JSON body" });

  const revokePayload = {
    requestId: body.requestId || `revoke_${Date.now()}`,
    sessionId: body.sessionId,
    owner: body.owner,
    chainId: body.chainId,
    revokeSignature: body.revokeSignature,
  };
  console.log("[MOCK_CRE_REVOKE] payload=", JSON.stringify(revokePayload));

  for (const [token, session] of sessions.entries()) {
    if (session.sessionAuth.sessionId === body.sessionId) {
      sessions.delete(token);
      positions.delete(token);
    }
  }

  return json(200, {
    revoked: true,
    requestId: revokePayload.requestId,
    reason: "mocked revoke accepted",
  });
};

const MIME_BY_EXT: Record<string, string> = {
  ".html": "text/html; charset=utf-8",
  ".js": "text/javascript; charset=utf-8",
  ".css": "text/css; charset=utf-8",
  ".json": "application/json; charset=utf-8",
  ".svg": "image/svg+xml",
  ".png": "image/png",
  ".jpg": "image/jpeg",
  ".jpeg": "image/jpeg",
  ".ico": "image/x-icon",
};

const tryServeDist = (urlPathname: string): Response | null => {
  const distDir = join(import.meta.dir, "dist");
  if (!existsSync(distDir)) return null;

  const safePath = normalize(urlPathname).replace(/^\/+/, "");
  const filePath = join(distDir, safePath || "index.html");
  if (existsSync(filePath)) {
    const ext = filePath.slice(filePath.lastIndexOf("."));
    return new Response(readFileSync(filePath), {
      headers: { "content-type": MIME_BY_EXT[ext] || "application/octet-stream" },
    });
  }

  const indexPath = join(distDir, "index.html");
  if (existsSync(indexPath)) {
    return new Response(readFileSync(indexPath), {
      headers: { "content-type": "text/html; charset=utf-8" },
    });
  }

  return null;
};

const port = Number(process.env.PORT || 5173);

const server = Bun.serve({
  port,
  async fetch(req) {
    if (req.method === "OPTIONS") {
      return new Response(null, {
        status: 204,
        headers: {
          "access-control-allow-origin": "*",
          "access-control-allow-headers": "content-type, x-session-token",
          "access-control-allow-methods": "GET,POST,OPTIONS",
        },
      });
    }

    const url = new URL(req.url);

    try {
      if (url.pathname === "/api/auth/google/mock" && req.method === "POST") return await handleSignIn(req);
      if (url.pathname === "/api/events" && req.method === "GET") return handleEvents(req);
      if (url.pathname === "/api/events/stream" && req.method === "GET") return handleEventStream(req);
      if (url.pathname === "/api/positions" && req.method === "GET") return handlePositions(req);
      if (url.pathname === "/api/vault/deposit" && req.method === "POST") return await handleVaultDeposit(req);
      if (url.pathname === "/api/fiat-payment-success" && req.method === "POST") return await handleFiatPaymentSuccess(req);
      if (url.pathname === "/api/funding/external-deposit" && req.method === "POST") return await handleExternalDepositFunding(req);
      if (url.pathname === "/api/market-actions" && req.method === "POST") return await handleMarketAction(req);
      if (url.pathname === "/api/sponsor" && req.method === "POST") return await handleSponsor(req);
      if (url.pathname === "/api/session/revoke" && req.method === "POST") return await handleSessionRevoke(req);
      if (url.pathname === "/api/chain-config" && req.method === "GET") return handleChainConfig(req);
      if (url.pathname === "/api/health" && req.method === "GET") return json(200, { ok: true, nowUnix: nowUnix() });
    } catch (error) {
      console.error("[API_ERROR]", error);
      return json(500, { error: "internal server error", detail: toErrorMessage(error) });
    }

    const staticRes = tryServeDist(url.pathname);
    if (staticRes) return staticRes;

    return new Response(
      [
        "Frontend dist not found.",
        "Run frontend dev server: bun run frontend:dev",
        "Backend API server: bun run dev",
        "Frontend URL: http://localhost:5174",
      ].join("\n"),
      {
        status: 200,
        headers: { "content-type": "text/plain; charset=utf-8" },
      }
    );
  },
});

console.log(`Backend running at http://localhost:${server.port}`);
console.log("Frontend dev expected at http://localhost:5174");
