import { type HTTPPayload, type Runtime } from "@chainlink/cre-sdk";
import { type Config } from "../../Constant-variable/config";
import { executeReportHttpHandler } from "./httpExecuteReport";
import { buildAgentPayloadHex, type AgentAction, AGENT_ACTION_TO_ROUTER_ACTION_TYPE } from "../utils/agentAction";

type AgentExecuteRequest = {
  requestId?: string;
  approvalId?: string;
  chainId?: number;
  action?: AgentAction;
  user?: `0x${string}`;
  sender?: `0x${string}`;
  agent?: `0x${string}`;
  market?: `0x${string}`;
  amountUsdc?: string;
  yesIn?: string;
  minNoOut?: string;
  noIn?: string;
  minYesOut?: string;
  yesAmount?: string;
  noAmount?: string;
  minShares?: string;
  shares?: string;
  proposedOutcome?: number;
};

/**
 * Builds an agent-specific router payload, maps the high-level agent action to the canonical
 * router `actionType`, and forwards the request into the shared execute handler.
 * This keeps agent execution on the same approval-consumption path as regular sponsored actions.
 */
export const agentExecuteTradeHttpHandler = async (runtime: Runtime<Config>, payload: HTTPPayload): Promise<string> => {
  const requestIdFallback = `agent_execute_${runtime.now().toISOString()}`;
  const agentPolicy = runtime.config.agentPolicy;
  if (!agentPolicy?.enabled) {
    return JSON.stringify({ submitted: false, requestId: requestIdFallback, reason: "agent policy disabled" });
  }

  let req: AgentExecuteRequest;
  try {
    const raw = new TextDecoder().decode(payload.input);
    if (!raw.trim()) throw new Error("empty payload");
    req = JSON.parse(raw) as AgentExecuteRequest;
  } catch (error) {
    return JSON.stringify({
      submitted: false,
      requestId: requestIdFallback,
      reason: error instanceof Error ? error.message : "invalid payload",
    });
  }

  const action = req.action;
  if (!action || !AGENT_ACTION_TO_ROUTER_ACTION_TYPE[action]) {
    return JSON.stringify({ submitted: false, requestId: req.requestId || requestIdFallback, reason: "invalid action" });
  }

  const user = (req.user || req.sender || "") as `0x${string}`;
  const actionType = AGENT_ACTION_TO_ROUTER_ACTION_TYPE[action];
  let payloadHex: `0x${string}`;
  try {
    payloadHex = buildAgentPayloadHex(action, {
      user,
      agent: (req.agent || "") as `0x${string}`,
      market: (req.market || "") as `0x${string}`,
      amountUsdc: req.amountUsdc,
      yesIn: req.yesIn,
      minNoOut: req.minNoOut,
      noIn: req.noIn,
      minYesOut: req.minYesOut,
      yesAmount: req.yesAmount,
      noAmount: req.noAmount,
      minShares: req.minShares,
      shares: req.shares,
      proposedOutcome: req.proposedOutcome,
    });
  } catch (error) {
    return JSON.stringify({
      submitted: false,
      requestId: req.requestId || requestIdFallback,
      reason: error instanceof Error ? error.message : "failed to build payload",
    });
  }

  const executeRequest = {
    requestId: req.requestId || requestIdFallback,
    approvalId: req.approvalId,
    chainId: req.chainId,
    amountUsdc: req.amountUsdc || "0",
    actionType,
    payloadHex,
  };

  return executeReportHttpHandler(runtime, {
    ...payload,
    input: new TextEncoder().encode(JSON.stringify(executeRequest)),
  });
};
