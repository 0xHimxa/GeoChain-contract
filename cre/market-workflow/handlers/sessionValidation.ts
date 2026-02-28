import { type Runtime } from "@chainlink/cre-sdk";
import { hashTypedData, keccak256, stringToHex, verifyTypedData } from "viem";
import { type Config } from "../Constant-variable/config";
import { getFirestoreIdToken, reserveSessionNonce, upsertAndValidateSession, type SessionGrantRecord } from "../firebase/sessionStore";
import {
  createSessionEip712Domain,
  serializeAllowedActions,
  SESSION_GRANT_TYPES,
  SPONSOR_INTENT_TYPES,
} from "./sessionMessage";

export type SessionAuthorization = {
  sessionId?: string;
  owner?: string;
  sessionPublicKey?: string;
  chainId?: number;
  allowedActions?: string[];
  maxAmountUsdc?: string;
  expiresAtUnix?: string | number;
  grantSignature?: string;
  requestNonce?: string;
  requestSignature?: string;
};

export type SessionValidationInput = {
  chainId: number;
  requestId: string;
  action: string;
  amount: bigint;
  amountUsdcRaw: string;
  slippageBps: number;
  sender: string;
  session?: SessionAuthorization;
};

export type SessionValidationResult = {
  ok: boolean;
  reason?: string;
  sessionId?: string;
};

const HEX_ADDRESS_REGEX = /^0x[a-fA-F0-9]{40}$/;
const HEX_BYTES_REGEX = /^0x([a-fA-F0-9]{2})*$/;
const HEX_UNCOMPRESSED_PUBKEY_REGEX = /^0x04[a-fA-F0-9]{128}$/;
const NONCE_REGEX = /^[a-zA-Z0-9_-]{8,80}$/;

const parseUintString = (value: unknown): bigint | null => {
  if (typeof value === "string" && /^\d+$/.test(value)) return BigInt(value);
  if (typeof value === "number" && Number.isSafeInteger(value) && value >= 0) return BigInt(value);
  return null;
};

const toLower = (value: string): string => value.toLowerCase();

const isAddressEqual = (a: string, b: string): boolean => toLower(a) === toLower(b);

const addressFromPublicKey = (publicKey: string): string | null => {
  if (!HEX_UNCOMPRESSED_PUBKEY_REGEX.test(publicKey)) return null;
  const uncompressedNoPrefix = `0x${publicKey.slice(4)}`;
  const hash = keccak256(uncompressedNoPrefix as `0x${string}`);
  return `0x${hash.slice(-40)}`;
};

