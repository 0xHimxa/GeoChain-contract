import { Contract, Interface, JsonRpcProvider, type Log } from "ethers";
import type { MarketEvent } from "./types";

export type SupportedChainId = 84532 | 421614;

export type DeployedAddresses = {
  marketFactory: string;
  router: string;
  collateral: string;
};

export const CHAIN_CONFIG: Record<SupportedChainId, { name: string; rpcUrl: string; addresses: DeployedAddresses }> = {
  84532: {
    name: "Base Sepolia",
    rpcUrl: "https://sepolia.base.org",
    addresses: {
      router: "0x075B30906d48f922A643bBa218724a84931DC1BA",
      marketFactory: "0xa11dE127E008aC5489D28C4130792981DB047654",
      collateral: "0xf3B85Ebc920e036c8Dc04179d35ac526a08EDAa8",
    },
  },
  421614: {
    name: "Arbitrum Sepolia",
    rpcUrl: "https://sepolia-rollup.arbitrum.io/rpc",
    addresses: {
      router: "0xAD51b51Ea9347CBaB070311f07d2C7659d8D8c78",
      marketFactory: "0x50045D38580b7f0c326E371c45f9ca22a0768fa7",
      collateral: "0x8eaE35b8DC918BE54b2fAA57c9Bb0D4E13B9C9CB",
    },
  },
};

export const MARKET_FACTORY_ABI = [
  "function getActiveEventList() view returns (address[])",
  "event MarketCreated(uint256 indexed marketId, address indexed market, uint256 indexed initialLiquidity)",
] as const;

export const MARKET_ABI = [
  "function s_question() view returns (string)",
  "function closeTime() view returns (uint256)",
  "function resolutionTime() view returns (uint256)",
  "function state() view returns (uint8)",
  "function resolution() view returns (uint8)",
  "function marketId() view returns (uint256)",
  "function getYesPriceProbability() view returns (uint256)",
  "function getNoPriceProbability() view returns (uint256)",
  "function yesToken() view returns (address)",
  "function noToken() view returns (address)",
] as const;

export const ROUTER_ABI = [
  "function collateralCredits(address) view returns (uint256)",
  "function tokenCredits(address,address) view returns (uint256)",
  "function depositCollateral(uint256 amount)",
  "function depositFor(address beneficiary, uint256 amount)",
] as const;

export const ERC20_ABI = [
  "function approve(address spender, uint256 amount) returns (bool)",
  "function allowance(address owner, address spender) view returns (uint256)",
  "function balanceOf(address owner) view returns (uint256)",
  "function transfer(address to, uint256 amount) returns (bool)",
] as const;

const createdEventIface = new Interface(MARKET_FACTORY_ABI);
export const MARKET_CREATED_TOPIC = createdEventIface.getEvent("MarketCreated")?.topicHash || "";

export const providerForChain = (chainId: SupportedChainId): JsonRpcProvider => {
  const cfg = CHAIN_CONFIG[chainId];
  return new JsonRpcProvider(cfg.rpcUrl, chainId);
};

export const decodeMarketCreatedLog = (log: Log): { market: string; marketId: bigint } | null => {
  try {
    const parsed = createdEventIface.parseLog(log);
    if (!parsed || parsed.name !== "MarketCreated") return null;
    return {
      market: String(parsed.args.market),
      marketId: BigInt(parsed.args.marketId),
    };
  } catch {
    return null;
  }
};

export const marketStateLabel = (raw: bigint): "open" | "closed" | "resolved" => {
  if (raw === 0n) return "open";
  if (raw === 1n) return "closed";
  return "resolved";
};

export const resolutionLabel = (raw: bigint): "yes" | "no" | null => {
  if (raw === 1n) return "yes";
  if (raw === 2n) return "no";
  return null;
};

export const loadMarketSnapshot = async (chainId: SupportedChainId, marketAddress: string): Promise<MarketEvent> => {
  const provider = providerForChain(chainId);
  const market = new Contract(marketAddress, MARKET_ABI, provider);

  const [
    question,
    closeTime,
    resolutionTime,
    state,
    resolution,
    marketId,
    yesPrice,
    noPrice,
    yesToken,
    noToken,
  ] = await Promise.all([
    market.s_question(),
    market.closeTime(),
    market.resolutionTime(),
    market.state(),
    market.resolution(),
    market.marketId(),
    market.getYesPriceProbability().catch(() => 500_000n),
    market.getNoPriceProbability().catch(() => 500_000n),
    market.yesToken(),
    market.noToken(),
  ]);

  const closeTimeUnix = Number(closeTime);
  const resolutionTimeUnix = Number(resolutionTime);
  const now = Math.floor(Date.now() / 1000);
  const rawState = marketStateLabel(BigInt(state));
  const resolutionOutcome = resolutionLabel(BigInt(resolution));
  let effectiveState: "open" | "closed" | "resolved" = rawState;
  if (resolutionOutcome) {
    effectiveState = "resolved";
  } else if (now >= closeTimeUnix && rawState === "open") {
    effectiveState = "closed";
  }

  return {
    id: `${chainId}:${String(marketId)}`,
    chainId,
    marketAddress,
    marketId: BigInt(marketId).toString(),
    question: String(question),
    closeTimeUnix,
    resolutionTimeUnix,
    state: effectiveState,
    resolutionOutcome,
    yesPriceBps: Math.floor((Number(yesPrice) / 1_000_000) * 10_000),
    noPriceBps: Math.floor((Number(noPrice) / 1_000_000) * 10_000),
    yesToken: String(yesToken),
    noToken: String(noToken),
    createdAtUnix: Math.floor(Date.now() / 1000),
  };
};
