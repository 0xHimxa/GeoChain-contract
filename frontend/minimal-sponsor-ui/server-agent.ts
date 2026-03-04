import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join, normalize } from "node:path";

type AgentAction =
  | "mintCompleteSets"
  | "redeemCompleteSets"
  | "swapYesForNo"
  | "swapNoForYes"
  | "addLiquidity"
  | "removeLiquidity"
  | "redeem"
  | "disputeProposedResolution";

type AgentTradeInput = {
  requestId?: string;
  approvalId?: string;
  chainId?: number;
  sender?: string;
  user?: string;
  agent?: string;
  market?: string;
  action?: AgentAction;
  amountUsdc?: string;
  slippageBps?: number;
  yesIn?: string;
  minNoOut?: string;
  noIn?: string;
  minYesOut?: string;
  yesAmount?: string;
  noAmount?: string;
  minShares?: string;
  shares?: string;
  proposedOutcome?: number;
  reason?: string;
  session?: Record<string, unknown>;
};

const ACTION_TO_ROUTER_ACTION_TYPE: Record<AgentAction, string> = {
  mintCompleteSets: "routerAgentMintCompleteSets",
  redeemCompleteSets: "routerAgentRedeemCompleteSets",
  swapYesForNo: "routerAgentSwapYesForNo",
  swapNoForYes: "routerAgentSwapNoForYes",
  addLiquidity: "routerAgentAddLiquidity",
  removeLiquidity: "routerAgentRemoveLiquidity",
  redeem: "routerAgentRedeem",
  disputeProposedResolution: "routerAgentDisputeProposedResolution",
};

const HEX_ADDRESS_REGEX = /^0x[a-fA-F0-9]{40}$/;

const AGENT_PLAN_JSON_PATH = process.env.CRE_AGENT_PLAN_JSON_PATH || join(import.meta.dir, "..", "..", "cre", "agents-workflow", "payload", "agent-plan.json");
const AGENT_SPONSOR_JSON_PATH = process.env.CRE_AGENT_SPONSOR_JSON_PATH || join(import.meta.dir, "..", "..", "cre", "agents-workflow", "payload", "agent-sponsor.json");
const AGENT_EXECUTE_JSON_PATH = process.env.CRE_AGENT_EXECUTE_JSON_PATH || join(import.meta.dir, "..", "..", "cre", "agents-workflow", "payload", "agent-execute.json");
const AGENT_REVOKE_JSON_PATH = process.env.CRE_AGENT_REVOKE_JSON_PATH || join(import.meta.dir, "..", "..", "cre", "agents-workflow", "payload", "agent-revoke.json");

const json = (status: number, payload: unknown): Response =>
  new Response(JSON.stringify(payload, null, 2), {
    status,
    headers: {
      "content-type": "application/json; charset=utf-8",
      "access-control-allow-origin": "*",
      "access-control-allow-headers": "content-type",
      "access-control-allow-methods": "GET,POST,OPTIONS",
    },
  });

const nowUnix = (): number => Math.floor(Date.now() / 1000);
const randomId = (prefix: string): string => `${prefix}_${Date.now()}_${Math.random().toString(16).slice(2, 10)}`;

const writeJsonFile = (filePath: string, payload: Record<string, unknown>): void => {
  mkdirSync(dirname(filePath), { recursive: true });
  writeFileSync(filePath, JSON.stringify(payload, null, 2));
};

const sanitizeUint = (value: string | undefined, field: string): string => {
  const raw = String(value || "").trim();
  if (!/^\d+$/.test(raw)) throw new Error(`${field} must be uint string`);
  return raw;
};

const sanitizeAddress = (value: string | undefined, field: string): string => {
  const raw = String(value || "").trim();
  if (!HEX_ADDRESS_REGEX.test(raw)) throw new Error(`${field} must be a valid address`);
  return raw;
};

