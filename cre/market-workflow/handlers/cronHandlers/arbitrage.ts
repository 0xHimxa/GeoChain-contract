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
import {
  ARB_MAX_SPEND_COLLATERAL,
  ARB_MIN_DEVIATION_IMPROVEMENT_BPS,

  sender,
  type Config,

} from "../../Constant-variable/config";
















/**
 * Scans every active market, checks deviation status, and detects markets in unsafe
 * pricing bands. For eligible markets, it submits `priceCorrection` reports with
 * configured spending and improvement limits to push prices back toward canonical values.
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

    let activeMarketList: `0x${string}`[] = [];
    try {
      const activeMarketResult = evmClient
        .callContract(runtime, {
          call: encodeCallMsg({
            from: sender,
            to: evmConfig.marketFactoryAddress as `0x${string}`,
            data: activeMarketCallData,
          }),
        })
        .result();

      activeMarketList = decodeFunctionResult({
        abi: MarketFactoryAbi,
        functionName: "getActiveEventList",
        data: bytesToHex(activeMarketResult.data),
      }) as `0x${string}`[];
    } catch (error) {
      runtime.log(
        `[${evmConfig.chainName}] failed to load active markets from ${evmConfig.marketFactoryAddress}: ${
          error instanceof Error ? error.message : String(error)
        }`
      );
      continue;
    }

    for (const marketAddress of activeMarketList) {
      scannedMarkets += 1;

      let band: number;
      let allowYesForNo: boolean;
      let allowNoForYes: boolean;
      try {
        const deviationResult = evmClient
          .callContract(runtime, {
            call: encodeCallMsg({
              from: sender,
              to: marketAddress,
              data: getDeviationStatusCallData,
            }),
          })
          .result();

        const decoded = decodeFunctionResult({
          abi: PredictionMarketAbi,
          functionName: "getDeviationStatus",
          data: bytesToHex(deviationResult.data),
        }) as readonly [number, bigint, bigint, bigint, boolean, boolean];
        [band, , , , allowYesForNo, allowNoForYes] = decoded;
      } catch (error) {
        runtime.log(
          `[${evmConfig.chainName}] skipping ${marketAddress}: getDeviationStatus reverted (${
            error instanceof Error ? error.message : String(error)
          })`
        );
        continue;
      }

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
