import { encodeAbiParameters, parseAbiParameters } from "viem";

export type AgentAction =
  | "mintCompleteSets"
  | "redeemCompleteSets"
  | "swapYesForNo"
  | "swapNoForYes"
  | "addLiquidity"
  | "removeLiquidity"
  | "redeem"
  | "disputeProposedResolution";

export const AGENT_ACTION_TO_ROUTER_ACTION_TYPE: Record<AgentAction, string> = {
  mintCompleteSets: "routerAgentMintCompleteSets",
  redeemCompleteSets: "routerAgentRedeemCompleteSets",
  swapYesForNo: "routerAgentSwapYesForNo",
  swapNoForYes: "routerAgentSwapNoForYes",
  addLiquidity: "routerAgentAddLiquidity",
  removeLiquidity: "routerAgentRemoveLiquidity",
  redeem: "routerAgentRedeem",
  disputeProposedResolution: "routerAgentDisputeProposedResolution",
};

type ActionPayloadInput = {
  user: `0x${string}`;
  agent: `0x${string}`;
  market: `0x${string}`;
  amountUsdc?: string;
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

const toUint = (value?: string): bigint => {
  if (!value) return 0n;
  if (!/^\d+$/.test(value)) throw new Error("amount fields must be unsigned integer strings");
  return BigInt(value);
};

export const buildAgentPayloadHex = (action: AgentAction, input: ActionPayloadInput): `0x${string}` => {
  if (action === "mintCompleteSets" || action === "redeemCompleteSets" || action === "redeem") {
    return encodeAbiParameters(parseAbiParameters("address user,address agent,address market,uint256 amount"), [
      input.user,
      input.agent,
      input.market,
      toUint(input.amountUsdc),
    ]);
  }

  if (action === "swapYesForNo") {
    return encodeAbiParameters(parseAbiParameters("address user,address agent,address market,uint256 yesIn,uint256 minNoOut"), [
      input.user,
      input.agent,
      input.market,
      toUint(input.yesIn ?? input.amountUsdc),
      toUint(input.minNoOut),
    ]);
  }

  if (action === "swapNoForYes") {
    return encodeAbiParameters(parseAbiParameters("address user,address agent,address market,uint256 noIn,uint256 minYesOut"), [
      input.user,
      input.agent,
      input.market,
      toUint(input.noIn ?? input.amountUsdc),
      toUint(input.minYesOut),
    ]);
  }

  if (action === "addLiquidity") {
    return encodeAbiParameters(
      parseAbiParameters("address user,address agent,address market,uint256 yesAmount,uint256 noAmount,uint256 minShares"),
      [
        input.user,
        input.agent,
        input.market,
        toUint(input.yesAmount),
        toUint(input.noAmount),
        toUint(input.minShares),
      ]
    );
  }

  if (action === "removeLiquidity") {
    return encodeAbiParameters(
      parseAbiParameters("address user,address agent,address market,uint256 shares,uint256 minYesOut,uint256 minNoOut"),
      [
        input.user,
        input.agent,
        input.market,
        toUint(input.shares),
        toUint(input.minYesOut),
        toUint(input.minNoOut),
      ]
    );
  }

  return encodeAbiParameters(parseAbiParameters("address user,address agent,address market,uint8 proposedOutcome"), [
    input.user,
    input.agent,
    input.market,
    Number(input.proposedOutcome || 0),
  ]);
};
