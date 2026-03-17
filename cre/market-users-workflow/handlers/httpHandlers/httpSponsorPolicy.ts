import { type HTTPPayload, type Runtime } from "@chainlink/cre-sdk";
import { type Config } from "../../Constant-variable/config";
import { createApprovalRecord, getFirestoreIdToken } from "../../firebase/sessionStore";
import { validateSessionAuthorization, type SessionAuthorization } from "../utils/sessionValidation";
import { HEX_ADDRESS_REGEX } from "../utils/evmUtils";
import { parseDecimalBigInt, parseJsonPayload } from "../utils/httpHandlerUtils";

type SponsorRequest = {
  requestId?: string;
  chainId?: number;
  action?: string;
  actionType?: string;
  reportActionType?: string;
  amountUsdc?: string;
  sender?: string;
  slippageBps?: number;
  session?: SessionAuthorization;
};

type SponsorDecision = {
  approved: boolean;
  reason: string;
  requestId: string;
  approvalId?: string;
  approvalExpiresAtUnix?: number;
};

const PRICISION = 1000000n
const DEFAULT_MAX_AMOUNT_USDC = 10000n  * PRICISION;
const DEFAULT_MAX_SLIPPAGE_BPS = 300;
const DEFAULT_ALLOWED_ACTIONS = new Set([
  "lmsrBuy",
  "lmsrSell",
  "mintCompleteSets",
  "redeemCompleteSets",
  "redeem",
  "disputeProposedResolution",
]);
const ACTION_TO_ROUTER_ACTION_TYPE: Record<string, string> = {
  lmsrBuy: "LMSRBuy",
  lmsrSell: "LMSRSell",
  mintCompleteSets: "routerMintCompleteSets",
  redeemCompleteSets: "routerRedeemCompleteSets",
  redeem: "routerRedeem",
  disputeProposedResolution: "routerDisputeProposedResolution",
};

const ZERO_AMOUNT_ALLOWED_ACTIONS = new Set([
  "disputeProposedResolution",
]);

const parseRequest = (payload: HTTPPayload): SponsorRequest => {
  return parseJsonPayload<SponsorRequest>(payload);
};

const makeDecision = (
  requestId: string,
  validationFailedReason?: string
): SponsorDecision => {
  if (validationFailedReason) {
    return { approved: false, reason: validationFailedReason, requestId };
  }
  return { approved: false, reason: "invalid request", requestId };
};

/**
 * Validates a sponsor request end-to-end: HTTP auth-key gate, supported chain, allowed
 * action/actionType mapping, amount/slippage limits, sender format, and session signatures.
 * If valid, it writes a short-lived approval record to Firestore for one-time consumption by execute.
 */
