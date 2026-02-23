import {
  EVMClient,
  TxStatus,
  bytesToHex,
  getNetwork,
  prepareReportRequest,
  type Runtime,
} from "@chainlink/cre-sdk";
import { encodeAbiParameters, parseAbiParameters } from "viem";
import { signUpWorkFlow } from "../firebase/firebase";
import { getFirestoreList } from "../firebase/doclist";
import { writeToFirestore } from "../firebase/write";
import { askGemeni } from "../gemini/uniqueEvent";
import { type GeminiResponse, type SignupNewUserResponse } from "../type";
import { type Config } from "../workflow/config";

export const authWorkflow = (runtime: Runtime<Config>): string => {
  const response: SignupNewUserResponse = signUpWorkFlow(runtime);
  runtime.log(`returned data:  ${response.localId}`);
  return `returned data:  ${response.expiresIn}`;
};

const txExplorer = (chainName: string, txHash: string): string => {
  if (chainName.includes("arbitrum")) {
    return `https://sepolia.arbiscan.io/tx/${txHash}`;
  }
  return `https://sepolia.etherscan.io/tx/${txHash}`;
};

const sendActionReport = (
  runtime: Runtime<Config>,
  evmConfig: Config["evms"][number],
  actionType: string,
  payload: `0x${string}`
): string => {
  const network = getNetwork({
    chainFamily: "evm",
    chainSelectorName: evmConfig.chainName,
    isTestnet: true,
  });

  if (!network) {
    throw new Error(`Unknown chain name: ${evmConfig.chainName}`);
  }

  const evmClient = new EVMClient(network.chainSelector.selector);
  const encodedReport = encodeAbiParameters(parseAbiParameters("string actionType, bytes payload"), [
    actionType,
    payload,
  ]);

  const reportResponse = runtime.report({
    ...prepareReportRequest(encodedReport),
  }).result();

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
    runtime.log(`[${evmConfig.chainName}] ${actionType} REVERTED: ${writeReportResult.errorMessage || "unknown"}`);
    throw new Error(`${actionType} failed on ${evmConfig.chainName}: ${writeReportResult.errorMessage}`);
  }

  const txHash = bytesToHex(writeReportResult.txHash || new Uint8Array(32));
  runtime.log(`[${evmConfig.chainName}] ${actionType} tx: ${txHash}`);
  runtime.log(`[${evmConfig.chainName}] ${txExplorer(evmConfig.chainName, txHash)}`);
  return txHash;
};

export function createPredictionMarketEvent(runtime: Runtime<Config>): string {
  const authInfo: SignupNewUserResponse = signUpWorkFlow(runtime);
  const documents = getFirestoreList(runtime, authInfo.idToken);
  const hasMore = documents.length === 31;
  const events = hasMore ? documents.slice(0, 30) : documents;
  const filteredEvent =
    events.length > 0
      ? events.map((event: any) => ({
          question: event.question,
          resolutionTime: event.resolutionTime,
        }))
      : [];

  const eventInfo: GeminiResponse = askGemeni(runtime, filteredEvent);
  const closeTime = BigInt(Math.floor(new Date(eventInfo.closing_date).getTime() / 1000));
  const resolutionTime = BigInt(Math.floor(new Date(eventInfo.resolution_date).getTime() / 1000));

  runtime.log(`returned data:  ${documents.length}, ${54}, Data from db`);
  writeToFirestore(runtime, authInfo.idToken, eventInfo.event_name, resolutionTime.toString(), "");
  runtime.log(`id token: ${authInfo.idToken}`);

  const marketFactoryCall = runtime.config.evms.map((evmConfig) => {
    const createPayload = encodeAbiParameters(
      parseAbiParameters("string question, uint256 closeTime, uint256 resolutionTime"),
      [eventInfo.event_name, closeTime, resolutionTime]
    );

    sendActionReport(runtime, evmConfig, "createMarket", createPayload);
    return `[${evmConfig.chainName}] ok`;
  });

  return marketFactoryCall.join(", ");
}

export const createEventHelper = (runtime: Runtime<Config>): string => {
  const eventName = "Will BTC price be above $3,000 in 1 hour?";
  const closeTime = BigInt(Math.floor(Date.now() / 1000) + 30 * 60);
  const resolutionTime = BigInt(Math.floor(Date.now() / 1000) + 45 * 60);

  runtime.config.evms.map((evmConfig) => {
    const createPayload = encodeAbiParameters(
      parseAbiParameters("string question, uint256 closeTime, uint256 resolutionTime"),
      [eventName, closeTime, resolutionTime]
    );
    sendActionReport(runtime, evmConfig, "createMarket", createPayload);
    return `[${evmConfig.chainName}] ok`;
  });

  return "";
};
