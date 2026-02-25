import {
  createPublicClient,
  http,
  type Address,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { arbitrumSepolia, baseSepolia, sepolia } from "viem/chains";
import { createSmartAccountClient, entryPoint07Address } from "permissionless";
import { toSimpleSmartAccount } from "permissionless/accounts";
import { createPimlicoClient } from "permissionless/clients/pimlico";

type ChainName = "baseSepolia" | "arbitrumSepolia" | "sepolia";

const chainByName = {
  baseSepolia,
  arbitrumSepolia,
  sepolia,
} as const;

const getRequired = (name: string): string => {
  const value = process.env[name];
  if (!value) throw new Error(`Missing env var: ${name}`);
  return value;
};

const chainName = (process.env.AA_CHAIN || "baseSepolia") as ChainName;
const chain = chainByName[chainName];
if (!chain) {
  throw new Error(`Unsupported AA_CHAIN: ${chainName}`);
}

const rpcUrl = getRequired("AA_RPC_URL");
const bundlerUrl = getRequired("AA_BUNDLER_URL");
const paymasterUrl = getRequired("AA_PAYMASTER_URL");
const ownerPk = getRequired("AA_OWNER_PRIVATE_KEY") as `0x${string}`;
const configuredEntryPoint = (process.env.AA_ENTRYPOINT || entryPoint07Address) as Address;

const owner = privateKeyToAccount(ownerPk);
const publicClient = createPublicClient({
  chain,
  transport: http(rpcUrl),
});

const pimlicoClient = createPimlicoClient({
  transport: http(paymasterUrl),
  entryPoint: {
    address: configuredEntryPoint,
    version: "0.7",
  },
});

const account = await toSimpleSmartAccount({
  client: publicClient,
  owner,
  entryPoint: {
    address: configuredEntryPoint,
    version: "0.7",
  },
});

const smartAccountClient = createSmartAccountClient({
  account,
  chain,
  bundlerTransport: http(bundlerUrl),
  paymaster: pimlicoClient,
  // Use paymaster-provided gas prices so UserOps are accepted by bundler/paymaster.
  userOperation: {
    estimateFeesPerGas: async () => {
      const gasPrice = await pimlicoClient.getUserOperationGasPrice();
      return gasPrice.fast;
    },
  },
});

const to = ((process.env.AA_TEST_TO || account.address) as Address);

console.log("Owner EOA:", owner.address);
console.log("Smart account:", account.address);
console.log("Destination:", to);
console.log("Chain:", chain.name);
console.log("EntryPoint:", configuredEntryPoint);

// Minimal sponsored transaction: zero-value call with empty data.
const userOpHash = await smartAccountClient.sendTransaction({
  to,
  value: 0n,
  data: "0x",
});

console.log("UserOp hash:", userOpHash);

const receipt = await smartAccountClient.waitForUserOperationReceipt({
  hash: userOpHash,
});

console.log("Included tx hash:", receipt.receipt.transactionHash);
console.log("Success:", receipt.success);
