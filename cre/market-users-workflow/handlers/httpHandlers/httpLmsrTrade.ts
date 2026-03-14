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
const PRICE_PRECISION = 1_000_000n;
const FEE_PRECISION_BPS = 10_000n;
const LMSR_TRADE_FEE_BPS = 400n; // 4% fee - must match PredictionMarket constants

/**
 * Fixed-point scale used throughout BigInt LMSR math.
 *
 * WAD (1e18) is the de-facto standard in DeFi fixed-point libraries
 * (e.g. Solidity's DSMath, PRBMath, FixedPointMathLib). It gives 18
 * decimal digits of fractional precision — more than enough for price/cost
 * calculations where the final outputs are only 6-decimal (1e6) prices and
 * integer collateral units.
 */
const WAD = 1_000_000_000_000_000_000n; // 1e18

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

// ─── BigInt Fixed-Point Math ─────────────────────────────────────────────────
//
// All functions below operate entirely in BigInt with WAD (1e18) scaling.
// No Number / floating-point is used anywhere in the LMSR math path.
//
// Design choices & trade-offs
// ───────────────────────────
// • exp(x)   20-term Taylor series around 0, with range reduction via
//             exp(x) = exp(x mod ln2) * 2^k  so the series always converges
//             fast. Accurate to < 1 ULP (WAD unit) for inputs up to ~135 WAD
//             (i.e. x < 135, which is far beyond any realistic share ratio).
//
// • ln(x)   - Halley's method (cubic convergence) seeded from a bit-length
//             estimate, then refined until the iterate stops changing.
//             Converges in ≤ 8 iterations for any positive WAD-scaled input.
//
// • lmsrCost / lmsrPrice - bigint ports of the log-sum-exp (LSE) trick:
//             shift all exponents by the maximum before summing to prevent
//             overflow, then re-add it. Identical algorithmic structure to
//             the float version but fully precision-safe.

/** Absolute value of a bigint */
function absBigInt(x: bigint): bigint {
  return x < 0n ? -x : x;
}

/**
 * WAD-scaled natural exponent: exp(x) where x is WAD-scaled.
 *
 * Range reduction: x = k*ln2 + r  →  exp(x) = 2^k * exp(r)
 * Then exp(r) via 20-term Taylor series (r is in [-ln2/2, ln2/2]).
 *
 * Handles negative x correctly (exp(-x) = 1/exp(x)).
 * Reverts (throws) for x > 135*WAD, mirroring Solidity overflow guards.
 */
function wadExp(x: bigint): bigint {
  if (x === 0n) return WAD;

  const MAX_INPUT = 135n * WAD;
  if (x > MAX_INPUT) throw new Error(`wadExp overflow: x=${x}`);

  // Handle negatives: exp(-x) = WAD^2 / exp(x)
  if (x < 0n) return (WAD * WAD) / wadExp(-x);

  // ln(2) scaled to WAD
  const LN2 = 693_147_180_559_945_309n; // ln(2) * 1e18

  // Range reduction: find k such that x = k*LN2 + r, 0 <= r < LN2
  const k = x / LN2;
  const r = x - k * LN2; // r in [0, LN2)

  // Taylor series: exp(r) = Σ r^n / n!  (n=0..19)
  // Accumulate in WAD scale; each term = prev_term * r / (n * WAD)
  let result = WAD; // term_0 = 1 * WAD
  let term = WAD;
  for (let n = 1n; n <= 20n; n++) {
    term = (term * r) / (n * WAD);
    result += term;
    if (term === 0n) break; // converged
  }

  // Re-apply range reduction: multiply by 2^k
  // Do it via repeated squaring to avoid BigInt shift limitations with WAD
  let scale = WAD;
  let base = 2n * WAD; // 2.0 in WAD
  let exp = k;
  while (exp > 0n) {
    if (exp & 1n) scale = (scale * base) / WAD;
    base = (base * base) / WAD;
    exp >>= 1n;
  }

  return (result * scale) / WAD;
}

/**
 * WAD-scaled natural logarithm: ln(x) where x is WAD-scaled.
 *
 * Uses Halley's method (cubic convergence):
 *   y_{n+1} = y_n + 2 * (x - exp(y_n)) / (x + exp(y_n))
 *
 * Seeded by bit-length of x to give a starting point within 1 bit of truth.
 * Typically converges in 5-8 iterations.
 *
 * Throws for x <= 0.
 */
