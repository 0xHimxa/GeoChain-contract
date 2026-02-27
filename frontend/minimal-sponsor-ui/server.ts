import { readFileSync } from "node:fs";
import { join } from "node:path";

type SponsorApiRequest = {
  requestId?: string;
  chainId: number;
  action: string;
  amountUsdc: string;
  sender: string;
  slippageBps: number;
  reportActionType: string;
  reportPayloadHex: string;
  session?: Record<string, unknown>;
};

type RevokeSessionApiRequest = {
  requestId?: string;
  sessionId: string;
  owner: string;
  chainId: number;
  revokeSignature: string;
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
const creConfigPath = process.env.CRE_CONFIG_PATH || join(import.meta.dir, "..", "..", "cre", "market-workflow", "config.staging.json");
const FALLBACK_CHAIN_CONFIG: Record<number, { executeReceiverAddress: string; collateralTokenAddress: string }> = {
  421614: {
    executeReceiverAddress: "0xf2992507E9589307Ea5f02225C5439Ee451d13EC",
    collateralTokenAddress: "0x8eaE35b8DC918BE54b2fAA57c9Bb0D4E13B9C9CB",
  },
  84532: {
    executeReceiverAddress: "0x65d7401B58C63841c72834D34141039ef41b52c8",
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

  const crePayload = {
    requestId: body.requestId || `ui_${Date.now()}`,
    chainId: body.chainId,
    action: body.action,
    amountUsdc: body.amountUsdc,
    sender: body.sender,
    slippageBps: body.slippageBps,
    session: body.session,
  };
  console.log("[MOCK_CRE_POLICY] payload=", JSON.stringify(crePayload));

  const creDecision = {
    approved: true,
    approvalId: `mock_approval_${Date.now()}`,
    reason: "mocked policy approval",
    requestId: crePayload.requestId,
  };

  if (!body.reportActionType || !body.reportPayloadHex) {
    return json(400, {
      approved: false,
      stage: "cre-execute",
      error: "missing reportActionType/reportPayloadHex",
    });
  }

  const executePayload = {
    requestId: `${body.requestId || `ui_${Date.now()}`}_exec`,
    approvalId: creDecision.approvalId,
    chainId: body.chainId,
    amountUsdc: body.amountUsdc,
    actionType: body.reportActionType,
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
    if (url.pathname === "/" && req.method === "GET") {
      return new Response(indexHtml, {
        headers: { "content-type": "text/html; charset=utf-8" },
      });
    }
    return new Response("Not Found", { status: 404 });
  },
});

console.log(`Minimal sponsor UI running at http://localhost:${server.port}`);
