import { HTTPClient, consensusIdenticalAggregation, ok, type HTTPPayload, type Runtime } from "@chainlink/cre-sdk";
import { type Config } from "../../Constant-variable/config";
import { type SessionAuthorization } from "../utils/sessionValidation";
import { AGENT_ACTION_TO_ROUTER_ACTION_TYPE, type AgentAction } from "../utils/agentAction";
import { agentPlanTradeHttpHandler } from "./httpAgentPlanTrade";
import { agentSponsorTradeHttpHandler } from "./httpAgentSponsorTrade";
import { agentExecuteTradeHttpHandler } from "./httpAgentExecuteTrade";

export type GeminiAutoTradeRequest = {
  requestId?: string;
  chainId?: number;
  sender?: string;
  user?: string;
  agent?: string;
  market?: string;
  amountUsdc?: string;
  slippageBps?: number;
  allowedActions?: AgentAction[];
  marketContext?: {
    question?: string;
    yesPriceBps?: number;
    noPriceBps?: number;
    note?: string;
  };
  session?: SessionAuthorization;
};

type GeminiDecision = {
  action: AgentAction | "hold";
  amountUsdc: string;
  rationale: string;
  confidenceBps: number;
};

export type GeminiAutoTradeResponse = {
  requestId: string;
  handled: boolean;
  reason: string;
  decision?: GeminiDecision;
  sponsor?: Record<string, unknown>;
  execute?: Record<string, unknown>;
};

const AUTO_EXEC_ACTIONS = new Set<AgentAction>([
  "mintCompleteSets",
  "redeemCompleteSets",
  "redeem",
  "swapYesForNo",
  "swapNoForYes",
]);

const SYSTEM_PROMPT = `You are a risk-constrained trading assistant for prediction markets.
Return a single minified JSON object only.
Schema: {"action":"mintCompleteSets"|"redeemCompleteSets"|"redeem"|"swapYesForNo"|"swapNoForYes"|"hold","amountUsdc":"<uint-string>","rationale":"<short>","confidenceBps":<0-10000 integer>}
Rules:
1) action must be one of ALLOWED_ACTIONS.
2) amountUsdc must be a base-10 integer string and <= MAX_AMOUNT_USDC.
3) If uncertain, output "hold" with amountUsdc "0".
4) No markdown, no prose, no extra keys.`;

const decodeInput = (payload: HTTPPayload): GeminiAutoTradeRequest => {
  const raw = new TextDecoder().decode(payload.input);
  if (!raw.trim()) throw new Error("empty payload");
  return JSON.parse(raw) as GeminiAutoTradeRequest;
};

const parseDecision = (raw: string): GeminiDecision => {
  const parsed = JSON.parse(raw) as GeminiDecision;
  if (!parsed || typeof parsed !== "object") throw new Error("invalid gemini response");
  if (!("action" in parsed) || !("amountUsdc" in parsed)) throw new Error("gemini response missing fields");
  return parsed;
};

const withInput = (base: HTTPPayload, obj: unknown): HTTPPayload => ({
  ...base,
  input: new TextEncoder().encode(JSON.stringify(obj)),
});

const makeInternalPayload = (obj: unknown): HTTPPayload => ({
  $typeName: "capabilities.networking.http.v1alpha.Payload",
  input: new TextEncoder().encode(JSON.stringify(obj)),
}) as HTTPPayload;

const askGeminiForTrade = (
  runtime: Runtime<Config>,
  userPrompt: string
): GeminiDecision => {
  const apiKey = runtime.getSecret({ id: "AI_KEY" }).result().value;
  const httpClient = new HTTPClient();

  const requester = (sender: any) => {
    const data = {
      system_instruction: { parts: [{ text: SYSTEM_PROMPT }] },
      contents: [{ parts: [{ text: userPrompt }] }],
    };
    const bodyBytes = new TextEncoder().encode(JSON.stringify(data));
    const body = Buffer.from(bodyBytes).toString("base64");

    const res = sender.sendRequest({
      url: "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent",
      method: "POST",
      body,
      headers: {
        "Content-Type": "application/json",
        "x-goog-api-key": apiKey,
      },
    }).result();

    if (!ok(res)) {
      throw new Error(`gemini call failed (${res.statusCode})`);
    }

    const rawBody = new TextDecoder().decode(res.body);
    const json = JSON.parse(rawBody) as { candidates?: Array<{ content?: { parts?: Array<{ text?: string }> } }> };
    const text = (json.candidates?.[0]?.content?.parts?.[0]?.text || "").trim();
    if (!text) throw new Error("empty gemini decision");
    return parseDecision(text);
  };

  return httpClient.sendRequest(runtime, requester, consensusIdenticalAggregation())().result();
};

