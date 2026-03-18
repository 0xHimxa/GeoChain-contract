import {
  encodeCallMsg,
  bytesToHex,
  prepareReportRequest,
  TxStatus,
  type Runtime,
} from "@chainlink/cre-sdk";
import {
  decodeFunctionResult,
  encodeAbiParameters,
  encodeFunctionData,
  parseAbiParameters,
} from "viem";
import { MarketFactoryAbi } from "../../contractsAbi/marketFactory";
import { PredictionMarketAbi } from "../../contractsAbi/predictionMarket";
import {
  ARB_MAX_SPEND_COLLATERAL,
  ARB_MIN_DEVIATION_IMPROVEMENT_BPS,
  sender,
  type Config,
} from "../../Constant-variable/config";
import { createEvmClient } from "../utils/evmUtils";

const WAD = 1_000_000_000_000_000_000n;
const PRICE_PRECISION = 1_000_000n;
const FEE_PRECISION_BPS = 10_000n;
// Mirrors market contract lower-bound guard for minimum LMSR trade granularity.
const MINIMUM_LMSR_TRADE_AMOUNT = 1_000_000n;

type LmsrState = readonly [bigint, bigint, bigint, bigint, bigint, bigint];
type DeviationStatus = readonly [number, bigint, bigint, bigint, boolean, boolean];

