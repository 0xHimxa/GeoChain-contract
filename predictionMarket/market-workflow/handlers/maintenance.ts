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
  PROCESS_PENDING_WITHDRAWALS_ACTION,
  sender,
  type Config,
  type EvmConfig,
  WITHDRAW_BATCH_SIZE,
} from "../workflow/config";

export const isHubFactoryConfig = (
  runtime: Runtime<Config>,
  evmConfig: EvmConfig,
  evmClient: EVMClient
): boolean => {
  const isHubCallData = encodeFunctionData({
    abi: MarketFactoryAbi,
    functionName: "isHubFactory",
  });

  const isHubResult = evmClient
    .callContract(runtime, {
      call: encodeCallMsg({
        from: sender,
        to: evmConfig.marketFactoryAddress as `0x${string}`,
        data: isHubCallData,
      }),
    })
    .result();

  return decodeFunctionResult({
    abi: MarketFactoryAbi,
    functionName: "isHubFactory",
    data: bytesToHex(isHubResult.data),
  }) as boolean;
};

export const processPendingWithdrawalsHandler = (runtime: Runtime<Config>): string => {
  let attemptedWrites = 0;
  let successfulWrites = 0;

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
    const payload = encodeAbiParameters(parseAbiParameters("uint256 maxItems"), [WITHDRAW_BATCH_SIZE]);
    const encodedReport = encodeAbiParameters(parseAbiParameters("string actionType, bytes payload"), [
      PROCESS_PENDING_WITHDRAWALS_ACTION,
      payload,
    ]);
    const reportResponse = runtime.report({
      ...prepareReportRequest(encodedReport),
    }).result();

    attemptedWrites += 1;
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
        `[${evmConfig.chainName}] ${PROCESS_PENDING_WITHDRAWALS_ACTION} REVERTED: ${writeReportResult.errorMessage || "unknown"}`
      );
      continue;
    }

    const txHash = bytesToHex(writeReportResult.txHash || new Uint8Array(32));
    runtime.log(`[${evmConfig.chainName}] ${PROCESS_PENDING_WITHDRAWALS_ACTION} tx: ${txHash}`);
    successfulWrites += 1;
  }

  return `pending-withdrawal batch writes=${successfulWrites}/${attemptedWrites}, batchSize=${WITHDRAW_BATCH_SIZE.toString()}`;
};

// this trigger checks factory collateral and tops up when below threshold
export const marketFactoryBalanceTopUp = (runtime: Runtime<Config>): string => {
  const marketFactoryCallData = encodeFunctionData({
    abi: MarketFactoryAbi,
    functionName: "getMarketFactoryCollateralBalance",
  });

  const balances = runtime.config.evms.map((evmConfig) => {
    const network = getNetwork({
      chainFamily: "evm",
      chainSelectorName: evmConfig.chainName,
      isTestnet: true,
    });

    if (!network) {
      throw new Error(`Unknown chain name: ${evmConfig.chainName}`);
    }

    const evmClient = new EVMClient(network.chainSelector.selector);

    const callResult = evmClient
      .callContract(runtime, {
        call: encodeCallMsg({
          from: sender,
          to: evmConfig.marketFactoryAddress as `0x${string}`,
          data: marketFactoryCallData,
        }),
      })
      .result();

    const contractBalance = decodeFunctionResult({
      abi: MarketFactoryAbi,
      functionName: "getMarketFactoryCollateralBalance",
      data: bytesToHex(callResult.data),
    }) as bigint;

    if (contractBalance <= 100000000000n) {
      const encodedReport = encodeAbiParameters(parseAbiParameters("string actionType, bytes payload"), [
        "addLiquidityToFactory",
        "0x",
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

      runtime.log("Waiting for write report response");

      if (writeReportResult.txStatus === TxStatus.REVERTED) {
        runtime.log(`[${evmConfig.chainName}] addLiquidity REVERTED: ${writeReportResult.errorMessage || "unknown"}`);
        throw new Error(`addLiquidity failed on ${evmConfig.chainName}: ${writeReportResult.errorMessage}`);
      }

      const txHash = bytesToHex(writeReportResult.txHash || new Uint8Array(32));
      runtime.log(`Write report transaction succeeded: ${txHash}`);
      runtime.log(`View transaction at https://sepolia.etherscan.io/tx/${txHash}`);
      return contractBalance;
    }

    return contractBalance;
  });

  runtime.log("returned data: arbturm one chain");
  return `Hello world! ${balances[0]} ${balances[1]}`;
};

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
      runtime.log(`View transaction at https://sepolia.etherscan.io/tx/${txHash}`);
    }

    runtime.log(`ready to be resolve ${readyForResolve}`);
  });

  const queueSummary = processPendingWithdrawalsHandler(runtime);
  return `active=${activeEventList.length}; ${queueSummary}`;
};

export const syncCanonicalPrice = (runtime: Runtime<Config>): string => {
  if (runtime.config.evms.length < 2) {
    return "Need at least one hub and one spoke EVM config";
  }

  const hubConfig = runtime.config.evms[0];
  const spokeConfigs = runtime.config.evms.slice(1);
  const hubNetwork = getNetwork({
    chainFamily: "evm",
    chainSelectorName: hubConfig.chainName,
    isTestnet: true,
  });

  if (!hubNetwork) {
    throw new Error(`Unknown chain name: ${hubConfig.chainName}`);
  }

  const hubClient = new EVMClient(hubNetwork.chainSelector.selector);
  const spokeClients = spokeConfigs.map((spokeConfig) => {
    const spokeNetwork = getNetwork({
      chainFamily: "evm",
      chainSelectorName: spokeConfig.chainName,
      isTestnet: true,
    });
    if (!spokeNetwork) {
      throw new Error(`Unknown chain name: ${spokeConfig.chainName}`);
    }
    return {
      config: spokeConfig,
      client: new EVMClient(spokeNetwork.chainSelector.selector),
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

    const yesPriceCallData = encodeFunctionData({
      abi: PredictionMarketAbi,
      functionName: "getYesPriceProbability",
    });
    const noPriceCallData = encodeFunctionData({
      abi: PredictionMarketAbi,
      functionName: "getNoPriceProbability",
    });

    const yesPriceResult = hubClient
      .callContract(runtime, {
        call: encodeCallMsg({
          from: sender,
          to: marketAddress,
          data: yesPriceCallData,
        }),
      })
      .result();

    const noPriceResult = hubClient
      .callContract(runtime, {
        call: encodeCallMsg({
          from: sender,
          to: marketAddress,
          data: noPriceCallData,
        }),
      })
      .result();

    const yesPriceE6 = decodeFunctionResult({
      abi: PredictionMarketAbi,
      functionName: "getYesPriceProbability",
      data: bytesToHex(yesPriceResult.data),
    }) as bigint;

    const noPriceE6 = decodeFunctionResult({
      abi: PredictionMarketAbi,
      functionName: "getNoPriceProbability",
      data: bytesToHex(noPriceResult.data),
    }) as bigint;

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
  }

  return `Synced ${activeMarketList.length} markets from hub to ${spokeClients.length} spokes (successful writes: ${successfulWrites}/${attemptedWrites})`;
};




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
