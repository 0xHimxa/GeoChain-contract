import {
  bytesToHex,
  encodeCallMsg,
  prepareReportRequest,
  TxStatus,
  type Runtime,
} from "@chainlink/cre-sdk";
import {
  decodeFunctionResult,
  encodeAbiParameters,
  encodeFunctionData,
  parseAbi,
  parseAbiParameters,
} from "viem";
import { sender, type Config } from "../../Constant-variable/config";
import { MarketFactoryAbi } from "../../contractsAbi/marketFactory";
import { createEvmClient } from "../utils/evmUtils";

const WAD = 1_000_000_000_000_000_000n;
const PRICE_PRECISION = 1_000_000n;
const MINIMUM_LMSR_TRADE_AMOUNT = 1_000_000n;
const PRE_CLOSE_WINDOW_SECONDS = 120n;
const ACTION_TYPE = "preCloseLmsrSell";

type LMSRState = readonly [bigint, bigint, bigint, bigint, bigint, bigint];

const getLMSRStateAbi = parseAbi([
  "function getLMSRState() view returns (uint256 yesShares, uint256 noShares, uint256 b, uint256 yesPriceE6, uint256 noPriceE6, uint64 currentNonce)",
]);
const closeTimeAbi = parseAbi(["function closeTime() view returns (uint256)"]);
const yesTokenAbi = parseAbi(["function yesToken() view returns (address)"]);
const noTokenAbi = parseAbi(["function noToken() view returns (address)"]);
const erc20BalanceOfAbi = parseAbi(["function balanceOf(address account) view returns (uint256)"]);

const absBigInt = (x: bigint): bigint => (x < 0n ? -x : x);

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

function lmsrCostBigInt(shares: bigint[], b: bigint): bigint {
  if (b === 0n) throw new Error("lmsrCost: b must be non-zero");
  const scaled = shares.map((q) => (q * WAD) / b);
  const maxScaled = scaled.reduce((m, v) => (v > m ? v : m), scaled[0]);
  const sumExp = scaled.reduce((acc, v) => acc + wadExp(v - maxScaled), 0n);
  return (b * (maxScaled + wadLn(sumExp))) / WAD;
}

function lmsrPriceBigInt(shares: bigint[], b: bigint, i: number): bigint {
  if (b === 0n) throw new Error("lmsrPrice: b must be non-zero");
  const scaled = shares.map((q) => (q * WAD) / b);
  const maxScaled = scaled.reduce((m, v) => (v > m ? v : m), scaled[0]);
  const exps = scaled.map((v) => wadExp(v - maxScaled));
  const sumExp = exps.reduce((acc, v) => acc + v, 0n);
  return (exps[i] * WAD) / sumExp;
}

function buildSellQuote(
  yesShares: bigint,
  noShares: bigint,
  b: bigint,
  outcomeIndex: 0 | 1,
  sharesDelta: bigint
): { refundDelta: bigint; yesPriceE6: bigint; noPriceE6: bigint } {
  const sharesBefore: bigint[] = [yesShares, noShares];
  const sharesAfter: bigint[] = [yesShares, noShares];

  if (sharesAfter[outcomeIndex] < sharesDelta) {
    throw new Error("insufficient outstanding shares for sell");
  }

  const costBefore = lmsrCostBigInt(sharesBefore, b);
  sharesAfter[outcomeIndex] -= sharesDelta;
  const costAfter = lmsrCostBigInt(sharesAfter, b);

  const refundDelta = costBefore - costAfter;
  if (refundDelta <= 0n) throw new Error("non-positive LMSR sell refund");

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

  return { refundDelta, yesPriceE6, noPriceE6 };
}

/**
 * Sells factory-held LMSR outcome shares during the final two minutes before market close.
 * The handler computes deterministic sell quotes off-chain and routes execution through
 * MarketFactory via `preCloseLmsrSell` reports.
 */