export const validateSessionAuthorization = async (
  runtime: Runtime<Config>,
  input: SessionValidationInput,
  existingFirestoreToken?: string
): Promise<SessionValidationResult> => {
  const requireSession = runtime.config.sponsorPolicy?.requireSessionAuthorization ?? true;
  if (!requireSession) return { ok: true };

  const session = input.session;
  if (!session) return { ok: false, reason: "missing session authorization" };

  const sessionId = (session.sessionId || "").trim();
  const owner = (session.owner || "").trim();
  const sessionPublicKey = (session.sessionPublicKey || "").trim();
  const grantSignature = (session.grantSignature || "").trim();
  const requestNonce = (session.requestNonce || "").trim();
  const requestSignature = (session.requestSignature || "").trim();

  if (!/^[a-zA-Z0-9_-]{12,100}$/.test(sessionId)) return { ok: false, reason: "invalid session.sessionId" };
  if (!HEX_ADDRESS_REGEX.test(owner)) return { ok: false, reason: "invalid session.owner" };
  if (!HEX_UNCOMPRESSED_PUBKEY_REGEX.test(sessionPublicKey)) return { ok: false, reason: "invalid session.sessionPublicKey" };
  if (!HEX_BYTES_REGEX.test(grantSignature) || grantSignature === "0x") {
    return { ok: false, reason: "invalid session.grantSignature" };
  }
  if (!NONCE_REGEX.test(requestNonce)) return { ok: false, reason: "invalid session.requestNonce" };
  if (!HEX_BYTES_REGEX.test(requestSignature) || requestSignature === "0x") {
    return { ok: false, reason: "invalid session.requestSignature" };
  }

  if (session.chainId !== input.chainId) {
    return { ok: false, reason: "session.chainId mismatch" };
  }

  const allowedActions = Array.isArray(session.allowedActions)
    ? session.allowedActions.map((action) => String(action).trim()).filter(Boolean)
    : [];
  if (allowedActions.length === 0) {
    return { ok: false, reason: "session.allowedActions cannot be empty" };
  }
  if (!allowedActions.includes(input.action)) {
    return {
      ok: false,
      reason: `session does not allow this action: requested=${input.action}; allowed=${allowedActions.join(",")}`,
    };
  }

  const maxAmountUsdc = parseUintString(session.maxAmountUsdc);
  if (maxAmountUsdc === null) return { ok: false, reason: "session.maxAmountUsdc must be uint string" };
  if (maxAmountUsdc < input.amount) {
    return { ok: false, reason: "session max amount below requested amount" };
  }
  if (!Number.isInteger(input.slippageBps) || input.slippageBps < 0) {
    return { ok: false, reason: "slippageBps must be a non-negative integer" };
  }

  const expiresAtUnix = parseUintString(session.expiresAtUnix);
  if (expiresAtUnix === null) return { ok: false, reason: "session.expiresAtUnix must be uint" };
  const nowUnix = BigInt(Math.floor(runtime.now().getTime() / 1000));
  if (expiresAtUnix < nowUnix) return { ok: false, reason: "session expired" };

  const policyMaxSessionDurationSec = runtime.config.sponsorPolicy?.sessionMaxDurationSec || 86_400;
  if (expiresAtUnix > nowUnix + BigInt(policyMaxSessionDurationSec)) {
    return { ok: false, reason: "session duration exceeds policy" };
  }

  if (!isAddressEqual(input.sender, owner)) {
    return { ok: false, reason: "session.owner must match sender" };
  }

  const allowedActionsHash = keccak256(stringToHex(serializeAllowedActions(allowedActions)));
  const grantSigOk = await verifyTypedData({
    address: owner as `0x${string}`,
    domain: createSessionEip712Domain(input.chainId),
    types: SESSION_GRANT_TYPES,
    primaryType: "SessionGrant",
    message: {
      sessionId,
      owner: owner as `0x${string}`,
      sessionPublicKey: sessionPublicKey as `0x${string}`,
      chainId: BigInt(input.chainId),
      allowedActionsHash,
      maxAmountUsdc,
      expiresAtUnix,
    },
    signature: grantSignature as `0x${string}`,
  });
  if (!grantSigOk) return { ok: false, reason: "invalid session grant signature" };

  const sessionAddress = addressFromPublicKey(sessionPublicKey);
  if (!sessionAddress) return { ok: false, reason: "invalid session public key" };

  const intentMessage = {
    requestId: input.requestId,
    sessionId,
    requestNonce,
    chainId: BigInt(input.chainId),
    action: input.action,
    amountUsdc: input.amount,
    slippageBps: BigInt(input.slippageBps),
    sender: input.sender as `0x${string}`,
  };

  const requestSigOk = await verifyTypedData({
    address: sessionAddress as `0x${string}`,
    domain: createSessionEip712Domain(input.chainId),
    types: SPONSOR_INTENT_TYPES,
    primaryType: "SponsorIntent",
    message: intentMessage,
    signature: requestSignature as `0x${string}`,
  });
  if (!requestSigOk) return { ok: false, reason: "invalid session request signature" };

  const firestoreToken = existingFirestoreToken || getFirestoreIdToken(runtime);
  const storeSessionResult = upsertAndValidateSession(runtime, firestoreToken, {
    sessionId,
    owner: owner.toLowerCase(),
    sessionPublicKey: sessionPublicKey.toLowerCase(),
    chainId: input.chainId,
    allowedActions,
    maxAmountUsdc: maxAmountUsdc.toString(),
    expiresAtUnix,
  } satisfies SessionGrantRecord);

  if (!storeSessionResult.ok) {
    return { ok: false, reason: storeSessionResult.reason };
  }

  const intentHash = hashTypedData({
    domain: createSessionEip712Domain(input.chainId),
    types: SPONSOR_INTENT_TYPES,
    primaryType: "SponsorIntent",
    message: intentMessage,
  });
  const nonceResult = reserveSessionNonce(runtime, firestoreToken, sessionId, requestNonce, intentHash);
  if (!nonceResult.ok) {
    return { ok: false, reason: nonceResult.reason };
  }

  return { ok: true, sessionId };
};
