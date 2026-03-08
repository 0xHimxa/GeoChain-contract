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
import { consumeFiatPaymentRecord, getFirestoreIdToken } from "../../firebase/sessionStore";

type FiatCreditRequest = {
  requestId?: string;
  paymentId?: string;
  chainId?: number;
  user?: string;
  amountUsdc?: string;
  provider?: string;
};

type FiatCreditResponse = {
  submitted: boolean;
  requestId: string;
  reason?: string;
  txHash?: string;
  chainName?: string;
  receiver?: string;
  explorerUrl?: string;
};

const HEX_ADDRESS_REGEX = /^0x[a-fA-F0-9]{40}$/;
const USDC_INTEGER_REGEX = /^\d+$/;
const ACTION_TYPE = "routerCreditFromFiat";
const DEFAULT_MAX_AMOUNT_USDC = 10_000n * 1_000_000n;

const toBigIntAmount = (value?: string): bigint => {
  if (!value || !USDC_INTEGER_REGEX.test(value)) {
    throw new Error("amountUsdc must be a numeric string");
  }
  return BigInt(value);
};

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

const parseRequest = (payload: HTTPPayload): FiatCreditRequest => {
  const raw = new TextDecoder().decode(payload.input);
  if (!raw.trim()) throw new Error("empty payload");
  return JSON.parse(raw) as FiatCreditRequest;
};

/**
 * Credits users from off-chain fiat payments by validating provider/chain/user/amount,
 * consuming a payment record in Firestore to prevent replay, and submitting a
 * `routerCreditFromFiat` report to the mapped router receiver on the target chain.
 */
export const fiatCreditHttpHandler = async (runtime: Runtime<Config>, payload: HTTPPayload): Promise<string> => {
  const requestIdFallback = `fiat_${runtime.now().toISOString()}`;
  const policy = runtime.config.fiatCreditPolicy;
  if (!policy?.enabled) {
    return JSON.stringify({
      submitted: false,
      requestId: requestIdFallback,
      reason: "fiat credit policy disabled",
    } satisfies FiatCreditResponse);
  }

  let req: FiatCreditRequest;
  try {
    req = parseRequest(payload);
  } catch (error) {
    return JSON.stringify({
      submitted: false,
      requestId: requestIdFallback,
      reason: error instanceof Error ? error.message : "invalid payload",
    } satisfies FiatCreditResponse);
  }

  const requestId = req.requestId || requestIdFallback;
  const paymentId = (req.paymentId || "").trim();
  if (!paymentId || paymentId.length > 128) {
    return JSON.stringify({
      submitted: false,
      requestId,
      reason: "invalid paymentId",
    } satisfies FiatCreditResponse);
  }

  if (typeof req.chainId !== "number" || !policy.supportedChainIds.includes(req.chainId)) {
    return JSON.stringify({
      submitted: false,
      requestId,
      reason: "chain is not supported for fiat credit",
    } satisfies FiatCreditResponse);
  }

  const user = (req.user || "").trim();
  if (!HEX_ADDRESS_REGEX.test(user)) {
    return JSON.stringify({
      submitted: false,
      requestId,
      reason: "invalid user address",
    } satisfies FiatCreditResponse);
  }

  const provider = (req.provider || "").trim().toLowerCase();
  if (!provider || !policy.allowedProviders.includes(provider)) {
    return JSON.stringify({
      submitted: false,
      requestId,
      reason: "provider not allowed",
    } satisfies FiatCreditResponse);
  }

  let amount: bigint;
  try {
    amount = toBigIntAmount(req.amountUsdc);
  } catch (error) {
    return JSON.stringify({
      submitted: false,
      requestId,
      reason: error instanceof Error ? error.message : "invalid amountUsdc",
    } satisfies FiatCreditResponse);
  }
  if (amount <= 0n) {
    return JSON.stringify({
      submitted: false,
      requestId,
      reason: "amountUsdc must be greater than zero",
    } satisfies FiatCreditResponse);
  }
  const maxAmountUsdc = USDC_INTEGER_REGEX.test(policy.maxAmountUsdc)
    ? BigInt(policy.maxAmountUsdc)
    : DEFAULT_MAX_AMOUNT_USDC;
  if (amount > maxAmountUsdc) {
    return JSON.stringify({
      submitted: false,
      requestId,
      reason: "amount exceeds fiat credit limit",
    } satisfies FiatCreditResponse);
  }

  const evmConfig = runtime.config.evms.find((evm) => toChainId(evm.chainName) === req.chainId);
  if (!evmConfig) {
    return JSON.stringify({
      submitted: false,
      requestId,
      reason: "chainId not mapped in config.evms",
    } satisfies FiatCreditResponse);
  }

  const receiver = (evmConfig.routerReceiverAddress || "").trim() as `0x${string}`;
  if (!HEX_ADDRESS_REGEX.test(receiver)) {
    return JSON.stringify({
      submitted: false,
      requestId,
      reason: "invalid router receiver",
    } satisfies FiatCreditResponse);
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
    } satisfies FiatCreditResponse);
  }

  const firestoreToken = getFirestoreIdToken(runtime);
  const consumeResult = consumeFiatPaymentRecord(runtime, firestoreToken, {
    paymentId,
    requestId,
    chainId: req.chainId,
    user,
    amountUsdc: amount.toString(),
    provider,
    nowUnix: BigInt(Math.floor(runtime.now().getTime() / 1000)),
  });
  if (!consumeResult.ok) {
    return JSON.stringify({
      submitted: false,
      requestId,
      reason: consumeResult.reason,
    } satisfies FiatCreditResponse);
  }

  const reportPayload = encodeAbiParameters(parseAbiParameters("address user, uint256 amount"), [user as `0x${string}`, amount]);
  const encodedReport = encodeAbiParameters(parseAbiParameters("string actionType, bytes payload"), [ACTION_TYPE, reportPayload]);
  const report = runtime.report({
    ...prepareReportRequest(encodedReport),
  }).result();

  const evmClient = new EVMClient(network.chainSelector.selector);
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
    } satisfies FiatCreditResponse);
  }

  const txHash = bytesToHex(writeReportResult.txHash || new Uint8Array(32));
  const explorerUrl = txExplorer(evmConfig.chainName, txHash);
  runtime.log(
    `[HTTP_FIAT_CREDIT] requestId=${requestId} paymentId=${paymentId} user=${user} amountUsdc=${amount.toString()} txHash=${txHash}`
  );

  return JSON.stringify({
    submitted: true,
    requestId,
    txHash,
    chainName: evmConfig.chainName,
    receiver,
    explorerUrl,
  } satisfies FiatCreditResponse);
};
