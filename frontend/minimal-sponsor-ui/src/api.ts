import type { ActionResponse, AuthResponse, FiatResponse, MarketEvent, Position } from "./types";

const API_BASE = import.meta.env.VITE_API_BASE_URL || "http://localhost:5173";

type JsonValue = Record<string, unknown>;

async function request<T>(path: string, init?: RequestInit): Promise<T> {
  const res = await fetch(`${API_BASE}${path}`, {
    ...init,
    headers: {
      "content-type": "application/json",
      ...(init?.headers || {}),
    },
  });
  if (!res.ok) {
    const body = (await res.json().catch(() => ({}))) as JsonValue;
    throw new Error(String(body.error || `request failed: ${res.status}`));
  }
  return (await res.json()) as T;
}

export const signInWithGoogleMock = (email: string, name: string): Promise<AuthResponse> =>
  request("/api/auth/google/mock", {
    method: "POST",
    body: JSON.stringify({ email, name }),
  });

export const signInWithGoogleAndSession = (
  email: string,
  name: string,
  body: {
    walletAddress: string;
    sessionAddress: string;
    sessionPublicKey: string;
  }
): Promise<AuthResponse> =>
  request("/api/auth/google/mock", {
    method: "POST",
    body: JSON.stringify({ email, name, ...body }),
  });

export const fetchMarkets = (sessionToken: string): Promise<{ events: MarketEvent[]; vaultBalanceUsdc: string }> =>
  request("/api/events", {
    headers: {
      "x-session-token": sessionToken,
    },
  });

export const fetchPositions = (sessionToken: string): Promise<{ positions: Position[]; vaultBalanceUsdc: string }> =>
  request("/api/positions", {
    headers: {
      "x-session-token": sessionToken,
    },
  });

export const depositToVault = (sessionToken: string, amountUsdc: string): Promise<{ ok: boolean; vaultBalanceUsdc: string; note: string }> =>
  request("/api/vault/deposit", {
    method: "POST",
    headers: {
      "x-session-token": sessionToken,
    },
    body: JSON.stringify({ amountUsdc }),
  });

export const submitFiatPayment = (
  sessionToken: string,
  body: { amountUsd: string; provider: string; paymentId?: string; requestId?: string }
): Promise<FiatResponse> =>
  request("/api/fiat-payment-success", {
    method: "POST",
    headers: {
      "x-session-token": sessionToken,
    },
    body: JSON.stringify(body),
  });

export const submitAction = (
  body: {
    requestId?: string;
    chainId: number;
    action: string;
    actionType: string;
    amountUsdc: string;
    sender: string;
    slippageBps: number;
    reportPayloadHex: string;
    session?: Record<string, unknown>;
  }
): Promise<ActionResponse> =>
  request("/api/sponsor", {
    method: "POST",
    body: JSON.stringify(body),
  });

export const submitExternalDepositFunding = (body: {
  chainId: number;
  funder: string;
  beneficiary: string;
  amountUsdc: string;
  txHash: string;
}): Promise<Record<string, unknown>> =>
  request("/api/funding/external-deposit", {
    method: "POST",
    body: JSON.stringify(body),
  });

export const eventStreamUrl = (sessionToken: string): string =>
  `${API_BASE}/api/events/stream?sessionToken=${encodeURIComponent(sessionToken)}`;
