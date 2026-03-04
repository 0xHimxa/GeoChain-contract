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
import { verifyTypedData } from "viem";
import { type Config } from "../../Constant-variable/config";
import { createSessionEip712Domain, SESSION_REVOKE_TYPES } from "../utils/sessionMessage";

type RevokeRequest = {
  requestId?: string;
  sessionId?: string;
  owner?: string;
  agent?: string;
  chainId?: number;
  revokeSignature?: string;
};

type RevokeResponse = {
  revoked: boolean;
  requestId: string;
  reason?: string;
  txHash?: string;
  chainName?: string;
  receiver?: string;
  explorerUrl?: string;
};

const HEX_ADDRESS_REGEX = /^0x[a-fA-F0-9]{40}$/;
const HEX_BYTES_REGEX = /^0x([a-fA-F0-9]{2})*$/;
const ROUTER_AGENT_REVOKE_ACTION_TYPE = "routerAgentRevokePermission";

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

const decodePayloadInput = (payload: HTTPPayload): string => {
  return new TextDecoder().decode(payload.input);
};

const parseRequest = (raw: string): RevokeRequest => {
  if (!raw.trim()) throw new Error("empty payload");
  return JSON.parse(raw) as RevokeRequest;
};

const makeResponse = (requestId: string, reason: string): string => {
  return JSON.stringify({
    revoked: false,
    requestId,
    reason,
  } satisfies RevokeResponse);
};

export const revokeAgentPermissionHttpHandler = async (runtime: Runtime<Config>, payload: HTTPPayload): Promise<string> => {
  const requestIdFallback = `revoke_${runtime.now().toISOString()}`;
  const agentPolicy = runtime.config.agentPolicy;
  if (!agentPolicy?.enabled) return makeResponse(requestIdFallback, "agent policy disabled");

  let request: RevokeRequest;
  try {
    request = parseRequest(decodePayloadInput(payload));
  } catch (error) {
    return makeResponse(requestIdFallback, error instanceof Error ? error.message : "invalid payload");
  }

  const requestId = request.requestId || requestIdFallback;
  const sessionId = (request.sessionId || "").trim();
  const owner = (request.owner || "").trim();
  const agent = (request.agent || "").trim();
  const chainIdRaw = request.chainId;
  const revokeSignature = (request.revokeSignature || "").trim();

  if (!/^[a-zA-Z0-9_-]{12,100}$/.test(sessionId)) {
    return makeResponse(requestId, "invalid sessionId");
  }
  if (!HEX_ADDRESS_REGEX.test(owner)) {
    return makeResponse(requestId, "invalid owner");
  }
  if (!HEX_ADDRESS_REGEX.test(agent)) {
    return makeResponse(requestId, "invalid agent");
  }
  if (typeof chainIdRaw !== "number" || !Number.isInteger(chainIdRaw) || chainIdRaw <= 0) {
    return makeResponse(requestId, "invalid chainId");
  }
  const chainId = chainIdRaw;
  if (!agentPolicy.supportedChainIds.includes(chainId)) {
    return makeResponse(requestId, "chain is not supported for agent revoke");
  }
  if (!HEX_BYTES_REGEX.test(revokeSignature) || revokeSignature === "0x") {
    return makeResponse(requestId, "invalid revokeSignature");
  }

  const sigOk = await verifyTypedData({
    address: owner as `0x${string}`,
    domain: createSessionEip712Domain(chainId),
    types: SESSION_REVOKE_TYPES,
    primaryType: "SessionRevoke",
    message: {
      sessionId,
      owner: owner as `0x${string}`,
      agent: agent as `0x${string}`,
      chainId: BigInt(chainId),
    },
    signature: revokeSignature as `0x${string}`,
  });
  if (!sigOk) {
    return makeResponse(requestId, "invalid revoke signature");
  }

  const evmConfig = runtime.config.evms.find((evm) => toChainId(evm.chainName) === chainId);
  if (!evmConfig) {
    return makeResponse(requestId, "chainId not mapped in config.evms");
  }
  const receiver = (evmConfig.routerReceiverAddress || "").trim() as `0x${string}`;
  if (!HEX_ADDRESS_REGEX.test(receiver)) {
    return makeResponse(requestId, "invalid router receiver");
  }

  const network = getNetwork({
    chainFamily: "evm",
    chainSelectorName: evmConfig.chainName,
    isTestnet: true,
  });
  if (!network) {
    return makeResponse(requestId, `unknown chain name: ${evmConfig.chainName}`);
  }

  const evmClient = new EVMClient(network.chainSelector.selector);
  const payloadHex = encodeAbiParameters(parseAbiParameters("address user,address agent"), [
    owner as `0x${string}`,
    agent as `0x${string}`,
  ]);
  const encodedReport = encodeAbiParameters(parseAbiParameters("string actionType, bytes payload"), [
    ROUTER_AGENT_REVOKE_ACTION_TYPE,
    payloadHex,
  ]);
  const report = runtime.report({
    ...prepareReportRequest(encodedReport),
  }).result();

  const writeReportResult = evmClient
    .writeReport(runtime, {
      receiver,
      report,
      gasConfig: {
        gasLimit: evmConfig.reportGasLimit,
      },
    })
    .result();

  if (writeReportResult.txStatus === TxStatus.REVERTED) {
    return makeResponse(requestId, writeReportResult.errorMessage || "writeReport reverted");
  }

  const txHash = bytesToHex(writeReportResult.txHash || new Uint8Array(32));
  const explorerUrl = txExplorer(evmConfig.chainName, txHash);

  return JSON.stringify({
    revoked: true,
    requestId,
    txHash,
    chainName: evmConfig.chainName,
    receiver,
    explorerUrl,
  } satisfies RevokeResponse);
};

export const revokeSessionHttpHandler = revokeAgentPermissionHttpHandler;
