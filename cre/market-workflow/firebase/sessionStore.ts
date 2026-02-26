import { HTTPClient, consensusIdenticalAggregation, ok, type Runtime } from "@chainlink/cre-sdk";
import { type Config } from "../Constant-variable/config";
import { signUpWorkFlow } from "./signUp";

type FirestoreField =
  | { stringValue: string }
  | { integerValue: string }
  | { booleanValue: boolean }
  | { arrayValue: { values: FirestoreField[] } }
  | { nullValue: null };

type FirestoreDoc = {
  name?: string;
  fields?: Record<string, FirestoreField>;
  updateTime?: string;
};

type FirestoreResponse = {
  statusCode: number;
  bodyText: string;
};

export type SessionGrantRecord = {
  sessionId: string;
  owner: string;
  sessionPublicKey: string;
  chainId: number;
  allowedActions: string[];
  maxAmountUsdc: string;
  expiresAtUnix: bigint;
};

export type ApprovalRecord = {
  approvalId: string;
  requestId: string;
  sessionId: string;
  chainId: number;
  amountUsdc: string;
  expiresAtUnix: bigint;
};

type StoredApproval = {
  sessionId: string;
  chainId: number;
  amountUsdc: string;
  expiresAtUnix: bigint;
  used: boolean;
  updateTime: string;
};

type StoredSession = SessionGrantRecord & {
  revoked: boolean;
  updateTime: string;
};

const SESSIONS_COLLECTION = "aa_sessions";
const APPROVALS_COLLECTION = "aa_approvals";

const toBase64Body = (payload: unknown): string => {
  const bodyBytes = new TextEncoder().encode(JSON.stringify(payload));
  return Buffer.from(bodyBytes).toString("base64");
};

const baseUrl = (projectId: string): string => {
  return `https://firestore.googleapis.com/v1/projects/${projectId}/databases/(default)/documents`;
};

const parseBodyText = <T>(text: string): T | null => {
  if (!text.trim()) return null;
  return JSON.parse(text) as T;
};

const asString = (field?: FirestoreField): string | null => {
  if (!field || !("stringValue" in field)) return null;
  return field.stringValue;
};

const asInteger = (field?: FirestoreField): bigint | null => {
  if (!field || !("integerValue" in field)) return null;
  if (!/^\d+$/.test(field.integerValue)) return null;
  return BigInt(field.integerValue);
};

const asBoolean = (field?: FirestoreField): boolean | null => {
  if (!field || !("booleanValue" in field)) return null;
  return field.booleanValue;
};

const asStringArray = (field?: FirestoreField): string[] => {
  if (!field || !("arrayValue" in field)) return [];
  const values = field.arrayValue.values || [];
  return values
    .map((value) => asString(value))
    .filter((value): value is string => typeof value === "string");
};

const sendFirestoreRequest = (
  runtime: Runtime<Config>,
  idToken: string,
  req: {
    url: string;
    method: "GET" | "POST" | "PATCH";
    body?: unknown;
  }
): FirestoreResponse => {
  const httpClient = new HTTPClient();

  const requester = (sender: any) => {
    const res = sender
      .sendRequest({
        url: req.url,
        method: req.method,
        headers: {
          Authorization: `Bearer ${idToken}`,
          "Content-Type": "application/json",
        },
        ...(req.body ? { body: toBase64Body(req.body) } : {}),
      })
      .result();

    if (!ok(res) && res.statusCode < 400) {
      throw new Error(`Firestore request failed with status ${res.statusCode}`);
    }

    const bodyText = new TextDecoder().decode(res.body);
    return {
      statusCode: res.statusCode,
      bodyText,
    } satisfies FirestoreResponse;
  };

  return httpClient.sendRequest(runtime, requester, consensusIdenticalAggregation())().result();
};

const getProjectId = (runtime: Runtime<Config>): string => {
  return runtime.getSecret({ id: "FIREBASE_PROJECT_ID" }).result().value;
};

