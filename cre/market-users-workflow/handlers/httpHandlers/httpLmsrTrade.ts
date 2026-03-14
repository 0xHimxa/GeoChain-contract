import {
  EVMClient,
  TxStatus,
  bytesToHex,
  encodeCallMsg,
  getNetwork,
  prepareReportRequest,
  type HTTPPayload,
  type Runtime,
} from "@chainlink/cre-sdk";
import {
  decodeFunctionResult,
  encodeFunctionData,
  encodeAbiParameters,
  parseAbiParameters,
} from "viem";
import { type Config } from "../../Constant-variable/config";
import { consumeApprovalRecord, getFirestoreIdToken } from "../../firebase/sessionStore";

// ─── Types ───────────────────────────────────────────────────────────────────

type LmsrTradeRequest = {
  requestId?: string;
  approvalId?: string;
  approvalID?: string;
  approval_id?: string;
  market?: string;
  chainId?: number;
  outcomeIndex?: number;
  amount?: string;
  action?: "buy" | "sell";
  trader?: string;
  creDecision?: {
    approvalId?: string;
    approvalID?: string;
    approval_id?: string;
  };
};

type LmsrTradeResponse = {
  submitted: boolean;
  requestId: string;
  reason?: string;
  txHash?: string;
  chainName?: string;
  receiver?: string;
  explorerUrl?: string;
  costOrRefund?: string;
  newYesPriceE6?: string;
  newNoPriceE6?: string;
};

// ─── Constants ───────────────────────────────────────────────────────────────

const HEX_ADDRESS_REGEX = /^0x[a-fA-F0-9]{40}$/;
const PRICE_PRECISION = 1_000_000;
const FEE_PRECISION_BPS = 10_000;
const LMSR_TRADE_FEE_BPS = 400; // 4% fee - must match PredictionMarket constants

/** ABI fragment for PredictionMarketBase.getLMSRState() */
const getLMSRStateAbi = [
  {
    type: "function",
    name: "getLMSRState",
    inputs: [],
    outputs: [
      { name: "yesShares", type: "uint256" },
      { name: "noShares", type: "uint256" },
      { name: "b", type: "uint256" },
      { name: "yesPriceE6", type: "uint256" },
      { name: "noPriceE6", type: "uint256" },
      { name: "currentNonce", type: "uint64" },
    ],
    stateMutability: "view",
  },
] as const;

const getYesTokenAbi = [
  {
    type: "function",
    name: "yesToken",
    inputs: [],
    outputs: [{ name: "", type: "address" }],
    stateMutability: "view",
  },
] as const;

const getNoTokenAbi = [
  {
    type: "function",
    name: "noToken",
    inputs: [],
    outputs: [{ name: "", type: "address" }],
    stateMutability: "view",
  },
] as const;

const erc20BalanceOfAbi = [
  {
    type: "function",
    name: "balanceOf",
    inputs: [{ name: "account", type: "address" }],
    outputs: [{ name: "", type: "uint256" }],
    stateMutability: "view",
  },
] as const;

type LMSRState = readonly [bigint, bigint, bigint, bigint, bigint, bigint];

// ─── LMSR Math (log-sum-exp trick for numerical stability) ───────────────────

/**
 * Computes LMSR cost function: C(q) = b × ln(Σ exp(q_i / b))
 * Uses the log-sum-exp trick to avoid overflow: max + ln(Σ exp(v_i - max))
 */
function lmsrCost(shares: number[], b: number): number {
  const scaled = shares.map((q) => q / b);
  const max = Math.max(...scaled);
  const sumExp = scaled.reduce((s, v) => s + Math.exp(v - max), 0);
  return b * (max + Math.log(sumExp));
}

/**
 * Computes LMSR probability/price for outcome i: price_i = exp(q_i/b) / Σ exp(q_j/b)
 * Uses log-sum-exp trick for numerical stability (softmax).
 */
function lmsrPrice(shares: number[], b: number, i: number): number {
  const scaled = shares.map((q) => q / b);
  const max = Math.max(...scaled);
  const exps = scaled.map((v) => Math.exp(v - max));
  const sum = exps.reduce((a, c) => a + c, 0);
  return exps[i] / sum;
}

// ─── Helpers ─────────────────────────────────────────────────────────────────

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

