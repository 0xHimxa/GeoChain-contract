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
      router: "0x29D4d09493e507E6b31ffD18f28AC647EE56916a",
      marketFactory: "0x82dB8e8d6CC0E1fc7C305905140822e0EB57557f",
      collateral: "0x8423148D55274a2430B1093F3352c460C0c14C4C",
    },
  },
  421614: {
    name: "Arbitrum Sepolia",
    rpcUrl: "https://sepolia-rollup.arbitrum.io/rpc",
    addresses: {
      router: "0x4924D16b5ffadF307e7370c6961d8F3FB084Fc23",
      marketFactory: "0x093a5F31A845FCadAbd55AB3915A6300B4cbCB47",
      collateral: "0x4114D2B355f6dcEFbEd61A316e0516496b43c055",
    },
  },
};

export const MARKET_FACTORY_ABI = [
  "function getActiveEventList() view returns (address[])",
  "function marketCount() view returns (uint256)",
  "function marketById(uint256) view returns (address)",
  "event MarketCreated(uint256 indexed marketId, address indexed market, uint256 indexed initialLiquidity)",
] as const;

export const MARKET_ABI = [
  "function s_question() view returns (string)",
  "function s_Proof_Url() view returns (string)",
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
    questionProofUrl,
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
    market.s_Proof_Url().catch(() => ""),
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
    questionProofUrl: String(questionProofUrl || ""),
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