const executeGeminiAutoTrade = async (
  runtime: Runtime<Config>,
  req: GeminiAutoTradeRequest,
  payloadFactory?: (obj: unknown) => HTTPPayload
): Promise<GeminiAutoTradeResponse> => {
  const requestIdFallback = `agent_gemini_${runtime.now().toISOString()}`;
  const policy = runtime.config.agentPolicy;
  if (!policy?.enabled) {
    return {
      requestId: requestIdFallback,
      handled: false,
      reason: "agent policy disabled",
    };
  }

  const requestId = req.requestId || requestIdFallback;
  const allowedActions = (req.allowedActions || policy.allowedActions || [])
    .filter((a): a is AgentAction => Boolean(AGENT_ACTION_TO_ROUTER_ACTION_TYPE[a as AgentAction]))
    .filter((a) => AUTO_EXEC_ACTIONS.has(a));

  if (allowedActions.length === 0) {
    return {
      requestId,
      handled: false,
      reason: "no auto-executable allowed actions provided",
    };
  }

  const maxAmountUsdc = req.amountUsdc && /^\d+$/.test(req.amountUsdc)
    ? req.amountUsdc
    : policy.maxAmountUsdc;
  const userPrompt = `REQUEST_ID=${requestId}
ALLOWED_ACTIONS=${allowedActions.join(",")}
MAX_AMOUNT_USDC=${maxAmountUsdc}
CHAIN_ID=${String(req.chainId || "")}
MARKET=${req.market || ""}
QUESTION=${req.marketContext?.question || ""}
YES_PRICE_BPS=${String(req.marketContext?.yesPriceBps ?? "")}
NO_PRICE_BPS=${String(req.marketContext?.noPriceBps ?? "")}
NOTE=${req.marketContext?.note || ""}`;

  let decision: GeminiDecision;
  try {
    decision = askGeminiForTrade(runtime, userPrompt);
  } catch (error) {
    return {
      requestId,
      handled: false,
      reason: error instanceof Error ? error.message : "gemini decision failed",
    };
  }

  if (decision.action === "hold") {
    return {
      requestId,
      handled: true,
      reason: "gemini decided to hold",
      decision,
    };
  }

  if (!allowedActions.includes(decision.action)) {
    return {
      requestId,
      handled: false,
      reason: "gemini selected action outside allowed set",
      decision,
    };
  }

  if (!/^\d+$/.test(decision.amountUsdc)) {
    return {
      requestId,
      handled: false,
      reason: "gemini returned invalid amountUsdc",
      decision,
    };
  }

  const boundedAmount = BigInt(decision.amountUsdc) > BigInt(maxAmountUsdc)
    ? maxAmountUsdc
    : decision.amountUsdc;

  const planReq = {
    requestId,
    chainId: req.chainId,
    sender: req.sender || req.user,
    user: req.user || req.sender,
    agent: req.agent,
    market: req.market,
    action: decision.action,
    amountUsdc: boundedAmount,
    slippageBps: req.slippageBps,
    session: req.session,
  };

  const toPayload = payloadFactory || makeInternalPayload;

  const planRaw = await agentPlanTradeHttpHandler(runtime, toPayload(planReq));
  const planJson = JSON.parse(planRaw) as { planned?: boolean; reason?: string; plan?: Record<string, unknown> };
  if (!planJson.planned || !planJson.plan) {
    return {
      requestId,
      handled: false,
      reason: `plan rejected: ${planJson.reason || "unknown"}`,
      decision,
    };
  }

  const sponsorRaw = await agentSponsorTradeHttpHandler(runtime, toPayload(planJson.plan));
  const sponsorJson = JSON.parse(sponsorRaw) as { approved?: boolean; reason?: string; approvalId?: string };
  if (!sponsorJson.approved || !sponsorJson.approvalId) {
    return {
      requestId,
      handled: false,
      reason: `sponsor rejected: ${sponsorJson.reason || "unknown"}`,
      decision,
      sponsor: sponsorJson as Record<string, unknown>,
    };
  }

  const executeReq = {
    ...planJson.plan,
    requestId,
    approvalId: sponsorJson.approvalId,
    action: decision.action,
    amountUsdc: boundedAmount,
  };
  const executeRaw = await agentExecuteTradeHttpHandler(runtime, toPayload(executeReq));
  const executeJson = JSON.parse(executeRaw) as { submitted?: boolean; reason?: string };
  if (!executeJson.submitted) {
    return {
      requestId,
      handled: false,
      reason: `execute failed: ${executeJson.reason || "unknown"}`,
      decision,
      sponsor: sponsorJson as Record<string, unknown>,
      execute: executeJson as Record<string, unknown>,
    };
  }

  return {
    requestId,
    handled: true,
    reason: "gemini-selected trade executed",
    decision: {
      ...decision,
      amountUsdc: boundedAmount,
    },
    sponsor: sponsorJson as Record<string, unknown>,
    execute: executeJson as Record<string, unknown>,
  };
};

/**
 * Shared entrypoint for HTTP and cron callers.
 */
export const runGeminiAutoTrade = async (
  runtime: Runtime<Config>,
  req: GeminiAutoTradeRequest
): Promise<GeminiAutoTradeResponse> => {
  return executeGeminiAutoTrade(runtime, req, makeInternalPayload);
};

/**
 * End-to-end HTTP agent handler that asks Gemini for a trade decision and then executes
 * only through the secured plan/sponsor/execute pipeline.
 */
export const agentGeminiAutoTradeHttpHandler = async (
  runtime: Runtime<Config>,
  payload: HTTPPayload
): Promise<string> => {
  let req: GeminiAutoTradeRequest;
  try {
    req = decodeInput(payload);
  } catch (error) {
    return JSON.stringify({
      requestId: `agent_gemini_${runtime.now().toISOString()}`,
      handled: false,
      reason: error instanceof Error ? error.message : "invalid payload",
    } satisfies GeminiAutoTradeResponse);
  }

  const result = await executeGeminiAutoTrade(runtime, req, (obj) => withInput(payload, obj));
  return JSON.stringify(result satisfies GeminiAutoTradeResponse);
};