const toSessionDocFields = (session: SessionGrantRecord): Record<string, FirestoreField> => ({
  sessionId: { stringValue: session.sessionId },
  owner: { stringValue: session.owner.toLowerCase() },
  sessionPublicKey: { stringValue: session.sessionPublicKey.toLowerCase() },
  chainId: { integerValue: String(session.chainId) },
  allowedActions: {
    arrayValue: {
      values: session.allowedActions.sort().map((action) => ({ stringValue: action })),
    },
  },
  maxAmountUsdc: { stringValue: session.maxAmountUsdc },
  expiresAtUnix: { integerValue: session.expiresAtUnix.toString() },
  revoked: { booleanValue: false },
  createdAtUnix: { integerValue: String(Math.floor(Date.now() / 1000)) },
});

const parseSessionDoc = (doc: FirestoreDoc | null): StoredSession | null => {
  if (!doc?.fields || !doc.updateTime) return null;

  const fields = doc.fields;
  const sessionId = asString(fields.sessionId);
  const owner = asString(fields.owner);
  const sessionPublicKey = asString(fields.sessionPublicKey);
  const chainId = asInteger(fields.chainId);
  const maxAmountUsdc = asString(fields.maxAmountUsdc);
  const expiresAtUnix = asInteger(fields.expiresAtUnix);
  const revoked = asBoolean(fields.revoked);

  if (!sessionId || !owner || !sessionPublicKey || chainId === null || !maxAmountUsdc || expiresAtUnix === null || revoked === null) {
    return null;
  }

  return {
    sessionId,
    owner,
    sessionPublicKey,
    chainId: Number(chainId),
    allowedActions: asStringArray(fields.allowedActions).sort(),
    maxAmountUsdc,
    expiresAtUnix,
    revoked,
    updateTime: doc.updateTime,
  };
};

const getSessionDoc = (runtime: Runtime<Config>, idToken: string, sessionId: string): FirestoreDoc | null => {
  const projectId = getProjectId(runtime);
  const url = `${baseUrl(projectId)}/${SESSIONS_COLLECTION}/${encodeURIComponent(sessionId)}`;
  const response = sendFirestoreRequest(runtime, idToken, {
    url,
    method: "GET",
  });

  if (response.statusCode === 404) return null;
  if (response.statusCode !== 200 || !response.bodyText.trim()) {
    throw new Error(`failed to fetch session state (${response.statusCode})`);
  }
  return parseBodyText<FirestoreDoc>(response.bodyText);
};

const createSessionDoc = (runtime: Runtime<Config>, idToken: string, session: SessionGrantRecord): boolean => {
  const projectId = getProjectId(runtime);
  const url = `${baseUrl(projectId)}/${SESSIONS_COLLECTION}/${encodeURIComponent(session.sessionId)}?currentDocument.exists=false`;

  const response = sendFirestoreRequest(runtime, idToken, {
    url,
    method: "PATCH",
    body: {
      fields: toSessionDocFields(session),
    },
  });

  if (response.statusCode === 200) return true;
  if (response.statusCode === 409 || response.statusCode === 412) return false;
  throw new Error(`failed to create session state (${response.statusCode})`);
};

const markSessionRevoked = (
  runtime: Runtime<Config>,
  idToken: string,
  sessionId: string,
  updateTime: string
): boolean => {
  const projectId = getProjectId(runtime);
  const mask = "updateMask.fieldPaths=revoked&updateMask.fieldPaths=revokedAtUnix";
  const precondition = `currentDocument.updateTime=${encodeURIComponent(updateTime)}`;
  const url = `${baseUrl(projectId)}/${SESSIONS_COLLECTION}/${encodeURIComponent(sessionId)}?${mask}&${precondition}`;

  const response = sendFirestoreRequest(runtime, idToken, {
    url,
    method: "PATCH",
    body: {
      fields: {
        revoked: { booleanValue: true },
        revokedAtUnix: { integerValue: String(Math.floor(runtime.now().getTime() / 1000)) },
      },
    },
  });

  return response.statusCode === 200;
};

export const getFirestoreIdToken = (runtime: Runtime<Config>): string => {
  const auth = signUpWorkFlow(runtime);
  if (!auth?.idToken) throw new Error("firebase sign-up did not return idToken");
  return auth.idToken;
};

