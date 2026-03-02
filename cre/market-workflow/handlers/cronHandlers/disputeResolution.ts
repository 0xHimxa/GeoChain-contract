import {
  EVMClient,
  TxStatus,
  bytesToHex,
  encodeCallMsg,
  getNetwork,
  prepareReportRequest,
  type Runtime,
} from "@chainlink/cre-sdk";
import {
  decodeFunctionResult,
  encodeAbiParameters,
  encodeFunctionData,
  parseAbiParameters,
} from "viem";
import { askGeminiAdjudicateDispute } from "../../gemini/adjudicateDispute";
import { type Config, sender } from "../../Constant-variable/config";
import { isHubFactoryConfig } from "../utils/isHub";

const ACTION_FINALIZE = "FinalizeResolutionAfterDisputeWindow";
const ACTION_ADJUDICATE = "AdjudicateDisputedResolution";

const factoryAbi = [
  {
    type: "function",
    name: "getActiveEventList",
    inputs: [],
    outputs: [{ name: "", type: "address[]" }],
    stateMutability: "view",
  },
] as const;

const marketAbi = [
  {
    type: "function",
    name: "state",
    inputs: [],
    outputs: [{ name: "", type: "uint8" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "proposedResolution",
    inputs: [],
    outputs: [{ name: "", type: "uint8" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "resolutionDisputed",
    inputs: [],
    outputs: [{ name: "", type: "bool" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "disputeDeadline",
    inputs: [],
    outputs: [{ name: "", type: "uint256" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "resolutionTime",
    inputs: [],
    outputs: [{ name: "", type: "uint256" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "s_question",
    inputs: [],
    outputs: [{ name: "", type: "string" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "getDisputeSubmissionsCount",
    inputs: [],
    outputs: [{ name: "", type: "uint256" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "disputeSubmissions",
    inputs: [{ name: "", type: "uint256" }],
    outputs: [
      { name: "disputer", type: "address" },
      { name: "proposedOutcome", type: "uint8" },
      { name: "submittedAt", type: "uint256" },
    ],
    stateMutability: "view",
  },
] as const;

const toOutcomeLabel = (outcome: number): string => {
  if (outcome === 1) return "YES";
  if (outcome === 2) return "NO";
  if (outcome === 3) return "INCONCLUSIVE";
  return "UNSET";
};

const toOutcomeCode = (value: string): number => {
  const normalized = value.trim().toUpperCase();
  if (normalized === "YES") return 1;
  if (normalized === "NO") return 2;
  if (normalized === "INCONCLUSIVE") return 3;
  return 3;
};

const callView = <T>(
  runtime: Runtime<Config>,
  evmClient: EVMClient,
  market: `0x${string}`,
  functionName: (typeof marketAbi)[number]["name"],
  args: readonly unknown[] = []
): T => {
  const data = encodeFunctionData({
    abi: marketAbi,
    functionName,
    args: args as any,
  });

  const result = evmClient
    .callContract(runtime, {
      call: encodeCallMsg({
        from: sender,
        to: market,
        data,
      }),
    })
    .result();

  return decodeFunctionResult({
    abi: marketAbi,
    functionName,
    data: bytesToHex(result.data),
  }) as T;
};

const sendMarketReport = (
  runtime: Runtime<Config>,
  evmClient: EVMClient,
  market: `0x${string}`,
  actionType: string,
  payload: `0x${string}`
): string => {
  const encodedReport = encodeAbiParameters(parseAbiParameters("string actionType, bytes payload"), [
    actionType,
    payload,
  ]);

  const reportResponse = runtime.report({
    ...prepareReportRequest(encodedReport),
  }).result();

  const writeReportResult = evmClient
    .writeReport(runtime, {
      receiver: market,
      report: reportResponse,
      gasConfig: {
        gasLimit: "10000000",
      },
    })
    .result();

  if (writeReportResult.txStatus === TxStatus.REVERTED) {
    throw new Error(`${actionType} reverted for ${market}: ${writeReportResult.errorMessage || "unknown"}`);
  }

  return bytesToHex(writeReportResult.txHash || new Uint8Array(32));
};

export const adjudicateExpiredDisputeWindows = (runtime: Runtime<Config>): string => {
  const sepoConfig = runtime.config.evms[0];
  const network = getNetwork({
    chainFamily: "evm",
    chainSelectorName: sepoConfig.chainName,
    isTestnet: true,
  });

  if (!network) {
    throw new Error(`Unknown chain name: ${sepoConfig.chainName}`);
  }

  const evmClient = new EVMClient(network.chainSelector.selector);
  const isHub = isHubFactoryConfig(runtime, sepoConfig, evmClient);
  if (!isHub) {
    return `Configured dispute resolver chain is not hub: ${sepoConfig.chainName}`;
  }

  const activeEventListData = encodeFunctionData({
    abi: factoryAbi,
    functionName: "getActiveEventList",
  });

  const activeResult = evmClient
    .callContract(runtime, {
      call: encodeCallMsg({
        from: sender,
        to: sepoConfig.marketFactoryAddress as `0x${string}`,
        data: activeEventListData,
      }),
    })
    .result();

  const activeMarkets = decodeFunctionResult({
    abi: factoryAbi,
    functionName: "getActiveEventList",
    data: bytesToHex(activeResult.data),
  }) as `0x${string}`[];

  if (activeMarkets.length === 0) {
    return "No Active Events";
  }

  let finalizedCount = 0;
  let adjudicatedCount = 0;
  const now = BigInt(Math.floor(Date.now() / 1000));

  for (const market of activeMarkets) {
    try {
      const state = callView<number>(runtime, evmClient, market, "state");
      const proposedResolution = callView<number>(runtime, evmClient, market, "proposedResolution");
      const disputeDeadline = callView<bigint>(runtime, evmClient, market, "disputeDeadline");

      if (state !== 2 || proposedResolution === 0) {
        continue;
      }
      if (now <= disputeDeadline) {
        continue;
      }

      const resolutionDisputed = callView<boolean>(runtime, evmClient, market, "resolutionDisputed");
      if (!resolutionDisputed) {
        const txHash = sendMarketReport(runtime, evmClient, market, ACTION_FINALIZE, "0x");
        finalizedCount++;
        runtime.log(`Finalized undisputed market ${market}: ${txHash}`);
        continue;
      }

      const disputesCount = callView<bigint>(runtime, evmClient, market, "getDisputeSubmissionsCount");
      if (disputesCount === 0n) {
        runtime.log(`Skipping disputed market ${market}: no dispute submissions found`);
        continue;
      }

      const outcomes = new Set<string>();
      for (let i = 0n; i < disputesCount; i++) {
        const row = callView<readonly [string, number, bigint]>(runtime, evmClient, market, "disputeSubmissions", [i]);
        outcomes.add(toOutcomeLabel(Number(row[1])));
      }

      const question = callView<string>(runtime, evmClient, market, "s_question");
      const resolutionTime = callView<bigint>(runtime, evmClient, market, "resolutionTime");
      const gemini = askGeminiAdjudicateDispute(runtime, {
        question,
        resolutionTime: resolutionTime.toString(),
        originalProposedOutcome: toOutcomeLabel(proposedResolution),
        disputedOutcomes: [...outcomes].filter((label) => label !== "UNSET"),
      });

      const adjudicatedOutcome = toOutcomeCode(gemini.result || "INCONCLUSIVE");
      const proofUrl = adjudicatedOutcome === 3 ? "" : (gemini.source_url || "");
      const adjudicatePayload = encodeAbiParameters(
        parseAbiParameters("uint8 adjudicatedOutcome, string proofUrl"),
        [adjudicatedOutcome, proofUrl]
      );

      const txHash = sendMarketReport(runtime, evmClient, market, ACTION_ADJUDICATE, adjudicatePayload);
      adjudicatedCount++;
      runtime.log(`Adjudicated disputed market ${market}: ${txHash}; outcome=${adjudicatedOutcome}`);
    } catch (error) {
      runtime.log(`Skipping dispute automation for ${market}: ${error instanceof Error ? error.message : String(error)}`);
    }
  }

  return `markets=${activeMarkets.length}; finalized=${finalizedCount}; adjudicated=${adjudicatedCount}`;
};