export const sponsorUserOpPolicyHandler = async (runtime: Runtime<Config>, payload: HTTPPayload): Promise<string> => {
  const policy = runtime.config.sponsorPolicy;
  const executePolicy = runtime.config.executePolicy;
  const authKeys = runtime.config.httpTriggerAuthorizedKeys || [];

  if (!policy?.enabled) {
    return JSON.stringify({
      approved: false,
      reason: "sponsorship disabled",
      requestId: `req_${runtime.now().toString()}`,
    } satisfies SponsorDecision);
  }

  if (authKeys.length === 0) {
    return JSON.stringify({
      approved: false,
      reason: "no authorized HTTP trigger keys configured",
      requestId: `req_${runtime.now().toString()}`,
    } satisfies SponsorDecision);
  }

  let request: SponsorRequest;
  try {
    request = parseRequest(payload);
  } catch (error) {
    const reason = error instanceof Error ? error.message : "invalid payload";
    return JSON.stringify(makeDecision(`req_${runtime.now().toString()}`, reason));
  }

  const requestId = request.requestId || `req_${runtime.now().toString()}`;

  if (request.action && !DEFAULT_ALLOWED_ACTIONS.has(request.action)) {
    return JSON.stringify(makeDecision(requestId, "unknown action"));
  }

  if (typeof request.chainId !== "number") {
    return JSON.stringify(makeDecision(requestId, "missing chainId"));
  }

  if (!policy.supportedChainIds.includes(request.chainId)) {
    return JSON.stringify(makeDecision(requestId, "chain is not sponsorable"));
  }

  if (!request.action || !policy.allowedActions.includes(request.action)) {
    return JSON.stringify(makeDecision(requestId, "action is not sponsorable"));
  }
  const expectedActionType = ACTION_TO_ROUTER_ACTION_TYPE[request.action];
  if (!expectedActionType) {
    return JSON.stringify(makeDecision(requestId, "action is not mappable to execute actionType"));
  }

  const requestedActionType = (request.actionType || request.reportActionType || "").trim();
  if (!requestedActionType) {
    return JSON.stringify(makeDecision(requestId, "missing actionType"));
  }
  if (requestedActionType !== expectedActionType) {
    return JSON.stringify(makeDecision(requestId, "actionType does not match sponsored action"));
  }
  const isLmsrAction = request.action === "lmsrBuy" || request.action === "lmsrSell";
  if (isLmsrAction) {
    const lmsrPolicy = runtime.config.lmsrTradePolicy;
    if (!lmsrPolicy?.enabled) {
      return JSON.stringify(makeDecision(requestId, "lmsr trade policy disabled"));
    }
  } else {
    if (!executePolicy?.enabled) {
      return JSON.stringify(makeDecision(requestId, "execute policy disabled"));
    }
    if (!executePolicy.allowedActionTypes.includes(requestedActionType)) {
      return JSON.stringify(makeDecision(requestId, "actionType not allowed by execute policy"));
    }
  }

  const maxAmount = /^\d+$/.test(policy.maxAmountUsdc) ? BigInt(policy.maxAmountUsdc) : DEFAULT_MAX_AMOUNT_USDC;
  let amount: bigint;
  try {
    amount = parseDecimalBigInt(request.amountUsdc, "amountUsdc", true);
  } catch (error) {
    return JSON.stringify(makeDecision(requestId, error instanceof Error ? error.message : "invalid amountUsdc"));
  }
  const allowZeroAmount = ZERO_AMOUNT_ALLOWED_ACTIONS.has(request.action);
  if (!allowZeroAmount && amount <= 0n) {
    return JSON.stringify(makeDecision(requestId, "amountUsdc must be greater than zero"));
  }
  if (amount > maxAmount) {
    return JSON.stringify(makeDecision(requestId, "amount exceeds sponsorship limit"));
  }

  const maxSlippageBps = Number.isFinite(policy.maxSlippageBps) ? policy.maxSlippageBps : DEFAULT_MAX_SLIPPAGE_BPS;
  if (typeof request.slippageBps === "number" && request.slippageBps > maxSlippageBps) {
    return JSON.stringify(makeDecision(requestId, "slippage exceeds sponsorship policy"));
  }

  const sender = request.sender || "";
  if (!HEX_ADDRESS_REGEX.test(sender)) {
    return JSON.stringify(makeDecision(requestId, "invalid sender"));
  }

  const firestoreToken = getFirestoreIdToken(runtime);
  const sessionValidation = await validateSessionAuthorization(runtime, {
    chainId: request.chainId,
    amount,
    amountUsdcRaw: request.amountUsdc || "0",
    action: request.action,
    requestId,
    slippageBps: typeof request.slippageBps === "number" ? request.slippageBps : 0,
    sender,
    session: request.session,
  }, firestoreToken);
  if (!sessionValidation.ok || !sessionValidation.sessionId) {
    return JSON.stringify(makeDecision(requestId, sessionValidation.reason || "invalid session authorization"));
  }

  const approvalExpiresAtUnix = Math.floor(runtime.now().getTime() / 1000) + 360;
  const approvalId = `cre_approval_${runtime.now().getTime()}_${requestId.slice(-8)}_${sender.slice(2, 8)}`;
  createApprovalRecord(runtime, firestoreToken, {
    approvalId,
    requestId,
    sessionId: sessionValidation.sessionId,
    chainId: request.chainId,
    action: request.action,
    actionType: requestedActionType,
    amountUsdc: amount.toString(),
    expiresAtUnix: BigInt(approvalExpiresAtUnix),
  });

  const decision: SponsorDecision = {
    approved: true,
    reason: "approved by CRE sponsor policy",
    requestId,
    approvalId,
    approvalExpiresAtUnix,
  };

  runtime.log(
    `HTTP sponsor decision requestId=${decision.requestId} approved=${decision.approved} reason=${decision.reason}`
  );
  return JSON.stringify(decision);
};
