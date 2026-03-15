import { EVMClient, getNetwork, type Runtime } from "@chainlink/cre-sdk";
import { type Config } from "../../Constant-variable/config";

export const createEvmClient = (
  runtime: Runtime<Config>,
  evmConfig: Config["evms"][number]
): EVMClient => {
  const network = getNetwork({
    chainFamily: "evm",
    chainSelectorName: evmConfig.chainName,
    isTestnet: true,
  });

  if (!network) {
    throw new Error(`Unknown chain name: ${evmConfig.chainName}`);
  }

  return new EVMClient(network.chainSelector.selector);
};

export const txExplorer = (chainName: string, txHash: string): string => {
  if (chainName.includes("arbitrum")) {
    return `https://sepolia.arbiscan.io/tx/${txHash}`;
  }
  return `https://sepolia.basescan.org//tx/${txHash}`;
};
