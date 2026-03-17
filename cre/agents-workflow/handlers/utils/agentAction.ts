import { encodeAbiParameters, parseAbiParameters } from "viem";

export type AgentAction =
  | "lmsrBuy"
  | "lmsrSell"
  | "mintCompleteSets"
  | "redeemCompleteSets"
  | "redeem"
  | "disputeProposedResolution";

export const AGENT_ACTION_TO_ROUTER_ACTION_TYPE: Record<AgentAction, string> = {
  lmsrBuy: "routerAgentBuy",
  lmsrSell: "routerAgentSell",
  mintCompleteSets: "routerAgentMintCompleteSets",
  redeemCompleteSets: "routerAgentRedeemCompleteSets",
  redeem: "routerAgentRedeem",
  disputeProposedResolution: "routerAgentDisputeProposedResolution",
};

type ActionPayloadInput = {
  user: `0x${string}`;
  agent: `0x${string}`;
  market: `0x${string}`;
  amountUsdc?: string;
  outcomeIndex?: string | number;
  sharesDelta?: string | number;
  costDelta?: string | number;
  refundDelta?: string | number;
  newYesPriceE6?: string | number;
  newNoPriceE6?: string | number;
  nonce?: string | number;
  proposedOutcome?: number;
};

const toUint = (value?: string | number): bigint => {
  if (!value) return 0n;
  const text = String(value);
  if (!/^\d+$/.test(text)) throw new Error("amount fields must be unsigned integer strings");
  return BigInt(text);
};

const toUint8 = (value?: string | number): bigint => {
  if (!value) return 0n;
  const text = String(value);
  if (!/^\d+$/.test(text)) throw new Error("amount fields must be unsigned integer strings");
  const parsed = BigInt(text);
  if (parsed > 255n) throw new Error("outcomeIndex must be <= 255");
  return parsed;
};

const toUint64 = (value?: string | number): bigint => {
  if (!value) return 0n;
  const text = String(value);
  if (!/^\d+$/.test(text)) throw new Error("amount fields must be unsigned integer strings");
  const parsed = BigInt(text);
  if (parsed > 18446744073709551615n) throw new Error("nonce must be <= 2^64-1");
  return parsed;
};

export const buildAgentPayloadHex = (action: AgentAction, input: ActionPayloadInput): `0x${string}` => {
  if (action === "lmsrBuy") {
    return encodeAbiParameters(
      parseAbiParameters(
        "address user,address agent,address market,uint8 outcomeIndex,uint256 sharesDelta,uint256 costDelta,uint256 newYesPriceE6,uint256 newNoPriceE6,uint64 nonce"
      ),
      [
        input.user,
        input.agent,
        input.market,
        toUint8(input.outcomeIndex),
        toUint(input.sharesDelta),
        toUint(input.costDelta),
        toUint(input.newYesPriceE6),
        toUint(input.newNoPriceE6),
        toUint64(input.nonce),
      ]
    );
  }

  if (action === "lmsrSell") {
    return encodeAbiParameters(
      parseAbiParameters(
        "address user,address agent,address market,uint8 outcomeIndex,uint256 sharesDelta,uint256 refundDelta,uint256 newYesPriceE6,uint256 newNoPriceE6,uint64 nonce"
      ),
      [
        input.user,
        input.agent,
        input.market,
        toUint8(input.outcomeIndex),
        toUint(input.sharesDelta),
        toUint(input.refundDelta),
        toUint(input.newYesPriceE6),
        toUint(input.newNoPriceE6),
        toUint64(input.nonce),
      ]
    );
  }

  if (action === "mintCompleteSets" || action === "redeemCompleteSets" || action === "redeem") {
    return encodeAbiParameters(parseAbiParameters("address user,address agent,address market,uint256 amount"), [
      input.user,
      input.agent,
      input.market,
      toUint(input.amountUsdc),
    ]);
  }

  return encodeAbiParameters(parseAbiParameters("address user,address agent,address market,uint8 proposedOutcome"), [
    input.user,
    input.agent,
    input.market,
    Number(input.proposedOutcome || 0),
  ]);
};