const sessionsEqual = (a: SessionGrantRecord, b: SessionGrantRecord): boolean => {
  return (
    a.sessionId === b.sessionId &&
    a.owner.toLowerCase() === b.owner.toLowerCase() &&
    a.sessionPublicKey.toLowerCase() === b.sessionPublicKey.toLowerCase() &&
    a.chainId === b.chainId &&
    a.maxAmountUsdc === b.maxAmountUsdc &&
    a.expiresAtUnix === b.expiresAtUnix &&
    [...a.allowedActions].sort().join(",") === [...b.allowedActions].sort().join(",")
  );
};

export const upsertAndValidateSession = (
  runtime: Runtime<Config>,
  idToken: string,
  session: SessionGrantRecord
): { ok: true } | { ok: false; reason: string } => {
  const existing = getSessionDoc(runtime, idToken, session.sessionId);

  if (!existing) {
    const created = createSessionDoc(runtime, idToken, session);
    if (created) return { ok: true };

    const reloaded = getSessionDoc(runtime, idToken, session.sessionId);
    const reloadedSession = parseSessionDoc(reloaded);
    if (!reloadedSession) return { ok: false, reason: "stored session state is malformed" };
    if (reloadedSession.revoked) return { ok: false, reason: "session revoked" };
    if (!sessionsEqual(session, reloadedSession)) {
      return { ok: false, reason: "session metadata mismatch" };
    }
    return { ok: true };
  }

  const stored = parseSessionDoc(existing);
  if (!stored) return { ok: false, reason: "stored session state is malformed" };
  if (stored.revoked) return { ok: false, reason: "session revoked" };
  if (!sessionsEqual(session, stored)) {
    return { ok: false, reason: "session metadata mismatch" };
  }

  return { ok: true };
};

export const revokeSessionRecord = (
  runtime: Runtime<Config>,
  idToken: string,
  sessionId: string,
  owner: string,
  chainId: number
): { ok: true } | { ok: false; reason: string } => {
  const existing = getSessionDoc(runtime, idToken, sessionId);
  if (!existing) return { ok: false, reason: "session not found" };

  const stored = parseSessionDoc(existing);
  if (!stored) return { ok: false, reason: "stored session state is malformed" };
  if (stored.owner.toLowerCase() !== owner.toLowerCase()) {
    return { ok: false, reason: "session owner mismatch" };
  }
  if (stored.chainId !== chainId) {
    return { ok: false, reason: "session chain mismatch" };
  }
  if (stored.revoked) return { ok: true };

  const revoked = markSessionRevoked(runtime, idToken, sessionId, stored.updateTime);
  if (!revoked) return { ok: false, reason: "session revoke failed" };
  return { ok: true };
};

export const reserveSessionNonce = (
  runtime: Runtime<Config>,
  idToken: string,
  sessionId: string,
  nonce: string,
  intentHash: string
): { ok: true } | { ok: false; reason: string } => {
  const projectId = getProjectId(runtime);
  const url = `${baseUrl(projectId)}/${SESSIONS_COLLECTION}/${encodeURIComponent(
    sessionId
  )}/used_nonces?documentId=${encodeURIComponent(nonce)}`;

  const response = sendFirestoreRequest(runtime, idToken, {
    url,
    method: "POST",
    body: {
      fields: {
        nonce: { stringValue: nonce },
        intentHash: { stringValue: intentHash.toLowerCase() },
        createdAtUnix: { integerValue: String(Math.floor(runtime.now().getTime() / 1000)) },
      },
    },
  });

  if (response.statusCode === 200) return { ok: true };
  if (response.statusCode === 409) {
    return { ok: false, reason: "session nonce already used" };
  }
  return { ok: false, reason: `failed to reserve session nonce (${response.statusCode})` };
};

export const createApprovalRecord = (
  runtime: Runtime<Config>,
  idToken: string,
  approval: ApprovalRecord
): void => {
  const projectId = getProjectId(runtime);
  const url = `${baseUrl(projectId)}/${APPROVALS_COLLECTION}/${encodeURIComponent(approval.approvalId)}?currentDocument.exists=false`;

  const response = sendFirestoreRequest(runtime, idToken, {
    url,
    method: "PATCH",
    body: {
      fields: {
        approvalId: { stringValue: approval.approvalId },
        requestId: { stringValue: approval.requestId },
        sessionId: { stringValue: approval.sessionId },
        chainId: { integerValue: String(approval.chainId) },
        amountUsdc: { stringValue: approval.amountUsdc },
        expiresAtUnix: { integerValue: approval.expiresAtUnix.toString() },
        used: { booleanValue: false },
        createdAtUnix: { integerValue: String(Math.floor(runtime.now().getTime() / 1000)) },
      },
    },
  });

  if (response.statusCode !== 200) {
    throw new Error(`failed to create approval (${response.statusCode})`);
  }
};

