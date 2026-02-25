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
  parseAbi,
  decodeFunctionResult,
  encodeAbiParameters,
  encodeFunctionData,
  parseAbiParameters,
} from "viem";
import { MarketFactoryAbi } from "../contractsAbi/marketFactory";

import {

  sender,
  type Config,
 
} from "../Constant-variable/config";

const USDC_DECIMALS = 1_000_000n;
const BRIDGE_BALANCE_THRESHOLD = 50_000n * USDC_DECIMALS;
const BRIDGE_TOP_UP_AMOUNT = 140_000n * USDC_DECIMALS;
const FACTORY_BALANCE_THRESHOLD = 210_000n * USDC_DECIMALS;
const FACTORY_TOP_UP_AMOUNT = 400_000n * USDC_DECIMALS;
const MINT_COLLATERAL_ACTION = "mintCollateralTo";

const marketFactoryBridgeGetterAbi = parseAbi(["function predictionMarketBridge() view returns (address)"]);
const erc20BalanceOfAbi = parseAbi(["function balanceOf(address account) view returns (uint256)"]);


/**
 * Monitors bridge and factory collateral balances on each configured chain and submits
 * mint top-up reports when balances fall below configured thresholds.
 */
export const marketFactoryBalanceTopUp = (runtime: Runtime<Config>): string => {
  const marketFactoryCollateralCallData = encodeFunctionData({
    abi: MarketFactoryAbi,
    functionName: "getMarketFactoryCollateralBalance",
  });
  const marketFactoryBridgeCallData = encodeFunctionData({
    abi: marketFactoryBridgeGetterAbi,
    functionName: "predictionMarketBridge",
  });
  const marketFactoryCollateralTokenCallData = encodeFunctionData({
    abi: MarketFactoryAbi,
    functionName: "collateral",
  });

  const chainSummaries = runtime.config.evms.map((evmConfig) => {
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
          data: marketFactoryCollateralCallData,
        }),
      })
      .result();

    const factoryBalance = decodeFunctionResult({
      abi: MarketFactoryAbi,
      functionName: "getMarketFactoryCollateralBalance",
      data: bytesToHex(callResult.data),
    }) as bigint;

    const bridgeResult = evmClient
      .callContract(runtime, {
        call: encodeCallMsg({
          from: sender,
          to: evmConfig.marketFactoryAddress as `0x${string}`,
          data: marketFactoryBridgeCallData,
        }),
      })
      .result();

    const bridgeAddress = decodeFunctionResult({
      abi: marketFactoryBridgeGetterAbi,
      functionName: "predictionMarketBridge",
      data: bytesToHex(bridgeResult.data),
    }) as `0x${string}`;

    if (bridgeAddress === "0x0000000000000000000000000000000000000000") {
      runtime.log(`[${evmConfig.chainName}] predictionMarketBridge is not configured`);
      return `${evmConfig.chainName}: bridge-not-configured factory=${factoryBalance.toString()}`;
    }

    const collateralResult = evmClient
      .callContract(runtime, {
        call: encodeCallMsg({
          from: sender,
          to: evmConfig.marketFactoryAddress as `0x${string}`,
          data: marketFactoryCollateralTokenCallData,
        }),
      })
      .result();

    const collateralAddress = decodeFunctionResult({
      abi: MarketFactoryAbi,
      functionName: "collateral",
      data: bytesToHex(collateralResult.data),
    }) as `0x${string}`;

    const bridgeCollateralBalanceCallData = encodeFunctionData({
      abi: erc20BalanceOfAbi,
      functionName: "balanceOf",
      args: [bridgeAddress],
    });

    const bridgeBalanceResult = evmClient
      .callContract(runtime, {
        call: encodeCallMsg({
          from: sender,
          to: collateralAddress,
          data: bridgeCollateralBalanceCallData,
        }),
      })
      .result();

    const bridgeCollateralBalance = decodeFunctionResult({
      abi: erc20BalanceOfAbi,
      functionName: "balanceOf",
      data: bytesToHex(bridgeBalanceResult.data),
    }) as bigint;

    const maybeTopUpByReport = (receiver: `0x${string}`, amount: bigint, reason: string): string => {
      const mintPayload = encodeAbiParameters(parseAbiParameters("address receiver, uint256 amount"), [receiver, amount]);
      const encodedReport = encodeAbiParameters(parseAbiParameters("string actionType, bytes payload"), [
        MINT_COLLATERAL_ACTION,
        mintPayload,
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
        runtime.log(
          `[${evmConfig.chainName}] ${MINT_COLLATERAL_ACTION} REVERTED: ${writeReportResult.errorMessage || "unknown"}`
        );
        throw new Error(`${MINT_COLLATERAL_ACTION} failed on ${evmConfig.chainName}: ${writeReportResult.errorMessage}`);
      }

      const txHash = bytesToHex(writeReportResult.txHash || new Uint8Array(32));
      runtime.log(`Write report transaction succeeded: ${txHash}`);
      runtime.log(`View transaction at https://sepolia.etherscan.io/tx/${txHash}`);
      return `${reason}=topped-up to=${receiver} amount=${amount.toString()} tx=${txHash}`;
    };

    const actions: string[] = [];

    if (bridgeCollateralBalance < BRIDGE_BALANCE_THRESHOLD) {
      actions.push(maybeTopUpByReport(bridgeAddress, BRIDGE_TOP_UP_AMOUNT, "bridge"));
    }

    if (factoryBalance < FACTORY_BALANCE_THRESHOLD) {
      actions.push(
        maybeTopUpByReport(
          evmConfig.marketFactoryAddress as `0x${string}`,
          FACTORY_TOP_UP_AMOUNT,
          "factory"
        )
      );
    }

    if (actions.length > 0) {
      return `${evmConfig.chainName}: ${actions.join(", ")}`;
    }

    return `${evmConfig.chainName}: healthy bridgeBalance=${bridgeCollateralBalance.toString()} factory=${factoryBalance.toString()}`;
  });

  return chainSummaries.join(" | ");
};

