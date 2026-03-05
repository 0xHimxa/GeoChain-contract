import {
  EVMClient,
  encodeCallMsg,
  bytesToHex,
  getNetwork,
  prepareReportRequest,
  TxStatus,
  type Runtime,
} from "@chainlink/cre-sdk";
import {
  decodeFunctionResult,
  encodeAbiParameters,
  encodeFunctionData,
  parseAbiParameters,
} from "viem";
import { MarketFactoryAbi } from "../../contractsAbi/marketFactory";
import { PredictionMarketAbi } from "../../contractsAbi/predictionMarket";
import { isHubFactoryConfig } from "../utils/isHub";
import { processPendingWithdrawalsHandler } from "./marketWithdrawal";
import {
  sender,
  type Config,
} from "../../Constant-variable/config";
import { askGemeniResolve } from "../../gemini/resolveEvent";

const marketSnapshotAbi = [
  {
    type: "function",
    name: "getDisputeResolutionSnapshot",
    inputs: [],
    outputs: [
      { name: "marketState", type: "uint8" },
      { name: "currentProposedResolution", type: "uint8" },
      { name: "isResolutionDisputed", type: "bool" },
      { name: "currentDisputeDeadline", type: "uint256" },
      { name: "currentResolutionTime", type: "uint256" },
      { name: "question", type: "string" },
      { name: "disputedUniqueOutcomes", type: "uint8[]" },
    ],
    stateMutability: "view",
  },
] as const;

type DisputeResolutionSnapshot = readonly [
  number,
  number,
  boolean,
  bigint,
  bigint,
  string,
  number[]
];

const toOutcomeCode = (result: string): number => {
  const normalized = (result || "").trim().toUpperCase();
  if (normalized === "YES") return 1;
  if (normalized === "NO") return 2;
  return 3;
};



/**
 * Loads active markets from the configured hub factory, checks each market for
 * resolution eligibility, and sends `ResolveMarket` reports for ready markets.
 * After attempting resolutions, it triggers withdrawal queue processing across factories.
 */
export const resoloveEvent = (runtime: Runtime<Config>): string => {
  const marketFactoryCallData = encodeFunctionData({
    abi: MarketFactoryAbi,
    functionName: "getActiveEventList",
  });

  const predictionCallData = encodeFunctionData({
    abi: PredictionMarketAbi,
    functionName: "checkResolutionTime",
  });

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
  const hubFlag = isHubFactoryConfig(runtime, sepoConfig, evmClient);
  if (!hubFlag) {
    return `Configured resolver chain is not hub: ${sepoConfig.chainName}`;
  }

  const callResult = evmClient
    .callContract(runtime, {
      call: encodeCallMsg({
        from: sender,
        to: sepoConfig.marketFactoryAddress as `0x${string}`,
        data: marketFactoryCallData,
      }),
    })
    .result();

  const activeEventList = decodeFunctionResult({
    abi: MarketFactoryAbi,
    functionName: "getActiveEventList",
    data: bytesToHex(callResult.data),
  }) as `0x${string}`[];
runtime.log(`Active Events: ${JSON.stringify( activeEventList)}`);
  if (activeEventList.length === 0) {
    return "No Active Events";
  }

  for (const eventAddress of activeEventList) {
    let readyForResolve = false;
    try {
      const predictionStatusResult = evmClient
        .callContract(runtime, {
          call: encodeCallMsg({
            from: sender,
            to: eventAddress,
            data: predictionCallData,
          }),
        })
        .result();

      readyForResolve = decodeFunctionResult({
        abi: PredictionMarketAbi,
        functionName: "checkResolutionTime",
        data: bytesToHex(predictionStatusResult.data),
      }) as boolean;
    } catch (error) {
      runtime.log(`Skipping ${eventAddress}: checkResolutionTime failed (${error instanceof Error ? error.message : String(error)})`);
      continue;
    }

    if (readyForResolve) {
      runtime.log(`Resolving eligible market: ${eventAddress}`);

      const snapshotCallData = encodeFunctionData({
        abi: marketSnapshotAbi,
        functionName: "getDisputeResolutionSnapshot",
      });
      const snapshotResult = evmClient
        .callContract(runtime, {
          call: encodeCallMsg({
            from: sender,
            to: eventAddress,
            data: snapshotCallData,
          }),
        })
        .result();
      const snapshot = decodeFunctionResult({
        abi: marketSnapshotAbi,
        functionName: "getDisputeResolutionSnapshot",
        data: bytesToHex(snapshotResult.data),
      }) as DisputeResolutionSnapshot;
      const question = snapshot[5] || "";
      const resolutionTime = snapshot[4].toString();

      const geminiResolve = askGemeniResolve(runtime, {
        question,
        resolutionTime,
      });
      const outcome = toOutcomeCode(geminiResolve.result);
      const proofUrl = geminiResolve.source_url || `https://www.google.com/search?q=${question}`;

      const resolvePayload = encodeAbiParameters(parseAbiParameters("uint8 outcome, string proofUrl"), [
        outcome,
        proofUrl,
      ]);
      const encodedReport = encodeAbiParameters(parseAbiParameters("string actionType, bytes payload"), [
        "ResolveMarket",
        resolvePayload,
      ]);

      const reportResponse = runtime.report({
        ...prepareReportRequest(encodedReport),
      }).result();

      const writeReportResult = evmClient
        .writeReport(runtime, {
          receiver: eventAddress,
          report: reportResponse,
          gasConfig: {
            gasLimit: "10000000",
          },
        })
        .result();

      runtime.log("Waiting for write report response");

      if (writeReportResult.txStatus === TxStatus.REVERTED) {
        runtime.log(
          `[${sepoConfig.chainName}] ResolveMarket REVERTED for ${eventAddress}: ${writeReportResult.errorMessage || "unknown"}`
        );
        throw new Error(`ResolveMarket failed on ${sepoConfig.chainName}: ${writeReportResult.errorMessage}`);
      }

      const txHash = bytesToHex(writeReportResult.txHash || new Uint8Array(32));
      runtime.log(
        `ResolveMarket tx succeeded for ${eventAddress}: ${txHash}; result=${geminiResolve.result}; confidence=${geminiResolve.confidence}; proofUrl=${proofUrl}`
      );
      runtime.log(`View transaction at https://sepolia.arbiscan.io/tx/${txHash}`);
    }

    runtime.log(`ready to be resolve ${readyForResolve}`);
  }

  const queueSummary = processPendingWithdrawalsHandler(runtime);
  return `active=${activeEventList.length}; ${queueSummary}`;
};
