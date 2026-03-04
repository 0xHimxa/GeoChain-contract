import { Contract, Interface, JsonRpcProvider, type Log } from "ethers";
import type { MarketEvent, MarketState, OutcomeLabel } from "./types";

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
      router: "0x7D60126CEE3D751913EAA299Ab3FFef480A39ee4",
      marketFactory: "0xf2992507E9589307Ea5f02225C5439Ee451d13EC",
      collateral: "0x88e624252aF6Dc6AA5ca76f00458aa8Df39E2657 ",
    },
  },
  421614: {
    name: "Arbitrum Sepolia",
    rpcUrl: "https://sepolia-rollup.arbitrum.io/rpc",
    addresses: {
      router: "0xdB5e75aC76136A3e9FFCbFf1DED42f3943aE1701",
      marketFactory: "0xbC44067d3bbDC4cb4231fD91b2Fe3Bf7027E7c77",
      collateral: "0x9e96ad0e4044356918477A36b58bFcb98eAD4566",
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
  "function proposedResolution() view returns (uint8)",
  "function disputeDeadline() view returns (uint256)",
  "function resolutionDisputed() view returns (bool)",
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
  "function setAgentPermission(address agent, uint32 actionMask, uint128 maxAmountPerAction, uint64 expiresAt)",
  "function revokeAgentPermission(address agent)",
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

export const marketStateLabel = (raw: bigint): MarketState => {
  if (raw === 0n) return "open";
  if (raw === 1n) return "closed";
  if (raw === 2n) return "review";
  return "resolved";
};

export const resolutionLabel = (raw: bigint): OutcomeLabel => {
  if (raw === 1n) return "yes";
  if (raw === 2n) return "no";
  if (raw === 3n) return "inconclusive";
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
    proposedResolution,
    disputeDeadline,
    resolutionDisputed,
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
    market.proposedResolution().catch(() => 0n),
    market.disputeDeadline().catch(() => 0n),
    market.resolutionDisputed().catch(() => false),
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
  let effectiveState: MarketState = rawState;
  if (resolutionOutcome && resolutionOutcome !== "inconclusive") {
    effectiveState = "resolved";
  } else if (rawState === "review") {
    effectiveState = "review";
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
    proposedResolutionOutcome: resolutionLabel(BigInt(proposedResolution)),
    disputeDeadlineUnix: Number(disputeDeadline || 0),
    resolutionDisputed: Boolean(resolutionDisputed),
    yesPriceBps: Math.floor((Number(yesPrice) / 1_000_000) * 10_000),
    noPriceBps: Math.floor((Number(noPrice) / 1_000_000) * 10_000),
    yesToken: String(yesToken),
    noToken: String(noToken),
    createdAtUnix: Math.floor(Date.now() / 1000),
  };
};
