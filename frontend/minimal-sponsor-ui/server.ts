import { readFileSync } from "node:fs";
import { join } from "node:path";

type SponsorApiRequest = {
  requestId?: string;
  chainId: number;
  action: string;
  amountUsdc: string;
  sender: string;
  slippageBps: number;
  actionType?: string;
  reportActionType?: string;
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

type CreFiatCreditPayload = {
  requestId: string;
  paymentId: string;
  chainId: number;
  user: string;
  amountUsdc: string;
  provider: string;
};

type CreEvmConfig = {
  chainName?: string;
  routerReceiverAddress?: string;
  collateralTokenAddress?: string;
};

type CreConfig = {
  evms?: CreEvmConfig[];
};

const indexHtml = readFileSync(join(import.meta.dir, "index.html"), "utf-8");
const fiatPaymentHtml = readFileSync(join(import.meta.dir, "fiat-payment.html"), "utf-8");
const creConfigPath = process.env.CRE_CONFIG_PATH || join(import.meta.dir, "..", "..", "cre", "market-workflow", "config.staging.json");
const FALLBACK_CHAIN_CONFIG: Record<number, { executeReceiverAddress: string; collateralTokenAddress: string }> = {
  421614: {
    executeReceiverAddress: "0xAD51b51Ea9347CBaB070311f07d2C7659d8D8c78",
    collateralTokenAddress: "0x8eaE35b8DC918BE54b2fAA57c9Bb0D4E13B9C9CB",
  },
  84532: {
    executeReceiverAddress: "0x075B30906d48f922A643bBa218724a84931DC1BA",
    collateralTokenAddress: "0xf3B85Ebc920e036c8Dc04179d35ac526a08EDAa8",
  },
};

const toChainId = (chainName: string): number | null => {
  if (chainName.includes("arbitrum")) return 421614;
  if (chainName.includes("base")) return 84532;
  if (chainName === "ethereum-testnet-sepolia") return 11155111;
  return null;
};

const readCreConfig = (): CreConfig => {
  try {
    return JSON.parse(readFileSync(creConfigPath, "utf-8")) as CreConfig;
  } catch {
    return {};
  }
};

const json = (status: number, payload: unknown) =>
  new Response(JSON.stringify(payload, null, 2), {
    status,
    headers: {
      "content-type": "application/json; charset=utf-8",
      "access-control-allow-origin": "*",
      "access-control-allow-headers": "content-type",
    },
  });

const toErrorMessage = (error: unknown): string => (error instanceof Error ? error.message : String(error));

// Local mock endpoint:
// 1) logs policy payload
// 2) logs execute payload
const handleSponsor = async (req: Request): Promise<Response> => {
  let body: SponsorApiRequest;
  try {
    body = (await req.json()) as SponsorApiRequest;
  } catch {
    return json(400, { error: "invalid JSON body" });
  }
  const actionType = (body.actionType || body.reportActionType || "").trim();
  console.log(
    "[MOCK_CRE_POLICY] actionType_debug=",
    JSON.stringify({
      normalizedActionType: actionType || null,
      actionType: body.actionType ?? null,
      reportActionType: body.reportActionType ?? null,
      keys: Object.keys(body),
    })
  );
  const crePayload = {
    requestId: body.requestId || `ui_${Date.now()}`,
    chainId: body.chainId,
    action: body.action,
    amountUsdc: body.amountUsdc,
    sender: body.sender,
    slippageBps: body.slippageBps,
    session: body.session,
    actionType,
  
  };
  console.log("[MOCK_CRE_POLICY] payload=", JSON.stringify(crePayload));

  const creDecision = {
    approved: true,
    approvalId: `mock_approval_${Date.now()}`,
    reason: "mocked policy approval",
    requestId: crePayload.requestId,
  };

  if (!actionType || !body.reportPayloadHex) {
    return json(400, {
      approved: false,
      stage: "cre-execute",
      error: "missing actionType/reportPayloadHex",
      received: {
        actionType: body.actionType ?? null,
        reportActionType: body.reportActionType ?? null,
        reportPayloadHex: body.reportPayloadHex ?? null,
      },
    });
  }

  const executePayload = {
    requestId: `${body.requestId || `ui_${Date.now()}`}_exec`,
    approvalId: creDecision.approvalId,
    chainId: body.chainId,
    amountUsdc: body.amountUsdc,
    actionType,
    payloadHex: body.reportPayloadHex,
  };
  console.log("[MOCK_CRE_EXECUTE] payload=", JSON.stringify(executePayload));

  const executeJson = {
    submitted: true,
    requestId: executePayload.requestId,
    reason: "mocked execute submission",
  };

  return json(200, {
    approved: true,
    stage: "cre-execute",
    creDecision,
    execute: executeJson,
  });
};

const handleChainConfig = (req: Request): Response => {
  const chainIdRaw = new URL(req.url).searchParams.get("chainId");
  const chainId = chainIdRaw ? Number(chainIdRaw) : NaN;
  if (!Number.isInteger(chainId) || chainId <= 0) {
    return json(400, { error: "invalid chainId" });
  }

  const cfg = readCreConfig();
  const evm = (cfg.evms || []).find((item) => item.chainName && toChainId(item.chainName) === chainId);
  const fallback = FALLBACK_CHAIN_CONFIG[chainId];
  return json(200, {
    chainId,
    executeReceiverAddress: evm?.routerReceiverAddress || fallback?.executeReceiverAddress || "",
    collateralTokenAddress: evm?.collateralTokenAddress || fallback?.collateralTokenAddress || "",
    configPath: creConfigPath,
  });
};

const handleSessionRevoke = async (req: Request): Promise<Response> => {
  let body: RevokeSessionApiRequest;
  try {
    body = (await req.json()) as RevokeSessionApiRequest;
  } catch {
    return json(400, { error: "invalid JSON body" });
  }

  const revokePayload = {
    requestId: body.requestId || `revoke_${Date.now()}`,
    sessionId: body.sessionId,
    owner: body.owner,
    chainId: body.chainId,
    revokeSignature: body.revokeSignature,
  };
  console.log("[MOCK_CRE_REVOKE] payload=", JSON.stringify(revokePayload));
  return json(200, {
    revoked: true,
    requestId: revokePayload.requestId,
    reason: "mocked revoke accepted",
  });
};

const HEX_ADDRESS_REGEX = /^0x[a-fA-F0-9]{40}$/;
const PROVIDERS = new Set(["google_pay", "card", "stripe", "mock"]);

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

const handleFiatPaymentSuccess = async (req: Request): Promise<Response> => {
  let body: FiatPaymentSuccessApiRequest;
  try {
    body = (await req.json()) as FiatPaymentSuccessApiRequest;
  } catch {
    return json(400, { error: "invalid JSON body" });
  }

  const chainId = Number(body.chainId);
  if (!Number.isInteger(chainId) || chainId <= 0) {
    return json(400, { error: "invalid chainId" });
  }

  const user = String(body.user || "").trim();
  if (!HEX_ADDRESS_REGEX.test(user)) {
    return json(400, { error: "invalid user address" });
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
    user,
    chainId,
    amountUsd: String(body.amountUsd || "").trim(),
    settledAtUnix: Math.floor(Date.now() / 1000),
  };

  const crePayload: CreFiatCreditPayload = {
    requestId,
    paymentId,
    chainId,
    user,
    amountUsdc,
    provider,
  };

  console.log("[MOCK_PROVIDER_SUCCESS] payload=", JSON.stringify(providerSuccess));
  console.log("[MOCK_CRE_FIAT_CREDIT] payload=", JSON.stringify(crePayload));

  return json(200, {
    ok: true,
    sentToCre: false,
    reason: "payload structured and logged only",
    providerSuccess,
    crePayload,
  });
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
          "access-control-allow-headers": "content-type",
          "access-control-allow-methods": "GET,POST,OPTIONS",
        },
      });
    }

    const url = new URL(req.url);
    if (url.pathname === "/api/sponsor" && req.method === "POST") {
      try {
        return await handleSponsor(req);
      } catch (error) {
        console.error("[API_SPONSOR_ERROR]", error);
        return json(500, { error: "internal sponsor error", detail: toErrorMessage(error) });
      }
    }
    if (url.pathname === "/api/chain-config" && req.method === "GET") {
      try {
        return handleChainConfig(req);
      } catch (error) {
        console.error("[API_CHAIN_CONFIG_ERROR]", error);
        return json(500, { error: "internal chain-config error", detail: toErrorMessage(error) });
      }
    }
    if (url.pathname === "/api/session/revoke" && req.method === "POST") {
      try {
        return await handleSessionRevoke(req);
      } catch (error) {
        console.error("[API_REVOKE_ERROR]", error);
        return json(500, { error: "internal revoke error", detail: toErrorMessage(error) });
      }
    }
    if (url.pathname === "/api/fiat-payment-success" && req.method === "POST") {
      try {
        return await handleFiatPaymentSuccess(req);
      } catch (error) {
        console.error("[API_FIAT_PAYMENT_SUCCESS_ERROR]", error);
        return json(500, { error: "internal fiat payment error", detail: toErrorMessage(error) });
      }
    }
    if (url.pathname === "/" && req.method === "GET") {
      return new Response(indexHtml, {
        headers: { "content-type": "text/html; charset=utf-8" },
      });
    }
    if (url.pathname === "/fiat" && req.method === "GET") {
      return new Response(fiatPaymentHtml, {
        headers: { "content-type": "text/html; charset=utf-8" },
      });
    }
    return new Response("Not Found", { status: 404 });
  },
});

console.log(`Minimal sponsor UI running at http://localhost:${server.port}`);
