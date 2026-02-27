import {
  EVMClient,
  bytesToHex,
  getNetwork,
  prepareReportRequest,
  type EVMLog,
  type Runtime,
} from "@chainlink/cre-sdk";
import {
  decodeAbiParameters,
  encodeAbiParameters,
  encodePacked,
  keccak256,
  parseAbiParameters,
} from "viem";
import { type Config, type EvmConfig } from "../Constant-variable/config";

const HEX_ADDRESS_REGEX = /^0x[a-fA-F0-9]{40}$/;
const DECIMAL_REGEX = /^\d+$/;
const ETH_RECEIVED_EVENT_SIG = keccak256(encodePacked(["string"], ["EthReceived(address,uint256)"]));
const ACTION_TYPE = "routerCreditFromEth";
const DEFAULT_MAX_AMOUNT_USDC = 10_000n * 1_000_000n;

const toChainId = (chainName: string): number | null => {
  if (chainName.includes("arbitrum")) return 421614;
  if (chainName.includes("base")) return 84532;
  if (chainName === "ethereum-testnet-sepolia") return 11155111;
  return null;
};

const senderFromTopic = (topicHex: string): `0x${string}` => {
  if (!/^0x[a-fA-F0-9]{64}$/.test(topicHex)) {
    throw new Error("invalid sender topic");
  }
  return `0x${topicHex.slice(26)}` as `0x${string}`;
};

const decodeAmountWei = (dataHex: string): bigint => {
  const [amountWei] = decodeAbiParameters(parseAbiParameters("uint256"), dataHex as `0x${string}`);
  return amountWei;
};

const weiToUsdcE6 = (amountWei: bigint, ethToUsdcRateE6: bigint): bigint => {
  return (amountWei * ethToUsdcRateE6) / 1_000_000_000_000_000_000n;
};

const resolveEvmConfigByRouter = (evms: EvmConfig[], routerAddress: string): EvmConfig | null => {
  const normalized = routerAddress.toLowerCase();
  for (const evm of evms) {
    if ((evm.routerReceiverAddress || "").toLowerCase() === normalized) {
      return evm;
    }
  }
  return null;
};

export const ethCreditFromLogsHandler = (runtime: Runtime<Config>, log: EVMLog): string => {
  const policy = runtime.config.ethCreditPolicy;
  if (!policy?.enabled) {
    return "eth credit policy disabled";
  }

  if (log.removed) {
    return "skipped removed log";
  }

  const eventSig = bytesToHex(log.eventSig);
  if (eventSig.toLowerCase() !== ETH_RECEIVED_EVENT_SIG.toLowerCase()) {
    return "skipped unrelated event";
  }

  const routerAddress = bytesToHex(log.address);
  const evmConfig = resolveEvmConfigByRouter(runtime.config.evms, routerAddress);
  if (!evmConfig) {
    return `router not mapped in config: ${routerAddress}`;
  }

  const chainId = toChainId(evmConfig.chainName);
  if (!chainId || !policy.supportedChainIds.includes(chainId)) {
    return `chain not supported for eth credit: ${evmConfig.chainName}`;
  }

  const rateRaw = evmConfig.ethToUsdcRateE6 || "";
  if (!DECIMAL_REGEX.test(rateRaw)) {
    return `invalid ethToUsdcRateE6 for chain ${evmConfig.chainName}`;
  }
  const rateE6 = BigInt(rateRaw);
  if (rateE6 <= 0n) {
    return `ethToUsdcRateE6 must be > 0 for chain ${evmConfig.chainName}`;
  }

  if (log.topics.length < 2) {
    return "missing sender topic";
  }
  const sender = senderFromTopic(bytesToHex(log.topics[1]));
  if (!HEX_ADDRESS_REGEX.test(sender)) {
    return "decoded sender is invalid";
  }

  const amountWei = decodeAmountWei(bytesToHex(log.data));
  if (amountWei <= 0n) {
    return "amountWei is zero";
  }

  const amountUsdcE6 = weiToUsdcE6(amountWei, rateE6);
  if (amountUsdcE6 <= 0n) {
    return "converted amountUsdcE6 is zero";
  }

  const maxAmountUsdc = DECIMAL_REGEX.test(policy.maxAmountUsdc) ? BigInt(policy.maxAmountUsdc) : DEFAULT_MAX_AMOUNT_USDC;
  if (amountUsdcE6 > maxAmountUsdc) {
    return `converted amount exceeds maxAmountUsdc: ${amountUsdcE6.toString()}`;
  }

  const network = getNetwork({
    chainFamily: "evm",
    chainSelectorName: evmConfig.chainName,
    isTestnet: true,
  });
  if (!network) {
    throw new Error(`unknown chain name: ${evmConfig.chainName}`);
  }

  const txHashHex = bytesToHex(log.txHash);
  const depositId = keccak256(
    encodePacked(["bytes32", "uint32"], [txHashHex as `0x${string}`, log.index])
  );
  const reportPayload = encodeAbiParameters(parseAbiParameters("address user, uint256 amount, bytes32 depositId"), [
    sender,
    amountUsdcE6,
    depositId,
  ]);

  const reportData = encodeAbiParameters(parseAbiParameters("string actionType, bytes payload"), [
    ACTION_TYPE,
    reportPayload,
  ]);

  const report = runtime.report({
    ...prepareReportRequest(reportData),
  }).result();

  const evmClient = new EVMClient(network.chainSelector.selector);
  evmClient
    .writeReport(runtime, {
      receiver: routerAddress as `0x${string}`,
      report,
      gasConfig: {
        gasLimit: evmConfig.reportGasLimit,
      },
    })
    .result();

  runtime.log(
    `[ETH_CREDIT] sender=${sender} amountWei=${amountWei.toString()} amountUsdcE6=${amountUsdcE6.toString()} txHash=${txHashHex} logIndex=${log.index}`
  );
  return `processed eth deposit tx=${txHashHex}`;
};