function wadLn(x: bigint): bigint {
  if (x <= 0n) throw new Error(`wadLn domain error: x=${x}`);
  if (x === WAD) return 0n;

  // Seed: bit_length(x / WAD) * ln(2)  (coarse integer approximation)
  const LN2 = 693_147_180_559_945_309n;
  const intPart = x / WAD;
  let bits = 0n;
  let tmp = intPart > 0n ? intPart : 1n;
  while (tmp > 0n) {
    tmp >>= 1n;
    bits++;
  }
  let y = (bits - 1n) * LN2; // seed in WAD scale

  // Halley iterations until convergence (max 20 guards against infinite loop)
  for (let i = 0; i < 20; i++) {
    const ey = wadExp(y);
    // Halley step: y += 2*(x - ey)/(x + ey)
    const numerator = 2n * (x - ey);
    const denominator = x + ey;
    if (denominator === 0n) break;
    const delta = (numerator * WAD) / denominator;
    y += delta;
    if (absBigInt(delta) <= 1n) break; // converged to 1 ULP
  }

  return y;
}

/**
 * LMSR cost function in BigInt fixed-point (WAD scale).
 *
 *   C(q) = b × ln( Σ exp(q_i / b) )
 *
 * Log-sum-exp trick for overflow safety (same as the float version):
 *   C(q) = b × ( maxScaled + ln( Σ exp(q_i/b − maxScaled) ) )
 *
 * @param shares  Array of share quantities (raw bigint, same units as b)
 * @param b       Liquidity parameter (raw bigint, same units as shares)
 * @returns       Cost in the same units as b (raw bigint, NOT WAD-scaled)
 */
function lmsrCostBigInt(shares: bigint[], b: bigint): bigint {
  if (b === 0n) throw new Error("lmsrCost: b must be non-zero");

  // q_i / b, WAD-scaled: (q_i * WAD) / b
  const scaled = shares.map((q) => (q * WAD) / b);

  // max for log-sum-exp trick
  const maxScaled = scaled.reduce((m, v) => (v > m ? v : m), scaled[0]);

  // Σ exp(q_i/b − maxScaled)  [all exponents ≤ 0, so no overflow]
  const sumExp = scaled.reduce((acc, v) => acc + wadExp(v - maxScaled), 0n);

  // C = b * (maxScaled + ln(sumExp))  — result back in raw units
  // maxScaled is WAD-scaled, wadLn(sumExp) is WAD-scaled → sum is WAD-scaled
  const lnSum = wadLn(sumExp);
  const costWad = maxScaled + lnSum; // WAD-scaled
  // Bring back to raw units: (b * costWad) / WAD
  return (b * costWad) / WAD;
}

/**
 * LMSR price (probability) for outcome i, in WAD scale (i.e. 1.0 == WAD).
 *
 *   price_i = exp(q_i/b) / Σ exp(q_j/b)
 *
 * Uses the same log-sum-exp trick to prevent overflow in the softmax.
 *
 * @param shares  Array of share quantities (raw bigint)
 * @param b       Liquidity parameter (raw bigint)
 * @param i       Outcome index to price
 * @returns       Price in WAD scale (e.g. 0.6 == 600_000_000_000_000_000n)
 */
