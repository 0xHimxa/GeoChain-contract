import { type HTTPPayload, type Runtime } from "@chainlink/cre-sdk";
import { type Config } from "../../Constant-variable/config";
import { type SessionAuthorization } from "../utils/sessionValidation";
import { type AgentAction, AGENT_ACTION_TO_ROUTER_ACTION_TYPE } from "../utils/agentAction";
import { HEX_ADDRESS_REGEX } from "../utils/evmUtils";
import { parseJsonPayload } from "../utils/httpHandlerUtils";

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
  outcomeIndex?: number | string;
  sharesDelta?: string | number;
  costDelta?: string | number;
  refundDelta?: string | number;
  newYesPriceE6?: string | number;
  newNoPriceE6?: string | number;
  nonce?: string | number;
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
    outcomeIndex?: number;
    sharesDelta?: string;
    costDelta?: string;
    refundDelta?: string;
    newYesPriceE6?: string;
    newNoPriceE6?: string;
    nonce?: string;
    proposedOutcome?: number;
    session?: SessionAuthorization;
  };
};

const ZERO_AMOUNT_ALLOWED_ACTIONS = new Set<AgentAction>(["disputeProposedResolution"]);

const parseRequest = (payload: HTTPPayload): AgentPlanRequest => {
  return parseJsonPayload<AgentPlanRequest>(payload);
};

const normalizeUintString = (value: string | number | undefined, field: string): string => {
  if (typeof value === "number") {
    if (!Number.isFinite(value) || !Number.isInteger(value) || value < 0) {
      throw new Error(`${field} must be a non-negative integer`);
    }
    return String(value);
  }
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
    amountUsdc = normalizeUintString(amountUsdc, "amountUsdc");
  } catch (error) {
    return JSON.stringify({ planned: false, requestId, reason: error instanceof Error ? error.message : "invalid amountUsdc" } satisfies AgentPlanResponse);
  }

  const slippageBps = typeof req.slippageBps === "number" ? req.slippageBps : agentPolicy.defaultSlippageBps;
  if (!Number.isInteger(slippageBps) || slippageBps < 0) {
    return JSON.stringify({ planned: false, requestId, reason: "invalid slippageBps" } satisfies AgentPlanResponse);
  }
  if (slippageBps > agentPolicy.maxSlippageBps) {
    return JSON.stringify({ planned: false, requestId, reason: "slippage exceeds agent policy" } satisfies AgentPlanResponse);
  }

  let outcomeIndex: number | undefined;
  let sharesDelta: string | undefined;
  let costDelta: string | undefined;
  let refundDelta: string | undefined;
  let newYesPriceE6: string | undefined;
  let newNoPriceE6: string | undefined;
  let nonce: string | undefined;

  if (action === "lmsrBuy" || action === "lmsrSell") {
    try {
      const outcomeIndexRaw = normalizeUintString(req.outcomeIndex, "outcomeIndex");
      if (outcomeIndexRaw !== "0" && outcomeIndexRaw !== "1") {
        return JSON.stringify({ planned: false, requestId, reason: "outcomeIndex must be 0 (YES) or 1 (NO)" } satisfies AgentPlanResponse);
      }
      outcomeIndex = Number(outcomeIndexRaw);
      sharesDelta = normalizeUintString(req.sharesDelta, "sharesDelta");
      newYesPriceE6 = normalizeUintString(req.newYesPriceE6, "newYesPriceE6");
      newNoPriceE6 = normalizeUintString(req.newNoPriceE6, "newNoPriceE6");
      nonce = normalizeUintString(req.nonce, "nonce");
      if (action === "lmsrBuy") {
        costDelta = normalizeUintString(req.costDelta, "costDelta");
        if (amountUsdc === "0") amountUsdc = costDelta;
        if (amountUsdc !== costDelta) {
          return JSON.stringify({ planned: false, requestId, reason: "amountUsdc must match costDelta for lmsrBuy" } satisfies AgentPlanResponse);
        }
      } else {
        refundDelta = normalizeUintString(req.refundDelta, "refundDelta");
        if (amountUsdc === "0") amountUsdc = sharesDelta;
        if (amountUsdc !== sharesDelta) {
          return JSON.stringify({ planned: false, requestId, reason: "amountUsdc must match sharesDelta for lmsrSell" } satisfies AgentPlanResponse);
        }
      }
    } catch (error) {
      return JSON.stringify({ planned: false, requestId, reason: error instanceof Error ? error.message : "invalid LMSR fields" } satisfies AgentPlanResponse);
    }
  }

  const allowZeroAmount = ZERO_AMOUNT_ALLOWED_ACTIONS.has(action);
  if (!allowZeroAmount && BigInt(amountUsdc) == 0n) {
    return JSON.stringify({ planned: false, requestId, reason: "amountUsdc must be greater than zero" } satisfies AgentPlanResponse);
  }

  const maxAmount = BigInt(agentPolicy.maxAmountUsdc);
  if (BigInt(amountUsdc) > maxAmount) {
    return JSON.stringify({ planned: false, requestId, reason: "amount exceeds agent policy" } satisfies AgentPlanResponse);
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
      outcomeIndex,
      sharesDelta,
      costDelta,
      refundDelta,
      newYesPriceE6,
      newNoPriceE6,
      nonce,
      proposedOutcome: req.proposedOutcome,
      session: req.session,
    },
  };
  return JSON.stringify(response);
};
