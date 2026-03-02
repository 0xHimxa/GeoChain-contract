import { type HTTPPayload, type Runtime } from "@chainlink/cre-sdk";
import { verifyTypedData } from "viem";
import { type Config } from "../../Constant-variable/config";
import { getFirestoreIdToken, revokeSessionRecord } from "../../firebase/sessionStore";
import { createSessionEip712Domain, SESSION_REVOKE_TYPES } from "../utils/sessionMessage";

type RevokeRequest = {
  requestId?: string;
  sessionId?: string;
  owner?: string;
  chainId?: number;
  revokeSignature?: string;
};

type RevokeResponse = {
  revoked: boolean;
  requestId: string;
  reason?: string;
};

const HEX_ADDRESS_REGEX = /^0x[a-fA-F0-9]{40}$/;
const HEX_BYTES_REGEX = /^0x([a-fA-F0-9]{2})*$/;

const decodePayloadInput = (payload: HTTPPayload): string => {
  return new TextDecoder().decode(payload.input);
};

const parseRequest = (raw: string): RevokeRequest => {
  if (!raw.trim()) throw new Error("empty payload");
  return JSON.parse(raw) as RevokeRequest;
};

const makeResponse = (requestId: string, reason: string): string => {
  return JSON.stringify({
    revoked: false,
    requestId,
    reason,
  } satisfies RevokeResponse);
};

/**
 * Accepts a signed session-revoke request, verifies the EIP-712 signature against
 * the session owner and chain domain, then marks the stored session as revoked so
 * future sponsorship requests using that session are rejected.
 */
export const revokeSessionHttpHandler = async (runtime: Runtime<Config>, payload: HTTPPayload): Promise<string> => {
  const requestIdFallback = `revoke_${runtime.now().toISOString()}`;
  const authKeys = runtime.config.httpTriggerAuthorizedKeys || [];
  if (authKeys.length === 0) {
    return makeResponse(requestIdFallback, "no authorized HTTP trigger keys configured");
  }

  let request: RevokeRequest;
  try {
    request = parseRequest(decodePayloadInput(payload));
  } catch (error) {
    return makeResponse(requestIdFallback, error instanceof Error ? error.message : "invalid payload");
  }

  const requestId = request.requestId || requestIdFallback;
  const sessionId = (request.sessionId || "").trim();
  const owner = (request.owner || "").trim();
  const chainIdRaw = request.chainId;
  const revokeSignature = (request.revokeSignature || "").trim();

  if (!/^[a-zA-Z0-9_-]{12,100}$/.test(sessionId)) {
    return makeResponse(requestId, "invalid sessionId");
  }
  if (!HEX_ADDRESS_REGEX.test(owner)) {
    return makeResponse(requestId, "invalid owner");
  }
  if (typeof chainIdRaw !== "number" || !Number.isInteger(chainIdRaw) || chainIdRaw <= 0) {
    return makeResponse(requestId, "invalid chainId");
  }
  const chainId = chainIdRaw;
  if (!HEX_BYTES_REGEX.test(revokeSignature) || revokeSignature === "0x") {
    return makeResponse(requestId, "invalid revokeSignature");
  }

  const sigOk = await verifyTypedData({
    address: owner as `0x${string}`,
    domain: createSessionEip712Domain(chainId),
    types: SESSION_REVOKE_TYPES,
    primaryType: "SessionRevoke",
    message: {
      sessionId,
      owner: owner as `0x${string}`,
      chainId: BigInt(chainId),
    },
    signature: revokeSignature as `0x${string}`,
  });
  if (!sigOk) {
    return makeResponse(requestId, "invalid revoke signature");
  }

  const firestoreToken = getFirestoreIdToken(runtime);
  const revokeResult = revokeSessionRecord(runtime, firestoreToken, sessionId, owner, chainId);
  if (!revokeResult.ok) {
    return makeResponse(requestId, revokeResult.reason);
  }

  return JSON.stringify({
    revoked: true,
    requestId,
  } satisfies RevokeResponse);
};