const getLmsrStateAbi = [
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

const canonicalYesPriceAbi = [
  {
    type: "function",
    name: "canonicalYesPriceE6",
    inputs: [],
    outputs: [{ name: "", type: "uint256" }],
    stateMutability: "view",
  },
] as const;

/** Branchless absolute value helper for bigint deltas used in convergence checks. */
const absBigInt = (x: bigint): bigint => (x < 0n ? -x : x);

/** WAD fixed-point exponent with range-reduction to keep Taylor expansion numerically stable. */
function wadExp(x: bigint): bigint {
  if (x === 0n) return WAD;
  const MAX_INPUT = 135n * WAD;
  if (x > MAX_INPUT) throw new Error(`wadExp overflow: x=${x}`);
  if (x < 0n) return (WAD * WAD) / wadExp(-x);

  const LN2 = 693_147_180_559_945_309n;
  const k = x / LN2;
  const r = x - k * LN2;

  let result = WAD;
  let term = WAD;
  for (let n = 1n; n <= 20n; n++) {
    term = (term * r) / (n * WAD);
    result += term;
    if (term === 0n) break;
  }

  let scale = WAD;
  let base = 2n * WAD;
  let exp = k;
  while (exp > 0n) {
    if (exp & 1n) scale = (scale * base) / WAD;
    base = (base * base) / WAD;
    exp >>= 1n;
  }

  return (result * scale) / WAD;
}

/** WAD fixed-point natural log via Halley's method (fast cubic convergence). */
function wadLn(x: bigint): bigint {
  if (x <= 0n) throw new Error(`wadLn domain error: x=${x}`);
  if (x === WAD) return 0n;

  const LN2 = 693_147_180_559_945_309n;
  const intPart = x / WAD;
  let bits = 0n;
  let tmp = intPart > 0n ? intPart : 1n;
  while (tmp > 0n) {
    tmp >>= 1n;
    bits++;
  }
  let y = (bits - 1n) * LN2;

  for (let i = 0; i < 20; i++) {
    const ey = wadExp(y);
    const numerator = 2n * (x - ey);
    const denominator = x + ey;
    if (denominator === 0n) break;
    const delta = (numerator * WAD) / denominator;
    y += delta;
    if (absBigInt(delta) <= 1n) break;
  }

  return y;
}

/**
 * LMSR cost function using log-sum-exp normalization for overflow-safe bigint math.
 * Returns cost in raw collateral units (not WAD).
 */
function lmsrCostBigInt(shares: bigint[], b: bigint): bigint {
  if (b === 0n) throw new Error("lmsrCost: b must be non-zero");
  const scaled = shares.map((q) => (q * WAD) / b);
  const maxScaled = scaled.reduce((m, v) => (v > m ? v : m), scaled[0]);
  const sumExp = scaled.reduce((acc, v) => acc + wadExp(v - maxScaled), 0n);
  return (b * (maxScaled + wadLn(sumExp))) / WAD;
}

/** Softmax price for one outcome in WAD scale (1e18 = 1.0). */
function lmsrPriceBigInt(shares: bigint[], b: bigint, i: number): bigint {
  if (b === 0n) throw new Error("lmsrPrice: b must be non-zero");
  const scaled = shares.map((q) => (q * WAD) / b);
  const maxScaled = scaled.reduce((m, v) => (v > m ? v : m), scaled[0]);
  const exps = scaled.map((v) => wadExp(v - maxScaled));
  const sumExp = exps.reduce((acc, v) => acc + v, 0n);
  return (exps[i] * WAD) / sumExp;
}

/**
 * Converts net LMSR cost into gross buy amount by applying effective fee.
 * Uses ceiling division so funding sent is never below required execution amount.
 */
function buyCostWithFee(rawCost: bigint, feeBps: bigint): bigint {
  const denominator = FEE_PRECISION_BPS - feeBps;
  if (denominator <= 0n) {
    throw new Error(`invalid effective fee bps: ${feeBps}`);
  }
  return (rawCost * FEE_PRECISION_BPS + denominator - 1n) / denominator;
}

/**
 * Builds a deterministic quote for one hypothetical LMSR buy.
 * This is used off-chain for report payload sizing before on-chain execution.
 */
function buildBuyQuote(
  yesShares: bigint,
  noShares: bigint,
  b: bigint,
  outcomeIndex: 0 | 1,
  sharesDelta: bigint,
  feeBps: bigint
): { costDelta: bigint; yesPriceE6: bigint; noPriceE6: bigint } {
  const sharesBefore: bigint[] = [yesShares, noShares];
  const costBefore = lmsrCostBigInt(sharesBefore, b);
  const sharesAfter: bigint[] = [yesShares, noShares];
  sharesAfter[outcomeIndex] += sharesDelta;
  const costAfter = lmsrCostBigInt(sharesAfter, b);
  const rawCost = costAfter - costBefore;
  if (rawCost <= 0n) {
    throw new Error("non-positive LMSR buy cost");
  }

  const costDelta = buyCostWithFee(rawCost, feeBps);
  const newYesPriceWad = lmsrPriceBigInt(sharesAfter, b, 0);
  const newNoPriceWad = lmsrPriceBigInt(sharesAfter, b, 1);
  const halfWad = WAD / 2n;

  let yesPriceE6 = (newYesPriceWad * PRICE_PRECISION + halfWad) / WAD;
  let noPriceE6 = (newNoPriceWad * PRICE_PRECISION + halfWad) / WAD;
  const diff = PRICE_PRECISION - (yesPriceE6 + noPriceE6);
  if (diff !== 0n) {
    if (yesPriceE6 >= noPriceE6) {
      yesPriceE6 += diff;
    } else {
      noPriceE6 += diff;
    }
  }

  return { costDelta, yesPriceE6, noPriceE6 };
}

function computeDeviationBps(localYesPriceE6: bigint, canonicalYesPriceE6: bigint): bigint {
  const diff = localYesPriceE6 >= canonicalYesPriceE6
    ? localYesPriceE6 - canonicalYesPriceE6
    : canonicalYesPriceE6 - localYesPriceE6;
  return (diff * FEE_PRECISION_BPS) / PRICE_PRECISION;
}

/**
 * Scans active markets and submits LMSR correction reports to MarketFactory.
 * Factory executes the corrective market buy using the trade quote data carried in payload.
 */
export const arbitrateUnsafeMarketHandler = (runtime: Runtime<Config>): string => {
  if (runtime.config.evms.length === 0) {
    return "No EVM config found";
  }

  const activeMarketCallData = encodeFunctionData({
    abi: MarketFactoryAbi,
    functionName: "getActiveEventList",
  });
  const getDeviationStatusCallData = encodeFunctionData({
    abi: PredictionMarketAbi,
    functionName: "getDeviationStatus",
  });
  const marketIdByAddressCallData = (marketAddress: `0x${string}`) =>
    encodeFunctionData({
      abi: MarketFactoryAbi,
      functionName: "marketIdByAddress",
      args: [marketAddress],
    });
  const getCanonicalYesCallData = encodeFunctionData({
    abi: canonicalYesPriceAbi,
    functionName: "canonicalYesPriceE6",
    args: [],
  });
  const stateCallData = "0xc1e80882" as `0x${string}`;

  let scannedMarkets = 0;
  let unsafeMarkets = 0;
  let correctedMarkets = 0;

  for (const evmConfig of runtime.config.evms) {
    // Process each configured chain independently; a single chain failure must not stop the sweep.
    const evmClient = createEvmClient(runtime, evmConfig);

    let activeMarketList: `0x${string}`[] = [];
    try {
      const activeMarketResult = evmClient
        .callContract(runtime, {
          call: encodeCallMsg({
            from: sender,
            to: evmConfig.marketFactoryAddress as `0x${string}`,
            data: activeMarketCallData,
          }),
        })
        .result();

      activeMarketList = decodeFunctionResult({
        abi: MarketFactoryAbi,
        functionName: "getActiveEventList",
        data: bytesToHex(activeMarketResult.data),
      }) as `0x${string}`[];
    } catch (error) {
      runtime.log(
        `[${evmConfig.chainName}] failed to load active markets from ${evmConfig.marketFactoryAddress}: ${
          error instanceof Error ? error.message : String(error)
        }`
      );
      continue;
    }

    for (const marketAddress of activeMarketList) {
      scannedMarkets += 1;

      let deviationStatus: DeviationStatus;
      try {
        const deviationResult = evmClient
          .callContract(runtime, {
            call: encodeCallMsg({
              from: sender,
              to: marketAddress,
              data: getDeviationStatusCallData,
            }),
          })
          .result();

        deviationStatus = decodeFunctionResult({
          abi: PredictionMarketAbi,
          functionName: "getDeviationStatus",
          data: bytesToHex(deviationResult.data),
        }) as DeviationStatus;
      } catch (error) {
        runtime.log(
          `[${evmConfig.chainName}] skipping ${marketAddress}: getDeviationStatus reverted (${
            error instanceof Error ? error.message : String(error)
          })`
        );
        continue;
      }

      // Only unsafe bands are candidates for corrective arbitrage trades.
      const [band, deviationBeforeBps, effectiveFeeBps, , allowYesForNo, allowNoForYes] = deviationStatus;
      if (Number(band) !== 2 && Number(band) !== 3) continue;
      if (!allowYesForNo && !allowNoForYes) {
        runtime.log(`[${evmConfig.chainName}] skipping ${marketAddress}: unsafe band without valid direction`);
        continue;
      }
      unsafeMarkets += 1;

      // Resolve immutable market id from address; reports are keyed by marketId in factory logic.
      let marketId: bigint;
      try {
        const marketIdCallResult = evmClient
          .callContract(runtime, {
            call: encodeCallMsg({
              from: sender,
              to: evmConfig.marketFactoryAddress as `0x${string}`,
              data: marketIdByAddressCallData(marketAddress),
            }),
          })
          .result();

        marketId = decodeFunctionResult({
          abi: MarketFactoryAbi,
          functionName: "marketIdByAddress",
          data: bytesToHex(marketIdCallResult.data),
        }) as bigint;
      } catch (error) {
        runtime.log(
          `[${evmConfig.chainName}] skipping ${marketAddress}: marketId lookup failed (${
            error instanceof Error ? error.message : String(error)
          })`
        );
        continue;
      }
      if (marketId === 0n) {
        runtime.log(`[${evmConfig.chainName}] skipping ${marketAddress}: marketIdByAddress returned 0`);
        continue;
      }

      // Snapshot local LMSR state and canonical reference price used to measure deviation.
      let lmsrState: LmsrState;
      try {
        const callResult = evmClient
          .callContract(runtime, {
            call: encodeCallMsg({
              from: sender,
              to: marketAddress,
              data: stateCallData,
            }),
          })
          .result();
        lmsrState = decodeFunctionResult({
          abi: getLmsrStateAbi,
          functionName: "getLMSRState",
          data: bytesToHex(callResult.data),
        }) as LmsrState;
      } catch (error) {
        runtime.log(
          `[${evmConfig.chainName}] skipping ${marketAddress}: failed getLMSRState (${
            error instanceof Error ? error.message : String(error)
          })`
        );
        continue;
      }

      let canonicalYesPriceE6 = 500_000n;
      try {
        const canonicalResult = evmClient
          .callContract(runtime, {
            call: encodeCallMsg({
              from: sender,
              to: marketAddress,
              data: getCanonicalYesCallData,
            }),
          })
          .result();
        canonicalYesPriceE6 = decodeFunctionResult({
          abi: canonicalYesPriceAbi,
          functionName: "canonicalYesPriceE6",
          data: bytesToHex(canonicalResult.data),
        }) as bigint;
      } catch (error) {
        runtime.log(
          `[${evmConfig.chainName}] skipping ${marketAddress}: failed canonicalYesPriceE6 (${
            error instanceof Error ? error.message : String(error)
          })`
        );
        continue;
      }

      const [yesShares, noShares, b, localYesPriceE6, , currentNonce] = lmsrState;
      if (b === 0n) {
        runtime.log(`[${evmConfig.chainName}] skipping ${marketAddress}: LMSR not initialized`);
        continue;
      }

      // Unsafe direction mapping to LMSR buy:
      // allowYesForNo => YES overpriced => buy NO (outcomeIndex 1)
      // allowNoForYes => NO overpriced => buy YES (outcomeIndex 0)
      let outcomeIndex: 0 | 1 = allowYesForNo ? 1 : 0;
      if (allowYesForNo && allowNoForYes) {
        // If both directions are technically allowed, bias toward the side that moves toward canonical price.
        const yesDistance = localYesPriceE6 >= canonicalYesPriceE6
          ? localYesPriceE6 - canonicalYesPriceE6
          : canonicalYesPriceE6 - localYesPriceE6;
        outcomeIndex = localYesPriceE6 >= canonicalYesPriceE6 || yesDistance === 0n ? 1 : 0;
      }

      // Two-phase sizing:
      // 1) Exponential expansion to find an upper bound near budget.
      // 2) Binary search for max shares that still fit ARB_MAX_SPEND_COLLATERAL.
      let lo = MINIMUM_LMSR_TRADE_AMOUNT;
      let hi = MINIMUM_LMSR_TRADE_AMOUNT;
      let bestDelta = 0n;
      let bestCost = 0n;
      let bestYesPriceE6 = localYesPriceE6;
      let bestNoPriceE6 = PRICE_PRECISION - localYesPriceE6;
      let bestDeviationAfter = deviationBeforeBps;

      try {
        while (hi <= ARB_MAX_SPEND_COLLATERAL * 2n) {
          const quote = buildBuyQuote(
            yesShares,
            noShares,
            b,
            outcomeIndex,
            hi,
            effectiveFeeBps
          );
          if (quote.costDelta > ARB_MAX_SPEND_COLLATERAL) break;
          bestDelta = hi;
          bestCost = quote.costDelta;
          bestYesPriceE6 = quote.yesPriceE6;
          bestNoPriceE6 = quote.noPriceE6;
          bestDeviationAfter = computeDeviationBps(quote.yesPriceE6, canonicalYesPriceE6);
          hi *= 2n;
        }

        if (bestDelta === 0n) {
          runtime.log(
            `[${evmConfig.chainName}] skipping ${marketAddress}: budget ${ARB_MAX_SPEND_COLLATERAL} too small for LMSR min trade`
          );
          continue;
        }

        lo = bestDelta;
        while (lo + 1n < hi) {
          const mid = (lo + hi) / 2n;
          const quote = buildBuyQuote(
            yesShares,
            noShares,
            b,
            outcomeIndex,
            mid,
            effectiveFeeBps
          );
          if (quote.costDelta <= ARB_MAX_SPEND_COLLATERAL) {
            lo = mid;
            bestDelta = mid;
            bestCost = quote.costDelta;
            bestYesPriceE6 = quote.yesPriceE6;
            bestNoPriceE6 = quote.noPriceE6;
            bestDeviationAfter = computeDeviationBps(quote.yesPriceE6, canonicalYesPriceE6);
          } else {
            hi = mid;
          }
        }
      } catch (error) {
        runtime.log(
          `[${evmConfig.chainName}] skipping ${marketAddress}: quote sizing failed (${
            error instanceof Error ? error.message : String(error)
          })`
        );
        continue;
      }

      const deviationImprovement = deviationBeforeBps > bestDeviationAfter
        ? deviationBeforeBps - bestDeviationAfter
        : 0n;
      if (deviationImprovement < ARB_MIN_DEVIATION_IMPROVEMENT_BPS) {
        runtime.log(
          `[${evmConfig.chainName}] skipping ${marketAddress}: improvement=${deviationImprovement}bps below min=${ARB_MIN_DEVIATION_IMPROVEMENT_BPS}`
        );
        continue;
      }

      // Payload schema must match MarketFactory.priceCorrection decoding order exactly.
      const correctionPayload = encodeAbiParameters(
        parseAbiParameters(
          "uint256 marketId, uint8 outcomeIndex, uint256 sharesDelta, uint256 costDelta, uint256 newYesPriceE6, uint256 newNoPriceE6, uint64 nonce, uint256 maxSpendCollateral, uint256 minDeviationImprovementBps"
        ),
        [
          marketId,
          outcomeIndex,
          bestDelta,
          bestCost,
          bestYesPriceE6,
          bestNoPriceE6,
          currentNonce,
          ARB_MAX_SPEND_COLLATERAL,
          ARB_MIN_DEVIATION_IMPROVEMENT_BPS,
        ]
      );

      const encodedReport = encodeAbiParameters(parseAbiParameters("string actionType, bytes payload"), [
        "priceCorrection",
        correctionPayload,
      ]);
      const reportResponse = runtime.report({
        ...prepareReportRequest(encodedReport),
      }).result();

      const writeReportResult = evmClient
        .writeReport(runtime, {
          receiver: evmConfig.marketFactoryAddress as `0x${string}`,
          report: reportResponse,
          gasConfig: {
            gasLimit: "10000000",
          },
        })
        .result();

      if (writeReportResult.txStatus === TxStatus.REVERTED) {
        runtime.log(
          `[${evmConfig.chainName}] priceCorrection REVERTED marketId=${marketId}: ${writeReportResult.errorMessage || "unknown"}`
        );
        continue;
      }

      const txHash = bytesToHex(writeReportResult.txHash || new Uint8Array(32));
      runtime.log(
        `[${evmConfig.chainName}] priceCorrection tx marketId=${marketId} market=${marketAddress} outcome=${outcomeIndex} shares=${bestDelta} cost=${bestCost} deviation ${deviationBeforeBps}->${bestDeviationAfter}: ${txHash}`
      );
      correctedMarkets += 1;
    }
  }

  return `Arbitrage scan complete: scanned=${scannedMarkets}, unsafe=${unsafeMarkets}, corrected=${correctedMarkets}`;
};
