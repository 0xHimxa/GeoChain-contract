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
import { type Config } from "../../Constant-variable/config";
import { consumeApprovalRecord, getFirestoreIdToken } from "../../firebase/sessionStore";
import { HEX_ADDRESS_REGEX, toChainId, txExplorer } from "../utils/evmUtils";
import { parseDecimalBigInt, parseJsonPayload } from "../utils/httpHandlerUtils";

type ExecuteRequest = {
  requestId?: string;
  approvalId?: string;
  approvalID?: string;
  approval_id?: string;
  chainId?: number;
  amountUsdc?: string;
  actionType?: string;
  action_type?: string;
  payloadHex?: `0x${string}`;
  payload_hex?: `0x${string}`;
  creDecision?: {
    approvalId?: string;
    approvalID?: string;
    approval_id?: string;
  };
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

const HEX_BYTES_REGEX = /^0x([a-fA-F0-9]{2})*$/;
const ROUTER_ACTION_PREFIX = "router";
const ZERO_AMOUNT_ALLOWED_ACTION_TYPES = new Set([
  "routerDisputeProposedResolution",
]);

/**
 * Parses decimal-string USDC amounts into bigint without allowing floats, signs, or formatting.
 * The handler uses this to keep approval matching deterministic across HTTP payloads and Firestore.
 */

/**
 * Decodes raw HTTP request bytes as JSON execute payload.
 */
const parseRequest = (payload: HTTPPayload): ExecuteRequest => {
  return parseJsonPayload<ExecuteRequest>(payload);
};

/**
 * Accepts legacy field aliases from older clients and collapses them into one canonical shape.
 */
const normalizeExecuteRequest = (req: ExecuteRequest): ExecuteRequest => {
  const nested = req.creDecision || {};
  const approvalId = String(
    req.approvalId ||
      req.approvalID ||
      req.approval_id ||
      nested.approvalId ||
      nested.approvalID ||
      nested.approval_id ||
      ""
  ).trim();
  const actionType = String(req.actionType || req.action_type || "").trim();
  const payloadHex = String(req.payloadHex || req.payload_hex || "").trim() as `0x${string}`;
  const requestId = String(req.requestId || "").trim();

  return {
    ...req,
    requestId,
    approvalId,
    actionType,
    payloadHex,
  };
};

/**
 * Executes an approved sponsored action by:
 * 1. validating and normalizing the execute payload,
 * 2. consuming the matching Firestore approval exactly once,
 * 3. selecting the router or factory receiver based on action type, and
 * 4. submitting the final report on-chain through CRE.
 */
export const executeReportHttpHandler = async (runtime: Runtime<Config>, payload: HTTPPayload): Promise<string> => {
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
    req = normalizeExecuteRequest(parseRequest(payload));
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

  let amount: bigint;
  try {
    amount = parseDecimalBigInt(req.amountUsdc, "amountUsdc", true);
  } catch (error) {
    return JSON.stringify({
      submitted: false,
      requestId,
      reason: error instanceof Error ? error.message : "invalid amountUsdc",
    } satisfies ExecuteResponse);
  }
  const allowZeroAmount = !!req.actionType && ZERO_AMOUNT_ALLOWED_ACTION_TYPES.has(req.actionType);
  if (!allowZeroAmount && amount <= 0n) {
    return JSON.stringify({
      submitted: false,
      requestId,
      reason: "amountUsdc must be greater than zero",
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

  const firestoreToken = getFirestoreIdToken(runtime);
  const approvalConsumption = consumeApprovalRecord(runtime, firestoreToken, {
    approvalId: req.approvalId,
    chainId: req.chainId,
    actionType: req.actionType,
    amountUsdc: amount.toString(),
    nowUnix: BigInt(Math.floor(runtime.now().getTime() / 1000)),
  });
  if (!approvalConsumption.ok) {
    return JSON.stringify({
      submitted: false,
      requestId,
      reason: approvalConsumption.reason || "invalid sponsorship approval",
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

  const isRouterAction = req.actionType.startsWith(ROUTER_ACTION_PREFIX);
  const configuredRouterReceiver = (evmConfig.routerReceiverAddress || "").trim();
  const receiver = (
    (isRouterAction && HEX_ADDRESS_REGEX.test(configuredRouterReceiver)
      ? configuredRouterReceiver
      : evmConfig.marketFactoryAddress) as string
  ) as `0x${string}`;
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
        gasLimit: evmConfig.reportGasLimit,
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
