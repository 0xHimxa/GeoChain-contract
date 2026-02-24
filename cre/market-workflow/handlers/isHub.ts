import {
  EVMClient,
  encodeCallMsg,
  bytesToHex,
  
  type Runtime,
} from "@chainlink/cre-sdk";
import {

  decodeFunctionResult,
 
  encodeFunctionData,

} from "viem";
import { MarketFactoryAbi } from "../contractsAbi/marketFactory";
import {

  sender,
  type Config,
  type EvmConfig,

} from "../Constant-variable/config";



/**
 * Reads the target factory's `isHubFactory` flag on-chain.
 * Used by other handlers to ensure hub-only actions are executed on the correct chain.
 */
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