const normalizeTradeInput = (body: AgentTradeInput, requireApproval: boolean) => {
  const action = body.action;
  if (!action || !ACTION_TO_ROUTER_ACTION_TYPE[action]) throw new Error("invalid action");

  const chainId = Number(body.chainId);
  if (!Number.isInteger(chainId) || chainId <= 0) throw new Error("invalid chainId");

  const requestId = String(body.requestId || randomId("agent_req"));
  const sender = sanitizeAddress(body.sender || body.user, "sender");
  const user = sanitizeAddress(body.user || body.sender, "user");
  const agent = sanitizeAddress(body.agent, "agent");
  const market = sanitizeAddress(body.market, "market");
  const amountUsdc = sanitizeUint(body.amountUsdc, "amountUsdc");
  const slippageBps = Number.isInteger(body.slippageBps) ? Number(body.slippageBps) : 120;

  const approvalId = String(body.approvalId || "").trim();
  if (requireApproval && !approvalId) throw new Error("approvalId required");

  const normalized = {
    requestId,
    chainId,
    sender,
    user,
    agent,
    market,
    action,
    actionType: ACTION_TO_ROUTER_ACTION_TYPE[action],
    amountUsdc,
    slippageBps,
    yesIn: String(body.yesIn || (action === "swapYesForNo" ? amountUsdc : "")).trim() || undefined,
    minNoOut: String(body.minNoOut || (action === "swapYesForNo" ? "0" : "")).trim() || undefined,
    noIn: String(body.noIn || (action === "swapNoForYes" ? amountUsdc : "")).trim() || undefined,
    minYesOut: String(body.minYesOut || (action === "swapNoForYes" ? "0" : "")).trim() || undefined,
    yesAmount: String(body.yesAmount || (action === "addLiquidity" ? amountUsdc : "")).trim() || undefined,
    noAmount: String(body.noAmount || (action === "addLiquidity" ? amountUsdc : "")).trim() || undefined,
    minShares: String(body.minShares || (action === "addLiquidity" ? "0" : "")).trim() || undefined,
    shares: String(body.shares || (action === "removeLiquidity" ? amountUsdc : "")).trim() || undefined,
    proposedOutcome: typeof body.proposedOutcome === "number" ? body.proposedOutcome : undefined,
    approvalId,
  };

  const planPayload = {
    requestId: normalized.requestId,
    chainId: normalized.chainId,
    sender: normalized.sender,
    user: normalized.user,
    agent: normalized.agent,
    market: normalized.market,
    action: normalized.action,
    actionType: normalized.actionType,
    amountUsdc: normalized.amountUsdc,
    slippageBps: normalized.slippageBps,
    yesIn: normalized.yesIn,
    minNoOut: normalized.minNoOut,
    noIn: normalized.noIn,
    minYesOut: normalized.minYesOut,
    yesAmount: normalized.yesAmount,
    noAmount: normalized.noAmount,
    minShares: normalized.minShares,
    shares: normalized.shares,
    proposedOutcome: normalized.proposedOutcome,
  };

  const sponsorPayload = {
    requestId: normalized.requestId,
    chainId: normalized.chainId,
    sender: normalized.sender,
    action: normalized.action,
    actionType: normalized.actionType,
    amountUsdc: normalized.amountUsdc,
    slippageBps: normalized.slippageBps,
    session: body.session,
  };

  const executePayload = {
    requestId: normalized.requestId,
    approvalId: normalized.approvalId || undefined,
    chainId: normalized.chainId,
    action: normalized.action,
    actionType: normalized.actionType,
    user: normalized.user,
    sender: normalized.sender,
    agent: normalized.agent,
    market: normalized.market,
    amountUsdc: normalized.amountUsdc,
    yesIn: normalized.yesIn,
    minNoOut: normalized.minNoOut,
    noIn: normalized.noIn,
    minYesOut: normalized.minYesOut,
    yesAmount: normalized.yesAmount,
    noAmount: normalized.noAmount,
    minShares: normalized.minShares,
    shares: normalized.shares,
    proposedOutcome: normalized.proposedOutcome,
  };

  return { normalized, planPayload, sponsorPayload, executePayload };
};

const handleAgentPlan = async (req: Request): Promise<Response> => {
  const body = (await req.json().catch(() => null)) as AgentTradeInput | null;
  if (!body) return json(400, { error: "invalid JSON body" });

  try {
    const grouped = normalizeTradeInput(body, false);
    const payload = {
      phaseNumber: 1,
      phase: "plan",
      ...grouped.planPayload,
      createdAtUnix: nowUnix(),
    };

    writeJsonFile(AGENT_PLAN_JSON_PATH, payload);
    console.log("[MOCK_AGENT_PHASE_1_PLAN] payload=", JSON.stringify(payload));

    return json(200, {
      planned: true,
      phaseNumber: 1,
      phase: "plan",
      planJsonPath: AGENT_PLAN_JSON_PATH,
      grouped: {
        plan: grouped.planPayload,
        sponsor: grouped.sponsorPayload,
        execute: grouped.executePayload,
      },
      ...payload,
    });
  } catch (error) {
    return json(400, { planned: false, phaseNumber: 1, phase: "plan", error: String(error) });
  }
};

