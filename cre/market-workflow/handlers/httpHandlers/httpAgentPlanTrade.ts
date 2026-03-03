import { type HTTPPayload, type Runtime } from "@chainlink/cre-sdk";
import { type Config } from "../../Constant-variable/config";
import { type SessionAuthorization } from "../utils/sessionValidation";
import { type AgentAction, AGENT_ACTION_TO_ROUTER_ACTION_TYPE } from "../utils/agentAction";

type AgentPlanRequest = {
  requestId?: string;
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
  session?: SessionAuthorization;
};

type AgentPlanResponse = {
  planned: boolean;
  requestId: string;
  reason?: string;
  plan?: {
    action: AgentAction;
    actionType: string;
    chainId: number;
    sender: string;
    user: string;
    agent: string;
    market: string;
    amountUsdc: string;
    slippageBps: number;
    yesIn?: string;
    minNoOut?: string;
    noIn?: string;
    minYesOut?: string;
    yesAmount?: string;
    noAmount?: string;
    minShares?: string;
    shares?: string;
    proposedOutcome?: number;
    session?: SessionAuthorization;
  };
};

const HEX_ADDRESS_REGEX = /^0x[a-fA-F0-9]{40}$/;
const ZERO_AMOUNT_ALLOWED_ACTIONS = new Set<AgentAction>(["disputeProposedResolution"]);

const parseRequest = (payload: HTTPPayload): AgentPlanRequest => {
  const raw = new TextDecoder().decode(payload.input);
  if (!raw.trim()) throw new Error("empty payload");
  return JSON.parse(raw) as AgentPlanRequest;
};

const validateUintString = (value: string | undefined, field: string): string => {
  const safe = (value || "").trim();
  if (!/^\d+$/.test(safe)) throw new Error(`${field} must be a numeric string`);
  return safe;
};

/**
 * Produces a normalized, policy-aligned agent trade plan that can be sponsored/executed.
 * This handler is deterministic and intentionally rejects missing/ambiguous fields.
 */
export const agentPlanTradeHttpHandler = async (runtime: Runtime<Config>, payload: HTTPPayload): Promise<string> => {
  const requestIdFallback = `agent_plan_${runtime.now().toISOString()}`;
  const agentPolicy = runtime.config.agentPolicy;
  if (!agentPolicy?.enabled) {
    return JSON.stringify({
      planned: false,
      requestId: requestIdFallback,
      reason: "agent policy disabled",
    } satisfies AgentPlanResponse);
  }

  let req: AgentPlanRequest;
  try {
    req = parseRequest(payload);
  } catch (error) {
    return JSON.stringify({
      planned: false,
      requestId: requestIdFallback,
      reason: error instanceof Error ? error.message : "invalid payload",
    } satisfies AgentPlanResponse);
  }

  const requestId = (req.requestId || requestIdFallback).trim();
  const action = req.action;
  if (!action || !AGENT_ACTION_TO_ROUTER_ACTION_TYPE[action]) {
    return JSON.stringify({ planned: false, requestId, reason: "invalid action" } satisfies AgentPlanResponse);
  }
  if (!agentPolicy.allowedActions.includes(action)) {
    return JSON.stringify({ planned: false, requestId, reason: "action not allowed by agent policy" } satisfies AgentPlanResponse);
  }

  if (typeof req.chainId !== "number" || !agentPolicy.supportedChainIds.includes(req.chainId)) {
    return JSON.stringify({ planned: false, requestId, reason: "unsupported chainId" } satisfies AgentPlanResponse);
  }

  const sender = (req.sender || req.user || "").trim();
  const user = (req.user || req.sender || "").trim();
  const agent = (req.agent || "").trim();
  const market = (req.market || "").trim();
  if (!HEX_ADDRESS_REGEX.test(sender) || !HEX_ADDRESS_REGEX.test(user) || !HEX_ADDRESS_REGEX.test(agent) || !HEX_ADDRESS_REGEX.test(market)) {
    return JSON.stringify({ planned: false, requestId, reason: "invalid address field" } satisfies AgentPlanResponse);
  }

  if (sender.toLowerCase() !== user.toLowerCase()) {
    return JSON.stringify({ planned: false, requestId, reason: "sender must equal user" } satisfies AgentPlanResponse);
  }

  let amountUsdc = (req.amountUsdc || "0").trim();
  try {
    amountUsdc = validateUintString(amountUsdc, "amountUsdc");
  } catch (error) {
    return JSON.stringify({ planned: false, requestId, reason: error instanceof Error ? error.message : "invalid amountUsdc" } satisfies AgentPlanResponse);
  }

  const allowZeroAmount = ZERO_AMOUNT_ALLOWED_ACTIONS.has(action);
  if (!allowZeroAmount && BigInt(amountUsdc) == 0n) {
    return JSON.stringify({ planned: false, requestId, reason: "amountUsdc must be greater than zero" } satisfies AgentPlanResponse);
  }

  const maxAmount = BigInt(agentPolicy.maxAmountUsdc);
  if (BigInt(amountUsdc) > maxAmount) {
    return JSON.stringify({ planned: false, requestId, reason: "amount exceeds agent policy" } satisfies AgentPlanResponse);
  }

  const slippageBps = typeof req.slippageBps === "number" ? req.slippageBps : agentPolicy.defaultSlippageBps;
  if (!Number.isInteger(slippageBps) || slippageBps < 0) {
    return JSON.stringify({ planned: false, requestId, reason: "invalid slippageBps" } satisfies AgentPlanResponse);
  }
  if (slippageBps > agentPolicy.maxSlippageBps) {
    return JSON.stringify({ planned: false, requestId, reason: "slippage exceeds agent policy" } satisfies AgentPlanResponse);
  }

  const response: AgentPlanResponse = {
    planned: true,
    requestId,
    plan: {
      action,
      actionType: AGENT_ACTION_TO_ROUTER_ACTION_TYPE[action],
      chainId: req.chainId,
      sender,
      user,
      agent,
      market,
      amountUsdc,
      slippageBps,
      yesIn: req.yesIn,
      minNoOut: req.minNoOut,
      noIn: req.noIn,
      minYesOut: req.minYesOut,
      yesAmount: req.yesAmount,
      noAmount: req.noAmount,
      minShares: req.minShares,
      shares: req.shares,
      proposedOutcome: req.proposedOutcome,
      session: req.session,
    },
  };
  return JSON.stringify(response);
};
