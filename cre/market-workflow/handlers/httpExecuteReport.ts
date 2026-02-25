import {
  EVMClient,
  TxStatus,
  bytesToHex,
  getNetwork,
  prepareReportRequest,
  type HTTPPayload,
  type Runtime,
} from "@chainlink/cre-sdk";
import { encodeAbiParameters, parseAbiParameters } from "viem";
import { type Config } from "../Constant-variable/config";

type ExecuteRequest = {
  requestId?: string;
  approvalId?: string;
  chainId?: number;
  receiver?: string;
  actionType?: string;
  payloadHex?: `0x${string}`;
  gasLimit?: string;
};

type ExecuteResponse = {
  submitted: boolean;
  requestId: string;
  reason?: string;
  txHash?: string;
  chainName?: string;
  receiver?: string;
  explorerUrl?: string;
};

const HEX_ADDRESS_REGEX = /^0x[a-fA-F0-9]{40}$/;
const HEX_BYTES_REGEX = /^0x([a-fA-F0-9]{2})*$/;

const toChainId = (chainName: string): number | null => {
  if (chainName.includes("arbitrum")) return 421614;
  if (chainName.includes("base")) return 84532;
  if (chainName === "ethereum-testnet-sepolia") return 11155111;
  return null;
};

const txExplorer = (chainName: string, txHash: string): string => {
  if (chainName.includes("arbitrum")) return `https://sepolia.arbiscan.io/tx/${txHash}`;
  if (chainName.includes("base")) return `https://sepolia.basescan.org/tx/${txHash}`;
  return `https://sepolia.etherscan.io/tx/${txHash}`;
};

const parseRequest = (payload: HTTPPayload): ExecuteRequest => {
  const raw = new TextDecoder().decode(payload.input);
  if (!raw.trim()) throw new Error("empty payload");
  return JSON.parse(raw) as ExecuteRequest;
};

export const executeReportHttpHandler = (runtime: Runtime<Config>, payload: HTTPPayload): string => {
  const requestIdFallback = `req_${runtime.now().toISOString()}`;
  const execPolicy = runtime.config.executePolicy;

  if (!execPolicy?.enabled) {
    return JSON.stringify({
      submitted: false,
      requestId: requestIdFallback,
      reason: "execute policy disabled",
    } satisfies ExecuteResponse);
  }

  let req: ExecuteRequest;
  try {
    req = parseRequest(payload);
  } catch (error) {
    return JSON.stringify({
      submitted: false,
      requestId: requestIdFallback,
      reason: error instanceof Error ? error.message : "invalid payload",
    } satisfies ExecuteResponse);
  }

  const requestId = req.requestId || requestIdFallback;
  if (!req.approvalId || !req.approvalId.startsWith("cre_approval_")) {
    return JSON.stringify({
      submitted: false,
      requestId,
      reason: "invalid or missing approvalId",
    } satisfies ExecuteResponse);
  }

  if (typeof req.chainId !== "number") {
    return JSON.stringify({
      submitted: false,
      requestId,
      reason: "missing chainId",
    } satisfies ExecuteResponse);
  }

  if (!req.actionType || !execPolicy.allowedActionTypes.includes(req.actionType)) {
    return JSON.stringify({
      submitted: false,
      requestId,
      reason: "actionType not allowed",
    } satisfies ExecuteResponse);
  }

  if (!req.payloadHex || !HEX_BYTES_REGEX.test(req.payloadHex)) {
    return JSON.stringify({
      submitted: false,
      requestId,
      reason: "invalid payloadHex",
    } satisfies ExecuteResponse);
  }

  const evmConfig = runtime.config.evms.find((evm) => toChainId(evm.chainName) === req.chainId);
  if (!evmConfig) {
    return JSON.stringify({
      submitted: false,
      requestId,
      reason: "chainId not mapped in config.evms",
    } satisfies ExecuteResponse);
  }

  const receiver = (req.receiver || evmConfig.marketFactoryAddress) as `0x${string}`;
  if (!HEX_ADDRESS_REGEX.test(receiver)) {
    return JSON.stringify({
      submitted: false,
      requestId,
      reason: "invalid receiver",
    } satisfies ExecuteResponse);
  }

  const network = getNetwork({
    chainFamily: "evm",
    chainSelectorName: evmConfig.chainName,
    isTestnet: true,
  });
  if (!network) {
    return JSON.stringify({
      submitted: false,
      requestId,
      reason: `unknown chain name: ${evmConfig.chainName}`,
    } satisfies ExecuteResponse);
  }

  const evmClient = new EVMClient(network.chainSelector.selector);
  const encodedReport = encodeAbiParameters(parseAbiParameters("string actionType, bytes payload"), [
    req.actionType,
    req.payloadHex,
  ]);

  const report = runtime.report({
    ...prepareReportRequest(encodedReport),
  }).result();

  const writeReportResult = evmClient
    .writeReport(runtime, {
      receiver,
      report,
      gasConfig: {
        gasLimit: req.gasLimit || "10000000",
      },
    })
    .result();

  if (writeReportResult.txStatus === TxStatus.REVERTED) {
    return JSON.stringify({
      submitted: false,
      requestId,
      reason: writeReportResult.errorMessage || "writeReport reverted",
      chainName: evmConfig.chainName,
      receiver,
    } satisfies ExecuteResponse);
  }

  const txHash = bytesToHex(writeReportResult.txHash || new Uint8Array(32));
  const explorerUrl = txExplorer(evmConfig.chainName, txHash);
  runtime.log(`[HTTP_EXECUTE] requestId=${requestId} actionType=${req.actionType} txHash=${txHash}`);

  return JSON.stringify({
    submitted: true,
    requestId,
    txHash,
    chainName: evmConfig.chainName,
    receiver,
    explorerUrl,
  } satisfies ExecuteResponse);
};
