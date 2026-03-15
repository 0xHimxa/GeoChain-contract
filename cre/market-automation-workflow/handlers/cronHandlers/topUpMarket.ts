import {
  encodeCallMsg,
  bytesToHex,
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
import { MarketFactoryAbi } from "../../contractsAbi/marketFactory";

import {

  sender,
  type Config,
 
} from "../../Constant-variable/config";
import { createEvmClient } from "../utils/evmUtils";

const USDC_DECIMALS = 1_000_000n;
const BRIDGE_BALANCE_THRESHOLD = 500_000n * USDC_DECIMALS;
const BRIDGE_TOP_UP_AMOUNT = 540_000n * USDC_DECIMALS;
const ROUTER_BALANCE_THRESHOLD = 50_000n * USDC_DECIMALS;
const ROUTER_TOP_UP_AMOUNT = 3000_000n * USDC_DECIMALS;
const FACTORY_BALANCE_THRESHOLD = 310_000n * USDC_DECIMALS;
const FACTORY_TOP_UP_AMOUNT = 600_000n * USDC_DECIMALS;
const MINT_COLLATERAL_ACTION = "mintCollateralTo";

const marketFactoryBridgeGetterAbi = parseAbi(["function predictionMarketBridge() view returns (address)"]);
const marketFactoryRouterGetterAbi = parseAbi(["function predictionMarketRouter() view returns (address)"]);
const erc20BalanceOfAbi = parseAbi(["function balanceOf(address account) view returns (uint256)"]);


/**
 * Reads collateral balances for each market factory, its bridge, and its router, then
 * submits `mintCollateralTo` reports when any balance drops below configured thresholds.
 * This keeps operational liquidity available for factory actions and cross-chain routing.
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
  const marketFactoryRouterCallData = encodeFunctionData({
    abi: marketFactoryRouterGetterAbi,
    functionName: "predictionMarketRouter",
  });
  const marketFactoryCollateralTokenCallData = encodeFunctionData({
    abi: MarketFactoryAbi,
    functionName: "collateral",
  });

  const chainSummaries = runtime.config.evms.map((evmConfig) => {
    const evmClient = createEvmClient(runtime, evmConfig);

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

    const routerResult = evmClient
      .callContract(runtime, {
        call: encodeCallMsg({
          from: sender,
          to: evmConfig.marketFactoryAddress as `0x${string}`,
          data: marketFactoryRouterCallData,
        }),
      })
      .result();

    const routerAddress = decodeFunctionResult({
      abi: marketFactoryRouterGetterAbi,
      functionName: "predictionMarketRouter",
      data: bytesToHex(routerResult.data),
    }) as `0x${string}`;

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

    let bridgeCollateralBalance = 0n;
    if (bridgeAddress !== "0x0000000000000000000000000000000000000000") {
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

      bridgeCollateralBalance = decodeFunctionResult({
        abi: erc20BalanceOfAbi,
        functionName: "balanceOf",
        data: bytesToHex(bridgeBalanceResult.data),
      }) as bigint;
    } else {
      runtime.log(`[${evmConfig.chainName}] predictionMarketBridge is not configured`);
    }

    let routerCollateralBalance = 0n;
    if (routerAddress !== "0x0000000000000000000000000000000000000000") {
      const routerCollateralBalanceCallData = encodeFunctionData({
        abi: erc20BalanceOfAbi,
        functionName: "balanceOf",
        args: [routerAddress],
      });

      const routerBalanceResult = evmClient
        .callContract(runtime, {
          call: encodeCallMsg({
            from: sender,
            to: collateralAddress,
            data: routerCollateralBalanceCallData,
          }),
        })
        .result();

      routerCollateralBalance = decodeFunctionResult({
        abi: erc20BalanceOfAbi,
        functionName: "balanceOf",
        data: bytesToHex(routerBalanceResult.data),
      }) as bigint;
    } else {
      runtime.log(`[${evmConfig.chainName}] predictionMarketRouter is not configured`);
    }

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

    if (bridgeAddress !== "0x0000000000000000000000000000000000000000" && bridgeCollateralBalance < BRIDGE_BALANCE_THRESHOLD) {
      actions.push(maybeTopUpByReport(bridgeAddress, BRIDGE_TOP_UP_AMOUNT, "bridge"));
    }

    if (routerAddress !== "0x0000000000000000000000000000000000000000" && routerCollateralBalance < ROUTER_BALANCE_THRESHOLD) {
      actions.push(maybeTopUpByReport(routerAddress, ROUTER_TOP_UP_AMOUNT, "router"));
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

    const bridgeStatus = bridgeAddress === "0x0000000000000000000000000000000000000000"
      ? "bridge=not-configured"
      : `bridgeBalance=${bridgeCollateralBalance.toString()}`;

    const routerStatus = routerAddress === "0x0000000000000000000000000000000000000000"
      ? "router=not-configured"
      : `routerBalance=${routerCollateralBalance.toString()}`;

    return `${evmConfig.chainName}: healthy ${bridgeStatus} ${routerStatus} factory=${factoryBalance.toString()}`;
  });

  return chainSummaries.join(" | ");
};