const parseRequest = (payload: HTTPPayload): LmsrTradeRequest => {
  const raw = new TextDecoder().decode(payload.input);
  if (!raw.trim()) throw new Error("empty payload");
  return JSON.parse(raw) as LmsrTradeRequest;
};

const toBigIntAmount = (value?: string): bigint => {
  if (!value) return 0n;
  if (!/^\d+$/.test(value)) {
    throw new Error("amount must be a numeric string");
  }
  return BigInt(value);
};

const normalizeRequest = (req: LmsrTradeRequest): LmsrTradeRequest => {
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
  const requestId = String(req.requestId || "").trim();

  return {
    ...req,
    requestId,
    approvalId,
    market: (req.market || "").trim(),
    trader: (req.trader || "").trim(),
    action: (req.action || "").trim().toLowerCase() as "buy" | "sell",
  };
};

const fail = (requestId: string, reason: string): string =>
  JSON.stringify({ submitted: false, requestId, reason } satisfies LmsrTradeResponse);

// ─── Main Handler ────────────────────────────────────────────────────────────

/**
 * LMSR Trade HTTP handler for the CRE market-users workflow.
 *
 * Receives a user trade intent, reads on-chain LMSR state, computes the LMSR
 * cost/refund off-chain using exp/ln, then encodes and writes a signed report
 * to the market contract for on-chain execution.
 *
 * Report format matches PredictionMarketResolution._processReport() expectations:
 *   ("LMSRBuy"|"LMSRSell", abi.encode(trader, outcomeIndex, sharesDelta, costOrRefund, newYesPriceE6, newNoPriceE6, nonce))
 */