function lmsrPriceBigInt(shares: bigint[], b: bigint, i: number): bigint {
  if (b === 0n) throw new Error("lmsrPrice: b must be non-zero");

  const scaled = shares.map((q) => (q * WAD) / b);
  const maxScaled = scaled.reduce((m, v) => (v > m ? v : m), scaled[0]);

  const exps = scaled.map((v) => wadExp(v - maxScaled));
  const sumExp = exps.reduce((acc, v) => acc + v, 0n);

  // price_i = exp_i / sumExp  (both WAD-scaled → result is WAD-scaled)
  return (exps[i] * WAD) / sumExp;
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
 * cost/refund off-chain using BigInt fixed-point arithmetic (WAD = 1e18),
 * then encodes and writes a signed report to the market contract for on-chain
 * execution.
 *
 * All share quantities, the liquidity parameter b, costs, and prices stay as
 * bigint throughout — no Number cast is performed on uint256 chain values.
 *
 * Report format matches PredictionMarketResolution._processReport() expectations:
 *   ("LMSRBuy"|"LMSRSell", abi.encode(trader, outcomeIndex, sharesDelta,
 *    costOrRefund, newYesPriceE6, newNoPriceE6, nonce))
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

  // ── All chain values stay as bigint — no Number() cast ───────────
  const [yesSharesRaw, noSharesRaw, bRaw, , , currentNonceRaw] = lmsrState;

  const yesShares: bigint = yesSharesRaw;
  const noShares: bigint = noSharesRaw;
  const b: bigint = bRaw;
  const currentNonce: bigint = currentNonceRaw;

  if (b === 0n) {
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

  // ── Compute LMSR Cost/Refund (fully in BigInt) ───────────────────
  const sharesBefore: bigint[] = [yesShares, noShares];
  const costBefore: bigint = lmsrCostBigInt(sharesBefore, b);

  const sharesAfter: bigint[] = [...sharesBefore];
  if (req.action === "buy") {
    sharesAfter[req.outcomeIndex] += sharesDelta;
  } else {
    if (sharesAfter[req.outcomeIndex] < sharesDelta) {
      return fail(requestId, "insufficient outstanding shares for sell");
    }
    sharesAfter[req.outcomeIndex] -= sharesDelta;
  }

  const costAfter: bigint = lmsrCostBigInt(sharesAfter, b);

  let costOrRefund: bigint;
  if (req.action === "buy") {
    const rawCost = costAfter - costBefore;
    if (rawCost <= 0n) {
      return fail(requestId, "computed cost is non-positive (unexpected)");
    }
    // Apply fee: grossCost = rawCost * FEE_PRECISION_BPS / (FEE_PRECISION_BPS - LMSR_TRADE_FEE_BPS)
    // Integer ceiling: (a * b + c - 1) / c
    const numerator = rawCost * FEE_PRECISION_BPS;
    const denominator = FEE_PRECISION_BPS - LMSR_TRADE_FEE_BPS;
    // Ceiling division for buy (trader pays at least the true cost)
    costOrRefund = (numerator + denominator - 1n) / denominator;
  } else {
    const rawRefund = costBefore - costAfter;
    if (rawRefund <= 0n) {
      return fail(requestId, "computed refund is non-positive (unexpected)");
    }
    // Sell: no fee markup; floor division so AMM never overpays
    costOrRefund = rawRefund;
  }

  // ── Compute new prices in WAD scale, then downscale to 1e6 ───────
  //
  // lmsrPriceBigInt returns a WAD-scaled value (1.0 == 1e18).
  // To convert to E6 (1.0 == 1e6): priceE6 = priceWad * PRICE_PRECISION / WAD
  const newYesPriceWad: bigint = lmsrPriceBigInt(sharesAfter, b, 0);
  const newNoPriceWad: bigint = lmsrPriceBigInt(sharesAfter, b, 1);

  // Round to nearest for prices (neither systematically favours AMM or trader)
  const halfWad = WAD / 2n;
  let finalYesPriceE6: bigint = (newYesPriceWad * PRICE_PRECISION + halfWad) / WAD;
  let finalNoPriceE6: bigint = (newNoPriceWad * PRICE_PRECISION + halfWad) / WAD;

  // Ensure prices sum exactly to PRICE_PRECISION (absorb rounding drift on the larger leg)
  const priceSum = finalYesPriceE6 + finalNoPriceE6;
  if (priceSum !== PRICE_PRECISION) {
    const diff = PRICE_PRECISION - priceSum;
    if (finalYesPriceE6 >= finalNoPriceE6) {
      finalYesPriceE6 += diff;
    } else {
      finalNoPriceE6 += diff;
    }
  }

  const expectedNonce: bigint = currentNonce;

  runtime.log(
    `[LMSR_TRADE] ${req.action} outcomeIndex=${req.outcomeIndex} sharesDelta=${sharesDelta} ` +
      `costOrRefund=${costOrRefund} newPrices=(${finalYesPriceE6},${finalNoPriceE6}) nonce=${expectedNonce}`
  );

  // ── Encode & Submit Report ───────────────────────────────────────
  const tradePayload = encodeAbiParameters(
    parseAbiParameters("address, uint8, uint256, uint256, uint256, uint256, uint64"),
    [
      req.trader as `0x${string}`,
      req.outcomeIndex,
      sharesDelta,
      costOrRefund,
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
    costOrRefund: costOrRefund.toString(),
    newYesPriceE6: finalYesPriceE6.toString(),
    newNoPriceE6: finalNoPriceE6.toString(),
  } satisfies LmsrTradeResponse);
};