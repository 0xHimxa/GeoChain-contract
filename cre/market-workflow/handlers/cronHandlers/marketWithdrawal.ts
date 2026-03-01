import {
  EVMClient,
 
  bytesToHex,
  getNetwork,
  prepareReportRequest,
  TxStatus,
  type Runtime,
} from "@chainlink/cre-sdk";
import {

  encodeAbiParameters,
 
  parseAbiParameters,
} from "viem";

import {

  PROCESS_PENDING_WITHDRAWALS_ACTION,
  sender,
  type Config,
 
  WITHDRAW_BATCH_SIZE,
} from "../../Constant-variable/config";


/**
 * Processes queued post-resolution withdrawals on each configured market factory.
 * Sends a bounded batch request so the queue can be drained incrementally without exceeding gas limits.
 */
export const processPendingWithdrawalsHandler = (runtime: Runtime<Config>): string => {
  let attemptedWrites = 0;
  let successfulWrites = 0;

  for (const evmConfig of runtime.config.evms) {
    const network = getNetwork({
      chainFamily: "evm",
      chainSelectorName: evmConfig.chainName,
      isTestnet: true,
    });

    if (!network) {
      throw new Error(`Unknown chain name: ${evmConfig.chainName}`);
    }

    const evmClient = new EVMClient(network.chainSelector.selector);
    const payload = encodeAbiParameters(parseAbiParameters("uint256 maxItems"), [WITHDRAW_BATCH_SIZE]);
    const encodedReport = encodeAbiParameters(parseAbiParameters("string actionType, bytes payload"), [
      PROCESS_PENDING_WITHDRAWALS_ACTION,
      payload,
    ]);
    const reportResponse = runtime.report({
      ...prepareReportRequest(encodedReport),
    }).result();

    attemptedWrites += 1;
    const writeReportResult = evmClient
      .writeReport(runtime, {
        receiver: evmConfig.marketFactoryAddress,
        report: reportResponse,
        gasConfig: {
          gasLimit: "10000000",
        },
      })
      .result();

    if (writeReportResult.txStatus === TxStatus.REVERTED) {
      runtime.log(
        `[${evmConfig.chainName}] ${PROCESS_PENDING_WITHDRAWALS_ACTION} REVERTED: ${writeReportResult.errorMessage || "unknown"}`
      );
      continue;
    }

    const txHash = bytesToHex(writeReportResult.txHash || new Uint8Array(32));
    runtime.log(`[${evmConfig.chainName}] ${PROCESS_PENDING_WITHDRAWALS_ACTION} tx: ${txHash}`);
    successfulWrites += 1;
  }

  return `pending-withdrawal batch writes=${successfulWrites}/${attemptedWrites}, batchSize=${WITHDRAW_BATCH_SIZE.toString()}`;
};
