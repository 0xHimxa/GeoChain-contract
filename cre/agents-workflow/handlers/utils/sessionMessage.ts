export type SessionGrantShape = {
  sessionId: string;
  owner: string;
  sessionPublicKey: string;
  chainId: number;
  allowedActions: string[];
  maxAmountUsdc: string;
  expiresAtUnix: bigint;
};

export type SponsorIntentShape = {
  requestId: string;
  sessionId: string;
  requestNonce: string;
  chainId: number;
  action: string;
  amountUsdc: string;
  slippageBps: number;
  sender: string;
};

export type SessionRevokeShape = {
  sessionId: string;
  owner: string;
  chainId: number;
};

export const SESSION_EIP712_NAME = "CRE Session Authorization";
export const SESSION_EIP712_VERSION = "1";

export const SESSION_GRANT_TYPES = {
  SessionGrant: [
    { name: "sessionId", type: "string" },
    { name: "owner", type: "address" },
    { name: "sessionPublicKey", type: "bytes" },
    { name: "chainId", type: "uint256" },
    { name: "allowedActionsHash", type: "bytes32" },
    { name: "maxAmountUsdc", type: "uint256" },
    { name: "expiresAtUnix", type: "uint256" },
  ],
} as const;

export const SPONSOR_INTENT_TYPES = {
  SponsorIntent: [
    { name: "requestId", type: "string" },
    { name: "sessionId", type: "string" },
    { name: "requestNonce", type: "string" },
    { name: "chainId", type: "uint256" },
    { name: "action", type: "string" },
    { name: "amountUsdc", type: "uint256" },
    { name: "slippageBps", type: "uint256" },
    { name: "sender", type: "address" },
  ],
} as const;

export const SESSION_REVOKE_TYPES = {
  SessionRevoke: [
    { name: "sessionId", type: "string" },
    { name: "owner", type: "address" },
    { name: "chainId", type: "uint256" },
  ],
} as const;

export const createSessionEip712Domain = (chainId: number) => ({
  name: SESSION_EIP712_NAME,
  version: SESSION_EIP712_VERSION,
  chainId,
});

export const normalizeActions = (actions: string[]): string[] => {
  return [...actions].map((x) => x.trim()).filter(Boolean).sort();
};

export const serializeAllowedActions = (actions: string[]): string => normalizeActions(actions).join(",");