export const lmsrTradeHttpHandler = async (
  runtime: Runtime<Config>,
  payload: HTTPPayload
): Promise<string> => {
  const requestIdFallback = `lmsr_${runtime.now().toISOString()}`;
  const tradePolicy = runtime.config.lmsrTradePolicy;

  if (!tradePolicy?.enabled) {
    return fail(requestIdFallback, "LMSR trade policy disabled");
  }

  // ── Parse & Validate ─────────────────────────────────────────────
  let req: LmsrTradeRequest;
  try {
    req = normalizeRequest(parseRequest(payload));
  } catch (error) {
    return fail(requestIdFallback, error instanceof Error ? error.message : "invalid payload");
  }

  const requestId = req.requestId || requestIdFallback;

  if (!req.approvalId || !req.approvalId.startsWith("cre_approval_")) {
    return fail(requestId, "invalid or missing approvalId");
  }

  if (typeof req.chainId !== "number") {
    return fail(requestId, "missing chainId");
  }

  if (!tradePolicy.supportedChainIds.includes(req.chainId)) {
    return fail(requestId, "chain not supported for LMSR trades");
  }

  if (!req.market || !HEX_ADDRESS_REGEX.test(req.market)) {
    return fail(requestId, "invalid market address");
  }

  if (!req.trader || !HEX_ADDRESS_REGEX.test(req.trader)) {
    return fail(requestId, "invalid trader address");
  }

  if (req.outcomeIndex !== 0 && req.outcomeIndex !== 1) {
    return fail(requestId, "outcomeIndex must be 0 (YES) or 1 (NO)");
  }

  if (req.action !== "buy" && req.action !== "sell") {
    return fail(requestId, "action must be 'buy' or 'sell'");
  }

  let sharesDelta: bigint;
  try {
    sharesDelta = toBigIntAmount(req.amount);
  } catch (error) {
    return fail(requestId, error instanceof Error ? error.message : "invalid amount");
  }
  if (sharesDelta <= 0n) {
    return fail(requestId, "amount must be greater than zero");
  }

  // ── Consume Approval ─────────────────────────────────────────────
  const actionType = req.action === "buy" ? "LMSRBuy" : "LMSRSell";

  const firestoreToken = getFirestoreIdToken(runtime);
  const approvalConsumption = consumeApprovalRecord(runtime, firestoreToken, {
    approvalId: req.approvalId,
    chainId: req.chainId,
    actionType,
    amountUsdc: sharesDelta.toString(),
    nowUnix: BigInt(Math.floor(runtime.now().getTime() / 1000)),
  });
  if (!approvalConsumption.ok) {
    return fail(requestId, approvalConsumption.reason || "invalid sponsorship approval");
  }

  // ── Resolve EVM Config ───────────────────────────────────────────
  const evmConfig = runtime.config.evms.find((evm) => toChainId(evm.chainName) === req.chainId);
  if (!evmConfig) {
    return fail(requestId, "chainId not mapped in config.evms");
  }

  const network = getNetwork({
    chainFamily: "evm",
    chainSelectorName: evmConfig.chainName,
    isTestnet: true,
  });
  if (!network) {
    return fail(requestId, `unknown chain name: ${evmConfig.chainName}`);
  }

  const evmClient = new EVMClient(network.chainSelector.selector);

  // ── Read On-Chain LMSR State ─────────────────────────────────────
  const getLMSRStateCallData = encodeAbiParameters(
    parseAbiParameters("bytes4"),
    // getLMSRState() selector
    ["0x" as `0x${string}`]
  );

  // Use raw ABI encoding for the call
  const stateCallData = "0xc1e80882"; // keccak256("getLMSRState()")[:4]

  let lmsrState: LMSRState;
  try {
    const callResult = evmClient
      .callContract(runtime, {
        call: encodeCallMsg({
          from: req.trader as `0x${string}`,
          to: req.market as `0x${string}`,
          data: stateCallData as `0x${string}`,
        }),
      })
      .result();

    lmsrState = decodeFunctionResult({
      abi: getLMSRStateAbi,
      functionName: "getLMSRState",
      data: bytesToHex(callResult.data),
    }) as LMSRState;
  } catch (error) {
    return fail(
      requestId,
      `failed to read LMSR state: ${error instanceof Error ? error.message : String(error)}`
    );
  }

  const [yesSharesRaw, noSharesRaw, bRaw, , , currentNonceRaw] = lmsrState;

  // Convert to floating point for LMSR math
  const yesShares = Number(yesSharesRaw);
  const noShares = Number(noSharesRaw);
  const b = Number(bRaw);
  const sharesDeltaNum = Number(sharesDelta);
  const currentNonce = Number(currentNonceRaw);

  if (b === 0) {
    return fail(requestId, "market not initialized (b=0)");
  }

  // ── For sells, verify trader balance early to avoid on-chain revert ──
  if (req.action === "sell") {
    try {
      const tokenCallData = encodeFunctionData({
        abi: req.outcomeIndex === 0 ? getYesTokenAbi : getNoTokenAbi,
        functionName: req.outcomeIndex === 0 ? "yesToken" : "noToken",
        args: [],
      });

      const tokenResult = evmClient
        .callContract(runtime, {
          call: encodeCallMsg({
            from: req.trader as `0x${string}`,
            to: req.market as `0x${string}`,
            data: tokenCallData as `0x${string}`,
          }),
        })
        .result();

      const tokenAddress = decodeFunctionResult({
        abi: req.outcomeIndex === 0 ? getYesTokenAbi : getNoTokenAbi,
        functionName: req.outcomeIndex === 0 ? "yesToken" : "noToken",
        data: bytesToHex(tokenResult.data),
      }) as `0x${string}`;

      const balanceCallData = encodeFunctionData({
        abi: erc20BalanceOfAbi,
        functionName: "balanceOf",
        args: [req.trader as `0x${string}`],
      });

      const balanceResult = evmClient
        .callContract(runtime, {
          call: encodeCallMsg({
            from: req.trader as `0x${string}`,
            to: tokenAddress,
            data: balanceCallData as `0x${string}`,
          }),
        })
        .result();

      const balance = decodeFunctionResult({
        abi: erc20BalanceOfAbi,
        functionName: "balanceOf",
        data: bytesToHex(balanceResult.data),
      }) as bigint;

      if (balance < sharesDelta) {
        return fail(requestId, "insufficient outcome token balance for sell");
      }
    } catch (error) {
      return fail(
        requestId,
        `failed to read outcome token balance: ${
          error instanceof Error ? error.message : String(error)
        }`
      );
    }
  }

  // ── Compute LMSR Cost/Refund ─────────────────────────────────────
  const sharesBefore = [yesShares, noShares];
  const costBefore = lmsrCost(sharesBefore, b);

  const sharesAfter = [...sharesBefore];
  if (req.action === "buy") {
    sharesAfter[req.outcomeIndex] += sharesDeltaNum;
  } else {
    //come
    // Sell: verify trader has enough shares
    if (sharesAfter[req.outcomeIndex] < sharesDeltaNum) {
      return fail(requestId, "insufficient outstanding shares for sell");
    }
    sharesAfter[req.outcomeIndex] -= sharesDeltaNum;
  }

  const costAfter = lmsrCost(sharesAfter, b);

  let costOrRefundFloat: number;
  if (req.action === "buy") {
    costOrRefundFloat = costAfter - costBefore;
    if (costOrRefundFloat <= 0) {
      return fail(requestId, "computed cost is non-positive (unexpected)");
    }


  // Convert to inclusive fee: subtract fee so AMM stays balanced if fee removed later
  
  const grossMultiplier =
    FEE_PRECISION_BPS / (FEE_PRECISION_BPS - LMSR_TRADE_FEE_BPS);

  costOrRefundFloat = costOrRefundFloat * grossMultiplier;


  } else {
    costOrRefundFloat = costBefore - costAfter;
    if (costOrRefundFloat <= 0) {
      return fail(requestId, "computed refund is non-positive (unexpected)");
    }
  }

  // Compute new prices after trade
  const newYesPrice = lmsrPrice(sharesAfter, b, 0);
  const newNoPrice = lmsrPrice(sharesAfter, b, 1);

  // Scale to integers (collateral has 6 decimals, prices use 1e6 precision)
  const costOrRefundInt = req.action === "buy" ? BigInt(Math.ceil(costOrRefundFloat)) : BigInt(Math.floor(costOrRefundFloat));
  const newYesPriceE6 = BigInt(Math.round(newYesPrice * PRICE_PRECISION));
  const newNoPriceE6 = BigInt(Math.round(newNoPrice * PRICE_PRECISION));

  // Ensure prices sum to ~PRICE_PRECISION (normalize if rounding drift)
  const priceSum = newYesPriceE6 + newNoPriceE6;
  let finalYesPriceE6 = newYesPriceE6;
  let finalNoPriceE6 = newNoPriceE6;
  if (priceSum !== BigInt(PRICE_PRECISION)) {
    // Adjust the larger price to absorb the rounding error
    const diff = BigInt(PRICE_PRECISION) - priceSum;
    if (finalYesPriceE6 >= finalNoPriceE6) {
      finalYesPriceE6 += diff;
    } else {
      finalNoPriceE6 += diff;
    }
  }

  const expectedNonce = BigInt(currentNonce);

  runtime.log(
    `[LMSR_TRADE] ${req.action} outcomeIndex=${req.outcomeIndex} sharesDelta=${sharesDelta} ` +
      `costOrRefund=${costOrRefundInt} newPrices=(${finalYesPriceE6},${finalNoPriceE6}) nonce=${expectedNonce}`
  );

  // ── Encode & Submit Report ───────────────────────────────────────
  const tradePayload = encodeAbiParameters(
    parseAbiParameters("address, uint8, uint256, uint256, uint256, uint256, uint64"),
    [
      req.trader as `0x${string}`,
      req.outcomeIndex,
      sharesDelta,
      costOrRefundInt,
      finalYesPriceE6,
      finalNoPriceE6,
      expectedNonce,
    ]
  );

  const encodedReport = encodeAbiParameters(
    parseAbiParameters("string actionType, bytes payload"),
    [actionType, tradePayload]
  );

  const report = runtime
    .report({
      ...prepareReportRequest(encodedReport),
    })
    .result();

  const writeReportResult = evmClient
    .writeReport(runtime, {
      receiver: req.market as `0x${string}`,
      report,
      gasConfig: {
        gasLimit: evmConfig.reportGasLimit || "10000000",
      },
    })
    .result();

  if (writeReportResult.txStatus === TxStatus.REVERTED) {
    return JSON.stringify({
      submitted: false,
      requestId,
      reason: writeReportResult.errorMessage || "writeReport reverted",
      chainName: evmConfig.chainName,
      receiver: req.market,
    } satisfies LmsrTradeResponse);
  }

  const txHash = bytesToHex(writeReportResult.txHash || new Uint8Array(32));
  const explorerUrl = txExplorer(evmConfig.chainName, txHash);
  runtime.log(`[LMSR_TRADE] requestId=${requestId} action=${req.action} txHash=${txHash}`);

  return JSON.stringify({
    submitted: true,
    requestId,
    txHash,
    chainName: evmConfig.chainName,
    receiver: req.market,
    explorerUrl,
    costOrRefund: costOrRefundInt.toString(),
    newYesPriceE6: finalYesPriceE6.toString(),
    newNoPriceE6: finalNoPriceE6.toString(),
  } satisfies LmsrTradeResponse);
};
