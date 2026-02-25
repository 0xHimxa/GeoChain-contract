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
import { MarketFactoryAbi } from "../contractsAbi/marketFactory";
import { PredictionMarketAbi } from "../contractsAbi/predictionMarket";
import { isHubFactoryConfig } from "./isHub";
import { processPendingWithdrawalsHandler } from "./marketWithdrawal";
import {

  sender,
  type Config,
  
} from "../Constant-variable/config";



/**
 * Resolves eligible active markets on the hub chain and then processes
 * pending withdrawal batches on all configured factories.
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

  if (activeEventList.length === 0) {
    return "No Active Events";
  }

  activeEventList.forEach((eventAddress) => {
    const marketIdCallData = encodeFunctionData({
      abi: MarketFactoryAbi,
      functionName: "marketIdByAddress",
      args: [eventAddress],
    });

    const marketIdResult = evmClient
      .callContract(runtime, {
        call: encodeCallMsg({
          from: sender,
          to: sepoConfig.marketFactoryAddress as `0x${string}`,
          data: marketIdCallData,
        }),
      })
      .result();

    const marketId = decodeFunctionResult({
      abi: MarketFactoryAbi,
      functionName: "marketIdByAddress",
      data: bytesToHex(marketIdResult.data),
    }) as bigint;

    if (marketId === 0n) {
      runtime.log(`Skipping ${eventAddress}: marketIdByAddress returned 0`);
      return;
    }

    const predictionStatusResult = evmClient
      .callContract(runtime, {
        call: encodeCallMsg({
          from: sender,
          to: eventAddress,
          data: predictionCallData,
        }),
      })
      .result();

    const readyForResolve = decodeFunctionResult({
      abi: PredictionMarketAbi,
      functionName: "checkResolutionTime",
      data: bytesToHex(predictionStatusResult.data),
    }) as boolean;

    if (readyForResolve) {
      const questionCallData = encodeFunctionData({
        abi: PredictionMarketAbi,
        functionName: "s_question",
      });
      const questionResult = evmClient
        .callContract(runtime, {
          call: encodeCallMsg({
            from: sender,
            to: eventAddress,
            data: questionCallData,
          }),
        })
        .result();
      const marketQuestion = decodeFunctionResult({
        abi: PredictionMarketAbi,
        functionName: "s_question",
        data: bytesToHex(questionResult.data),
      });

      const rtCallData = encodeFunctionData({
        abi: PredictionMarketAbi,
        functionName: "resolutionTime",
      });
      const rtResult = evmClient
        .callContract(runtime, {
          call: encodeCallMsg({
            from: sender,
            to: eventAddress,
            data: rtCallData,
          }),
        })
        .result();
      const resTime = decodeFunctionResult({
        abi: PredictionMarketAbi,
        functionName: "resolutionTime",
        data: bytesToHex(rtResult.data),
      });

      runtime.log(`Market question: ${marketQuestion}, resolutionTime: ${resTime}`);

      const resolvePayload = encodeAbiParameters(parseAbiParameters("uint8 outcome, string proofUrl"), [
        1,
        "https:working",
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
      runtime.log(`ResolveMarket tx succeeded for ${eventAddress}: ${txHash}`);
      runtime.log(`View transaction at https://sepolia.arbiscan.io/tx/${txHash}`);
    }

    runtime.log(`ready to be resolve ${readyForResolve}`);
  });

  const queueSummary = processPendingWithdrawalsHandler(runtime);
  return `active=${activeEventList.length}; ${queueSummary}`;
};
