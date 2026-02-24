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
import {
  ARB_MAX_SPEND_COLLATERAL,
  ARB_MIN_DEVIATION_IMPROVEMENT_BPS,

  sender,
  type Config,

} from "../Constant-variable/config";
















/**
 * Scans all active markets for unsafe deviation and triggers corrective arbitrage
 * via market-factory report actions when policy conditions are satisfied.
 */
export const arbitrateUnsafeMarketHandler = (runtime: Runtime<Config>): string => {
  if (runtime.config.evms.length === 0) {
    return "No EVM config found";
  }

  const activeMarketCallData = encodeFunctionData({
    abi: MarketFactoryAbi,
    functionName: "getActiveEventList",
  });
  const marketIdByAddressCallData = (marketAddress: `0x${string}`) =>
    encodeFunctionData({
      abi: MarketFactoryAbi,
      functionName: "marketIdByAddress",
      args: [marketAddress],
    });
  const getDeviationStatusCallData = encodeFunctionData({
    abi: PredictionMarketAbi,
    functionName: "getDeviationStatus",
  });

  let scannedMarkets = 0;
  let unsafeMarkets = 0;
  let correctedMarkets = 0;

  for (const evmConfig of runtime.config.evms) {
    const network = getNetwork({
      chainFamily: "evm",
      chainSelectorName: evmConfig.chainName,
      isTestnet: true,
    });

    if (!network) {
      throw new Error(`Unknown chain name: ${evmConfig.chainName}`);
    }

    const evmClient = new EVMClient(network.chainSelector.selector);

    const activeMarketResult = evmClient
      .callContract(runtime, {
        call: encodeCallMsg({
          from: sender,
          to: evmConfig.marketFactoryAddress as `0x${string}`,
          data: activeMarketCallData,
        }),
      })
      .result();

    const activeMarketList = decodeFunctionResult({
      abi: MarketFactoryAbi,
      functionName: "getActiveEventList",
      data: bytesToHex(activeMarketResult.data),
    }) as `0x${string}`[];

    for (const marketAddress of activeMarketList) {
      scannedMarkets += 1;

      const deviationResult = evmClient
        .callContract(runtime, {
          call: encodeCallMsg({
            from: sender,
            to: marketAddress,
            data: getDeviationStatusCallData,
          }),
        })
        .result();

      const [band, , , , allowYesForNo, allowNoForYes] = decodeFunctionResult({
        abi: PredictionMarketAbi,
        functionName: "getDeviationStatus",
        data: bytesToHex(deviationResult.data),
      }) as readonly [number, bigint, bigint, bigint, boolean, boolean];

      // DeviationBand.Unsafe = 2
      if (Number(band) !== 2) {
        continue;
      }
      if (!allowYesForNo && !allowNoForYes) {
        runtime.log(`[${evmConfig.chainName}] skipping ${marketAddress}: unsafe band without valid direction`);
        continue;
      }

      unsafeMarkets += 1;

      const marketIdCallResult = evmClient
        .callContract(runtime, {
          call: encodeCallMsg({
            from: sender,
            to: evmConfig.marketFactoryAddress as `0x${string}`,
            data: marketIdByAddressCallData(marketAddress),
          }),
        })
        .result();

      const marketId = decodeFunctionResult({
        abi: MarketFactoryAbi,
        functionName: "marketIdByAddress",
        data: bytesToHex(marketIdCallResult.data),
      }) as bigint;

      if (marketId === 0n) {
        runtime.log(`[${evmConfig.chainName}] skipping ${marketAddress}: marketIdByAddress returned 0`);
        continue;
      }

      const correctionPayload = encodeAbiParameters(
        parseAbiParameters("uint256 marketId, uint256 maxSpendCollateral, uint256 minDeviationImprovementBps"),
        [marketId, ARB_MAX_SPEND_COLLATERAL, ARB_MIN_DEVIATION_IMPROVEMENT_BPS]
      );
      const encodedReport = encodeAbiParameters(parseAbiParameters("string actionType, bytes payload"), [
        "priceCorrection",
        correctionPayload,
      ]);
      const reportResponse = runtime.report({
        ...prepareReportRequest(encodedReport),
      }).result();

      const writeReportResult = evmClient
        .writeReport(runtime, {
          receiver: evmConfig.marketFactoryAddress,
          report: reportResponse,
          gasConfig: {
            gasLimit: "10000000",
          },
        })
        .result();

      if (writeReportResult.txStatus === TxStatus.REVERTED) {
        runtime.log(
          `[${evmConfig.chainName}] priceCorrection REVERTED for marketId=${marketId}: ${writeReportResult.errorMessage || "unknown"}`
        );
        continue;
      }

      const txHash = bytesToHex(writeReportResult.txHash || new Uint8Array(32));
      runtime.log(`[${evmConfig.chainName}] priceCorrection tx for marketId=${marketId}: ${txHash}`);
      correctedMarkets += 1;
    }
  }

  return `Arbitrage scan complete: scanned=${scannedMarkets}, unsafe=${unsafeMarkets}, corrected=${correctedMarkets}`;
};