const handleAgentSponsor = async (req: Request): Promise<Response> => {
  const body = (await req.json().catch(() => null)) as AgentTradeInput | null;
  if (!body) return json(400, { error: "invalid JSON body" });

  try {
    const grouped = normalizeTradeInput(body, false);
    const payload = {
      phaseNumber: 2,
      phase: "sponsor",
      ...grouped.sponsorPayload,
      createdAtUnix: nowUnix(),
    };

    writeJsonFile(AGENT_SPONSOR_JSON_PATH, payload);
    const approvalId = `cre_approval_${Date.now()}_${payload.requestId.slice(-8)}_${payload.sender.slice(2, 8)}`;
    console.log("[MOCK_AGENT_PHASE_2_SPONSOR] payload=", JSON.stringify(payload));

    return json(200, {
      approved: true,
      phaseNumber: 2,
      phase: "sponsor",
      approvalId,
      sponsorJsonPath: AGENT_SPONSOR_JSON_PATH,
      grouped: {
        plan: grouped.planPayload,
        sponsor: grouped.sponsorPayload,
        execute: { ...grouped.executePayload, approvalId },
      },
      ...payload,
    });
  } catch (error) {
    return json(400, { approved: false, phaseNumber: 2, phase: "sponsor", error: String(error) });
  }
};

const handleAgentExecute = async (req: Request): Promise<Response> => {
  const body = (await req.json().catch(() => null)) as AgentTradeInput | null;
  if (!body) return json(400, { error: "invalid JSON body" });

  try {
    const grouped = normalizeTradeInput(body, true);
    const payload = {
      phaseNumber: 3,
      phase: "execute",
      ...grouped.executePayload,
      createdAtUnix: nowUnix(),
    };

    writeJsonFile(AGENT_EXECUTE_JSON_PATH, payload);
    console.log("[MOCK_AGENT_PHASE_3_EXECUTE] payload=", JSON.stringify(payload));

    return json(200, {
      submitted: true,
      phaseNumber: 3,
      phase: "execute",
      executeJsonPath: AGENT_EXECUTE_JSON_PATH,
      txHash: `0x${crypto.randomUUID().replaceAll("-", "").padEnd(64, "0").slice(0, 64)}`,
      grouped: {
        plan: grouped.planPayload,
        sponsor: grouped.sponsorPayload,
        execute: grouped.executePayload,
      },
      ...payload,
    });
  } catch (error) {
    return json(400, { submitted: false, phaseNumber: 3, phase: "execute", error: String(error) });
  }
};

const handleAgentRevoke = async (req: Request): Promise<Response> => {
  const body = (await req.json().catch(() => null)) as AgentTradeInput | null;
  if (!body) return json(400, { error: "invalid JSON body" });

  try {
    const requestId = String(body.requestId || randomId("agent_revoke"));
    const chainId = Number(body.chainId);
    if (!Number.isInteger(chainId) || chainId <= 0) throw new Error("invalid chainId");

    const payload = {
      phaseNumber: 4,
      phase: "revoke",
      requestId,
      chainId,
      user: sanitizeAddress(body.user, "user"),
      agent: sanitizeAddress(body.agent, "agent"),
      reason: String(body.reason || "manual revoke from agent page"),
      createdAtUnix: nowUnix(),
    };

    writeJsonFile(AGENT_REVOKE_JSON_PATH, payload);
    console.log("[MOCK_AGENT_PHASE_4_REVOKE] payload=", JSON.stringify(payload));

    return json(200, {
      revoked: true,
      phaseNumber: 4,
      phase: "revoke",
      revokeJsonPath: AGENT_REVOKE_JSON_PATH,
      ...payload,
    });
  } catch (error) {
    return json(400, { revoked: false, phaseNumber: 4, phase: "revoke", error: String(error) });
  }
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

const port = Number(process.env.AGENT_PORT || 5175);

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

    try {
      if (url.pathname === "/api/agent/plan" && req.method === "POST") return await handleAgentPlan(req);
      if (url.pathname === "/api/agent/sponsor" && req.method === "POST") return await handleAgentSponsor(req);
      if (url.pathname === "/api/agent/execute" && req.method === "POST") return await handleAgentExecute(req);
      if (url.pathname === "/api/agent/revoke" && req.method === "POST") return await handleAgentRevoke(req);
      if (url.pathname === "/api/health" && req.method === "GET") {
        return json(200, {
          ok: true,
          mode: "agent",
          nowUnix: nowUnix(),
          paths: {
            plan: AGENT_PLAN_JSON_PATH,
            sponsor: AGENT_SPONSOR_JSON_PATH,
            execute: AGENT_EXECUTE_JSON_PATH,
            revoke: AGENT_REVOKE_JSON_PATH,
          },
        });
      }
    } catch (error) {
      return json(500, { error: "internal server error", detail: String(error) });
    }

    const staticRes = tryServeDist(url.pathname);
    if (staticRes) return staticRes;

    return new Response(
      [
        "Agent backend running.",
        "Start frontend dev server: bun run frontend:dev:agent",
        "Start agent backend server: bun run dev:agent",
        "Agent page URL: http://localhost:5176/agent.html",
      ].join("\n"),
      {
        status: 200,
        headers: { "content-type": "text/plain; charset=utf-8" },
      }
    );
  },
});

console.log(`Agent backend running at http://localhost:${server.port}`);
console.log("Agent frontend expected at http://localhost:5176/agent.html");
