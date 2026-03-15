import {
  encodeCallMsg,
  bytesToHex,
  prepareReportRequest,
  TxStatus,
  type Runtime,
} from "@chainlink/cre-sdk";
import { decodeFunctionResult, encodeAbiParameters, encodeFunctionData, parseAbiParameters } from "viem";
import { MarketFactoryAbi } from "../../contractsAbi/marketFactory";
import { PredictionMarketAbi } from "../../contractsAbi/predictionMarket";
import { sender, type Config } from "../../Constant-variable/config";
import { createEvmClient } from "../utils/evmUtils";

const MARKET_STATE_OPEN = 0;

/**
 * Reads live yes/no probabilities from hub-chain markets and publishes those values to
 * each spoke factory using `syncSpokeCanonicalPrice` reports. Every report includes a
 * short expiry so spokes reject stale price updates.
 */
export const syncCanonicalPrice = (runtime: Runtime<Config>): string => {
  if (runtime.config.evms.length < 2) {
    return "Need at least one hub and one spoke EVM config";
  }

  const hubConfig = runtime.config.evms[0];
  const spokeConfigs = runtime.config.evms.slice(1);
  const hubClient = createEvmClient(runtime, hubConfig);
  const spokeClients = spokeConfigs.map((spokeConfig) => {
    return {
      config: spokeConfig,
      client: createEvmClient(runtime, spokeConfig),
    };
  });

  const activeMarketCallData = encodeFunctionData({
    abi: MarketFactoryAbi,
    functionName: "getActiveEventList",
  });

  const activeMarketResult = hubClient
    .callContract(runtime, {
      call: encodeCallMsg({
        from: sender,
        to: hubConfig.marketFactoryAddress as `0x${string}`,
        data: activeMarketCallData,
      }),
    })
    .result();

  const activeMarketList = decodeFunctionResult({
    abi: MarketFactoryAbi,
    functionName: "getActiveEventList",
    data: bytesToHex(activeMarketResult.data),
  }) as `0x${string}`[];

  if (activeMarketList.length === 0) {
    return "No active markets to sync";
  }

  let attemptedWrites = 0;
  let successfulWrites = 0;
  let syncedMarkets = 0;

  for (const marketAddress of activeMarketList) {
    const marketIdCallData = encodeFunctionData({
      abi: MarketFactoryAbi,
      functionName: "marketIdByAddress",
      args: [marketAddress],
    });

    const marketIdCallResult = hubClient
      .callContract(runtime, {
        call: encodeCallMsg({
          from: sender,
          to: hubConfig.marketFactoryAddress as `0x${string}`,
          data: marketIdCallData,
        }),
      })
      .result();

    const marketId = decodeFunctionResult({
      abi: MarketFactoryAbi,
      functionName: "marketIdByAddress",
      data: bytesToHex(marketIdCallResult.data),
    }) as bigint;

    if (marketId === 0n) {
      runtime.log(`Skipping ${marketAddress}: marketIdByAddress returned 0`);
      continue;
    }

    const syncSnapshotCallData = encodeFunctionData({
      abi: PredictionMarketAbi,
      functionName: "getSyncSnapshot",
    });

    const syncSnapshotResult = hubClient
      .callContract(runtime, {
        call: encodeCallMsg({
          from: sender,
          to: marketAddress,
          data: syncSnapshotCallData,
        }),
      })
      .result();

    const [marketState, yesPriceE6, noPriceE6] = decodeFunctionResult({
      abi: PredictionMarketAbi,
      functionName: "getSyncSnapshot",
      data: bytesToHex(syncSnapshotResult.data),
    }) as [bigint, bigint, bigint];

    if (Number(marketState) !== MARKET_STATE_OPEN) {
      runtime.log(`Skipping ${marketAddress}: market is no longer open (state=${marketState})`);
      continue;
    }
    

    const validUntil = BigInt(Math.floor(Date.now() / 1000) + 15 * 60);
    const pricePayload = encodeAbiParameters(
      parseAbiParameters("uint256 marketId, uint256 yesPriceE6, uint256 noPriceE6, uint256 validUntil"),
      [marketId, yesPriceE6, noPriceE6, validUntil]
    );
    const encodedReport = encodeAbiParameters(parseAbiParameters("string actionType, bytes payload"), [
      "syncSpokeCanonicalPrice",
      pricePayload,
    ]);
    const reportResponse = runtime.report({
      ...prepareReportRequest(encodedReport),
    }).result();

    for (const spoke of spokeClients) {
      attemptedWrites += 1;
      const writeReportResult = spoke.client
        .writeReport(runtime, {
          receiver: spoke.config.marketFactoryAddress,
          report: reportResponse,
          gasConfig: {
            gasLimit: "10000000",
          },
        })
        .result();

      if (writeReportResult.txStatus === TxStatus.REVERTED) {
        runtime.log(
          `[${spoke.config.chainName}] syncSpokeCanonicalPrice REVERTED for marketId=${marketId}: ${writeReportResult.errorMessage || "unknown"}`
        );
        continue;
      }

      const txHash = bytesToHex(writeReportResult.txHash || new Uint8Array(32));
      runtime.log(`[${spoke.config.chainName}] syncSpokeCanonicalPrice tx for marketId=${marketId}: ${txHash}`);
      successfulWrites += 1;
    }

    syncedMarkets += 1;
  }

  return `Synced ${syncedMarkets}/${activeMarketList.length} eligible markets from hub to ${spokeClients.length} spokes (successful writes: ${successfulWrites}/${attemptedWrites})`;
};