const getApprovalDoc = (runtime: Runtime<Config>, idToken: string, approvalId: string): FirestoreDoc | null => {
  const projectId = getProjectId(runtime);
  const url = `${baseUrl(projectId)}/${APPROVALS_COLLECTION}/${encodeURIComponent(approvalId)}`;
  const response = sendFirestoreRequest(runtime, idToken, {
    url,
    method: "GET",
  });

  if (response.statusCode === 404) return null;
  if (response.statusCode !== 200 || !response.bodyText.trim()) {
    throw new Error(`failed to fetch approval state (${response.statusCode})`);
  }
  return parseBodyText<FirestoreDoc>(response.bodyText);
};

const parseApprovalDoc = (doc: FirestoreDoc | null): StoredApproval | null => {
  if (!doc?.fields || !doc.updateTime) return null;
  const fields = doc.fields;

  const sessionId = asString(fields.sessionId);
  const chainId = asInteger(fields.chainId);
  const amountUsdc = asString(fields.amountUsdc);
  const expiresAtUnix = asInteger(fields.expiresAtUnix);
  const used = asBoolean(fields.used);

  if (!sessionId || chainId === null || !amountUsdc || expiresAtUnix === null || used === null) {
    return null;
  }

  return {
    sessionId,
    chainId: Number(chainId),
    amountUsdc,
    expiresAtUnix,
    used,
    updateTime: doc.updateTime,
  };
};

const markApprovalUsed = (
  runtime: Runtime<Config>,
  idToken: string,
  approvalId: string,
  updateTime: string
): boolean => {
  const projectId = getProjectId(runtime);
  const mask = "updateMask.fieldPaths=used&updateMask.fieldPaths=usedAtUnix";
  const precondition = `currentDocument.updateTime=${encodeURIComponent(updateTime)}`;
  const url = `${baseUrl(projectId)}/${APPROVALS_COLLECTION}/${encodeURIComponent(approvalId)}?${mask}&${precondition}`;

  const response = sendFirestoreRequest(runtime, idToken, {
    url,
    method: "PATCH",
    body: {
      fields: {
        used: { booleanValue: true },
        usedAtUnix: { integerValue: String(Math.floor(runtime.now().getTime() / 1000)) },
      },
    },
  });

  return response.statusCode === 200;
};

export const consumeApprovalRecord = (
  runtime: Runtime<Config>,
  idToken: string,
  expected: {
    approvalId: string;
    chainId: number;
    amountUsdc: string;
    nowUnix: bigint;
  }
): { ok: true; sessionId: string } | { ok: false; reason: string } => {
  const doc = getApprovalDoc(runtime, idToken, expected.approvalId);
  if (!doc) return { ok: false, reason: "approval does not exist" };

  const stored = parseApprovalDoc(doc);
  if (!stored) return { ok: false, reason: "approval state is malformed" };
  if (stored.used) return { ok: false, reason: "approval already used" };
  if (stored.chainId !== expected.chainId) return { ok: false, reason: "approval chain mismatch" };
  if (stored.amountUsdc !== expected.amountUsdc) return { ok: false, reason: "approval amount mismatch" };
  if (stored.expiresAtUnix < expected.nowUnix) return { ok: false, reason: "approval expired" };

  const sessionDoc = getSessionDoc(runtime, idToken, stored.sessionId);
  if (!sessionDoc) return { ok: false, reason: "session not found for approval" };
  const session = parseSessionDoc(sessionDoc);
  if (!session) return { ok: false, reason: "stored session state is malformed" };
  if (session.revoked) return { ok: false, reason: "session revoked" };
  if (session.expiresAtUnix < expected.nowUnix) return { ok: false, reason: "session expired" };

  const marked = markApprovalUsed(runtime, idToken, expected.approvalId, stored.updateTime);
  if (!marked) return { ok: false, reason: "approval could not be consumed" };

  return { ok: true, sessionId: stored.sessionId };
};
