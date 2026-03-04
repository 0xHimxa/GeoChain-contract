const AGENT_API_BASE = import.meta.env.VITE_AGENT_API_BASE_URL || "http://localhost:5175";

type JsonValue = Record<string, unknown>;

const coerceJson = (value: unknown): unknown => {
  if (typeof value !== "string") return value;
  const raw = value.trim();
  if (!raw) return value;
  if ((raw.startsWith("{") && raw.endsWith("}")) || (raw.startsWith("[") && raw.endsWith("]"))) {
    try {
      return JSON.parse(raw);
    } catch {
      return value;
    }
  }
  return value;
};

async function request<T>(path: string, init?: RequestInit): Promise<T> {
  const res = await fetch(`${AGENT_API_BASE}${path}`, {
    ...init,
    headers: {
      "content-type": "application/json",
      ...(init?.headers || {}),
    },
  });

  if (!res.ok) {
    const parsed = coerceJson(await res.json().catch(() => ({})));
    const body = (parsed && typeof parsed === "object" ? parsed : {}) as JsonValue;
    throw new Error(String(body.error || `request failed: ${res.status}`));
  }

  const parsed = coerceJson(await res.json());
  return parsed as T;
}

export type AgentAction =
  | "mintCompleteSets"
  | "redeemCompleteSets"
  | "swapYesForNo"
  | "swapNoForYes"
  | "addLiquidity"
  | "removeLiquidity"
  | "redeem"
  | "disputeProposedResolution";

export type AgentTradeDraft = {
  requestId: string;
  chainId: number;
  sender: string;
  user: string;
  agent: string;
  market: string;
  action: AgentAction;
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
};

export type SessionAuthorizationPayload = {
  sessionId: string;
  owner: string;
  sessionPublicKey: string;
  chainId: number;
  allowedActions: string[];
  maxAmountUsdc: string;
  expiresAtUnix: number;
  grantSignature: string;
  requestNonce: string;
  requestSignature: string;
};

export const agentPlan = (payload: AgentTradeDraft): Promise<Record<string, unknown>> =>
  request("/api/agent/plan", {
    method: "POST",
    body: JSON.stringify(payload),
  });

export const agentSponsor = (
  payload: AgentTradeDraft & {
    session: SessionAuthorizationPayload;
  }
): Promise<Record<string, unknown>> =>
  request("/api/agent/sponsor", {
    method: "POST",
    body: JSON.stringify(payload),
  });

export const agentExecute = (
  payload: Omit<AgentTradeDraft, "sender"> & { approvalId: string }
): Promise<Record<string, unknown>> =>
  request("/api/agent/execute", {
    method: "POST",
    body: JSON.stringify(payload),
  });

export const agentRevoke = (payload: { requestId: string; chainId: number; user: string; agent: string; reason?: string }): Promise<Record<string, unknown>> =>
  request("/api/agent/revoke", {
    method: "POST",
    body: JSON.stringify(payload),
  });
