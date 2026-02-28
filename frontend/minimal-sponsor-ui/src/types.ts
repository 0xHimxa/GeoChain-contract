export type UiPage = "markets" | "deposit" | "fiat" | "positions";

export type WalletIdentity = {
  address: string;
  publicKey: string;
};

export type SessionIdentity = {
  address: string;
  publicKey: string;
  privateKey?: string;
};

export type UserProfile = {
  sessionToken: string;
  name: string;
  email: string;
  walletAddress: string;
  vaultBalanceUsdc: string;
  wallet: WalletIdentity;
  session: SessionIdentity;
};

export type AuthResponse = {
  ok: boolean;
  user: UserProfile;
};

export type MarketEvent = {
  id: string;
  chainId?: number;
  marketId?: string;
  marketAddress: string;
  yesToken?: string;
  noToken?: string;
  question: string;
  closeTimeUnix: number;
  resolutionTimeUnix: number;
  state: "open" | "closed" | "resolved";
  resolutionOutcome: "yes" | "no" | null;
  yesPriceBps: number;
  noPriceBps: number;
  createdAtUnix: number;
};

export type Position = {
  eventId: string;
  question: string;
  yesShares: string;
  noShares: string;
  completeSetsMinted: string;
  redeemableUsdc: string;
};

export type ActionResponse = {
  approved?: boolean;
  stage?: string;
  creDecision?: Record<string, unknown>;
  execute?: Record<string, unknown>;
  [key: string]: unknown;
};

export type FiatResponse = {
  ok: boolean;
  sentToCre: boolean;
  reason: string;
  providerSuccess: Record<string, unknown>;
  crePayload: Record<string, unknown>;
  vaultBalanceUsdc: string;
};