export const preCloseLmsrSellHandler = (runtime: Runtime<Config>): string => {
  const activeMarketCallData = encodeFunctionData({
    abi: MarketFactoryAbi,
    functionName: "getActiveEventList",
  });

  const marketIdByAddressCallData = (marketAddress: `0x${string}`) =>
    encodeFunctionData({
      abi: MarketFactoryAbi,
      functionName: "marketIdByAddress",
      args: [marketAddress],
    });

  let scanned = 0;
  let eligible = 0;
  let sold = 0;

  const nowUnix = BigInt(Math.floor(runtime.now().getTime() / 1000));

  for (const evmConfig of runtime.config.evms) {
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
        `[${evmConfig.chainName}] failed to load active markets: ${
          error instanceof Error ? error.message : String(error)
        }`
      );
      continue;
    }

    for (const marketAddress of activeMarketList) {
      scanned += 1;

      let closeTime = 0n;
      try {
        const closeTimeResult = evmClient
          .callContract(runtime, {
            call: encodeCallMsg({
              from: sender,
              to: marketAddress,
              data: encodeFunctionData({ abi: closeTimeAbi, functionName: "closeTime" }),
            }),
          })
          .result();

        closeTime = decodeFunctionResult({
          abi: closeTimeAbi,
          functionName: "closeTime",
          data: bytesToHex(closeTimeResult.data),
        }) as bigint;
      } catch (error) {
        runtime.log(
          `[${evmConfig.chainName}] skipping ${marketAddress}: closeTime read failed (${error instanceof Error ? error.message : String(error)})`
        );
        continue;
      }

      if (closeTime <= nowUnix) continue;
      const secondsToClose = closeTime - nowUnix;
      if (secondsToClose > PRE_CLOSE_WINDOW_SECONDS) continue;
      eligible += 1;

      let marketId: bigint;
      try {
        const marketIdResult = evmClient
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
          data: bytesToHex(marketIdResult.data),
        }) as bigint;
      } catch (error) {
        runtime.log(
          `[${evmConfig.chainName}] skipping ${marketAddress}: marketId lookup failed (${error instanceof Error ? error.message : String(error)})`
        );
        continue;
      }

      if (marketId === 0n) continue;

      let lmsrState: LMSRState;
      try {
        const stateResult = evmClient
          .callContract(runtime, {
            call: encodeCallMsg({
              from: sender,
              to: marketAddress,
              data: encodeFunctionData({ abi: getLMSRStateAbi, functionName: "getLMSRState" }),
            }),
          })
          .result();

        lmsrState = decodeFunctionResult({
          abi: getLMSRStateAbi,
          functionName: "getLMSRState",
          data: bytesToHex(stateResult.data),
        }) as LMSRState;
      } catch (error) {
        runtime.log(
          `[${evmConfig.chainName}] skipping ${marketAddress}: getLMSRState failed (${error instanceof Error ? error.message : String(error)})`
        );
        continue;
      }

      let yesTokenAddress: `0x${string}`;
      let noTokenAddress: `0x${string}`;
      try {
        const yesTokenResult = evmClient
          .callContract(runtime, {
            call: encodeCallMsg({
              from: sender,
              to: marketAddress,
              data: encodeFunctionData({ abi: yesTokenAbi, functionName: "yesToken" }),
            }),
          })
          .result();
        yesTokenAddress = decodeFunctionResult({
          abi: yesTokenAbi,
          functionName: "yesToken",
          data: bytesToHex(yesTokenResult.data),
        }) as `0x${string}`;

        const noTokenResult = evmClient
          .callContract(runtime, {
            call: encodeCallMsg({
              from: sender,
              to: marketAddress,
              data: encodeFunctionData({ abi: noTokenAbi, functionName: "noToken" }),
            }),
          })
          .result();
        noTokenAddress = decodeFunctionResult({
          abi: noTokenAbi,
          functionName: "noToken",
          data: bytesToHex(noTokenResult.data),
        }) as `0x${string}`;
      } catch (error) {
        runtime.log(
          `[${evmConfig.chainName}] skipping ${marketAddress}: token address read failed (${error instanceof Error ? error.message : String(error)})`
        );
        continue;
      }

      let factoryYesBalance = 0n;
      let factoryNoBalance = 0n;
      try {
        const yesBalanceResult = evmClient
          .callContract(runtime, {
            call: encodeCallMsg({
              from: sender,
              to: yesTokenAddress,
              data: encodeFunctionData({
                abi: erc20BalanceOfAbi,
                functionName: "balanceOf",
                args: [evmConfig.marketFactoryAddress as `0x${string}`],
              }),
            }),
          })
          .result();
        factoryYesBalance = decodeFunctionResult({
          abi: erc20BalanceOfAbi,
          functionName: "balanceOf",
          data: bytesToHex(yesBalanceResult.data),
        }) as bigint;

        const noBalanceResult = evmClient
          .callContract(runtime, {
            call: encodeCallMsg({
              from: sender,
              to: noTokenAddress,
              data: encodeFunctionData({
                abi: erc20BalanceOfAbi,
                functionName: "balanceOf",
                args: [evmConfig.marketFactoryAddress as `0x${string}`],
              }),
            }),
          })
          .result();
        factoryNoBalance = decodeFunctionResult({
          abi: erc20BalanceOfAbi,
          functionName: "balanceOf",
          data: bytesToHex(noBalanceResult.data),
        }) as bigint;
      } catch (error) {
        runtime.log(
          `[${evmConfig.chainName}] skipping ${marketAddress}: token balance read failed (${error instanceof Error ? error.message : String(error)})`
        );
        continue;
      }

      const [yesShares, noShares, b, , , currentNonce] = lmsrState;
      if (b === 0n) continue;

      const sellPlans: Array<{ outcomeIndex: 0 | 1; sharesDelta: bigint }> = [];
      if (factoryYesBalance >= MINIMUM_LMSR_TRADE_AMOUNT) {
        sellPlans.push({ outcomeIndex: 0, sharesDelta: factoryYesBalance });
      }
      if (factoryNoBalance >= MINIMUM_LMSR_TRADE_AMOUNT) {
        sellPlans.push({ outcomeIndex: 1, sharesDelta: factoryNoBalance });
      }

      if (sellPlans.length === 0) continue;

      let runningYesShares = yesShares;
      let runningNoShares = noShares;
      let runningNonce = currentNonce;

      for (const plan of sellPlans) {
        try {
          const maxSharesAvailable = plan.outcomeIndex === 0 ? runningYesShares : runningNoShares;
          const sharesDelta = plan.sharesDelta <= maxSharesAvailable ? plan.sharesDelta : maxSharesAvailable;
          if (sharesDelta < MINIMUM_LMSR_TRADE_AMOUNT) {
            continue;
          }

          const quote = buildSellQuote(
            runningYesShares,
            runningNoShares,
            b,
            plan.outcomeIndex,
            sharesDelta
          );

          const payload = encodeAbiParameters(
            parseAbiParameters(
              "uint256 marketId, uint8 outcomeIndex, uint256 sharesDelta, uint256 refundDelta, uint256 newYesPriceE6, uint256 newNoPriceE6, uint64 nonce"
            ),
            [
              marketId,
              plan.outcomeIndex,
              sharesDelta,
              quote.refundDelta,
              quote.yesPriceE6,
              quote.noPriceE6,
              runningNonce,
            ]
          );

          const encodedReport = encodeAbiParameters(
            parseAbiParameters("string actionType, bytes payload"),
            [ACTION_TYPE, payload]
          );

          const reportResponse = runtime
            .report({
              ...prepareReportRequest(encodedReport),
            })
            .result();

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
              `[${evmConfig.chainName}] ${ACTION_TYPE} REVERTED marketId=${marketId} market=${marketAddress}: ${
                writeReportResult.errorMessage || "unknown"
              }`
            );
            continue;
          }

          const txHash = bytesToHex(writeReportResult.txHash || new Uint8Array(32));
          runtime.log(
            `[${evmConfig.chainName}] ${ACTION_TYPE} tx marketId=${marketId} market=${marketAddress} outcome=${plan.outcomeIndex} shares=${sharesDelta} refund=${quote.refundDelta} nonce=${runningNonce}: ${txHash}`
          );

          if (plan.outcomeIndex === 0) {
            runningYesShares -= sharesDelta;
          } else {
            runningNoShares -= sharesDelta;
          }
          runningNonce += 1n;
          sold += 1;
        } catch (error) {
          runtime.log(
            `[${evmConfig.chainName}] ${ACTION_TYPE} skipped market=${marketAddress} outcome=${plan.outcomeIndex}: ${
              error instanceof Error ? error.message : String(error)
            }`
          );
        }
      }
    }
  }

  return `Pre-close LMSR sell sweep complete: scanned=${scanned}, eligible=${eligible}, sellsSubmitted=${sold}`;
};
