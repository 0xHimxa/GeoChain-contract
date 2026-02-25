import { type HTTPPayload, type Runtime } from "@chainlink/cre-sdk";
import { type Config } from "../Constant-variable/config";

// Payload shape expected by CRE HTTP trigger callers (frontend/adapter).
type SponsorRequest = {
  requestId?: string;
  chainId?: number;
  action?: string;
  amountUsdc?: string;
  slippageBps?: number;
  userOp?: {
    sender?: string;
    nonce?: string;
    callData?: string;
    signature?: string;
  };
};

type SponsorDecision = {
  approved: boolean;
  reason: string;
  requestId: string;
  approvalId?: string;
  approvalExpiresAtUnix?: number;
};

const HEX_ADDRESS_REGEX = /^0x[a-fA-F0-9]{40}$/;
const HEX_BYTES_REGEX = /^0x([a-fA-F0-9]{2})*$/;
const DEFAULT_MAX_AMOUNT_USDC = 1000n;
const DEFAULT_MAX_SLIPPAGE_BPS = 300;
const DEFAULT_ALLOWED_ACTIONS = new Set([
  "addLiquidity",
  "removeLiquidity",
  "swapYesForNo",
  "swapNoForYes",
  "mintCompleteSets",
  "redeemCompleteSets",
]);

/**
 * CRE gives HTTP trigger input as bytes.
 * We decode those bytes into a UTF-8 JSON string.
 */
const decodePayloadInput = (payload: HTTPPayload): string => {
  return new TextDecoder().decode(payload.input);
};

/**
 * Parse raw request JSON sent to the HTTP trigger.
 */
const parseRequest = (raw: string): SponsorRequest => {
  if (!raw.trim()) {
    throw new Error("empty payload");
  }
  return JSON.parse(raw) as SponsorRequest;
};

/**
 * Amount is represented as string to avoid JS number precision issues.
 */
const toBigIntAmount = (value?: string): bigint => {
  if (!value) return 0n;
  if (!/^\d+$/.test(value)) {
    throw new Error("amountUsdc must be a numeric string");
  }
  return BigInt(value);
};

const makeDecision = (
  runtime: Runtime<Config>,
  request: SponsorRequest,
  validationFailedReason?: string
): SponsorDecision => {
  // Keep request ids deterministic when caller doesn't provide one.
  const requestId = request.requestId || `req_${runtime.now().toString()}`;
  if (validationFailedReason) {
    return { approved: false, reason: validationFailedReason, requestId };
  }

  // Policy is fully config-driven so governance can update limits without code changes.
  const policy = runtime.config.sponsorPolicy;
  if (!policy || !policy.enabled) {
    return { approved: false, reason: "sponsor policy disabled", requestId };
  }

  if (typeof request.chainId !== "number") {
    return { approved: false, reason: "missing chainId", requestId };
  }

  if (!policy.supportedChainIds.includes(request.chainId)) {
    return { approved: false, reason: "chain is not sponsorable", requestId };
  }

  if (!request.action || !policy.allowedActions.includes(request.action)) {
    return { approved: false, reason: "action is not sponsorable", requestId };
  }

  const maxAmount = /^\d+$/.test(policy.maxAmountUsdc) ? BigInt(policy.maxAmountUsdc) : DEFAULT_MAX_AMOUNT_USDC;
  const amount = toBigIntAmount(request.amountUsdc);
  if (amount > maxAmount) {
    return { approved: false, reason: "amount exceeds sponsorship limit", requestId };
  }

  const maxSlippageBps = Number.isFinite(policy.maxSlippageBps) ? policy.maxSlippageBps : DEFAULT_MAX_SLIPPAGE_BPS;
  if (typeof request.slippageBps === "number" && request.slippageBps > maxSlippageBps) {
    return { approved: false, reason: "slippage exceeds sponsorship policy", requestId };
  }

  // Basic structural checks for a UserOperation-like object.
  const sender = request.userOp?.sender || "";
  const signature = request.userOp?.signature || "";
  const callData = request.userOp?.callData || "";
  if (!HEX_ADDRESS_REGEX.test(sender)) {
    return { approved: false, reason: "invalid userOp.sender", requestId };
  }
  if (!HEX_BYTES_REGEX.test(callData)) {
    return { approved: false, reason: "invalid userOp.callData", requestId };
  }
  if (!HEX_BYTES_REGEX.test(signature) || signature === "0x") {
    return { approved: false, reason: "invalid userOp.signature", requestId };
  }

  // Short-lived approval window so paymaster cannot reuse old decisions forever.
  const approvalId = `cre_approval_${runtime.now().toString()}_${sender.slice(2, 8)}`;
  const approvalExpiresAtUnix = Math.floor(runtime.now().getTime() / 1000) + 120;
  return {
    approved: true,
    reason: "approved by CRE sponsor policy",
    requestId,
    approvalId,
    approvalExpiresAtUnix,
  };
};

export const sponsorUserOpPolicyHandler = (runtime: Runtime<Config>, payload: HTTPPayload): string => {
  const policy = runtime.config.sponsorPolicy;
  const authKeys = runtime.config.httpTriggerAuthorizedKeys || [];

  // Fast fail when sponsorship is globally disabled.
  if (!policy?.enabled) {
    return JSON.stringify({
      approved: false,
      reason: "sponsorship disabled",
      requestId: `req_${runtime.now().toString()}`,
    } satisfies SponsorDecision);
  }

  // HTTP trigger should be key-gated in CRE config.
  if (authKeys.length === 0) {
    return JSON.stringify({
      approved: false,
      reason: "no authorized HTTP trigger keys configured",
      requestId: `req_${runtime.now().toString()}`,
    } satisfies SponsorDecision);
  }

  let request: SponsorRequest;
  try {
    request = parseRequest(decodePayloadInput(payload));
  } catch (error) {
    const reason = error instanceof Error ? error.message : "invalid payload";
    return JSON.stringify(makeDecision(runtime, {}, reason));
  }

  // Extra hardcoded allowlist to avoid accidental broad policy config.
  if (request.action && !DEFAULT_ALLOWED_ACTIONS.has(request.action)) {
    return JSON.stringify(makeDecision(runtime, request, "unknown action"));
  }

  const decision = makeDecision(runtime, request);
  runtime.log(
    `HTTP sponsor decision requestId=${decision.requestId} approved=${decision.approved} reason=${decision.reason}`
  );
  return JSON.stringify(decision);
};
