import { type HTTPPayload, type Runtime } from "@chainlink/cre-sdk";
import { type Config } from "../../Constant-variable/config";
import { sponsorUserOpPolicyHandler } from "./httpSponsorPolicy";
import { type SessionAuthorization } from "../utils/sessionValidation";
import { type AgentAction, AGENT_ACTION_TO_ROUTER_ACTION_TYPE } from "../utils/agentAction";
import { parseJsonPayload } from "../utils/httpHandlerUtils";

type AgentSponsorRequest = {
  requestId?: string;
  chainId?: number;
  sender?: string;
  action?: AgentAction;
  amountUsdc?: string;
  slippageBps?: number;
  session?: SessionAuthorization;
};

/**
 * Bridges agent plans into the existing sponsor policy flow so session-signature,
 * amount, replay, and approval checks remain centralized in one place.
 */
export const agentSponsorTradeHttpHandler = async (runtime: Runtime<Config>, payload: HTTPPayload): Promise<string> => {
  const requestIdFallback = `agent_sponsor_${runtime.now().toISOString()}`;
  const agentPolicy = runtime.config.agentPolicy;
  if (!agentPolicy?.enabled) {
    return JSON.stringify({ approved: false, reason: "agent policy disabled", requestId: requestIdFallback });
  }

  let req: AgentSponsorRequest;
  try {
    req = parseJsonPayload<AgentSponsorRequest>(payload);
  } catch (error) {
    return JSON.stringify({ approved: false, reason: error instanceof Error ? error.message : "invalid payload", requestId: requestIdFallback });
  }

  const action = req.action;
  if (!action || !AGENT_ACTION_TO_ROUTER_ACTION_TYPE[action]) {
    return JSON.stringify({ approved: false, reason: "invalid action", requestId: req.requestId || requestIdFallback });
  }

  const sponsorRequest = {
    requestId: req.requestId || requestIdFallback,
    chainId: req.chainId,
    action,
    actionType: AGENT_ACTION_TO_ROUTER_ACTION_TYPE[action],
    amountUsdc: req.amountUsdc || "0",
    sender: req.sender || "",
    slippageBps: req.slippageBps,
    session: req.session,
  };

  return sponsorUserOpPolicyHandler(runtime, {
    ...payload,
    input: new TextEncoder().encode(JSON.stringify(sponsorRequest)),
  });
};
