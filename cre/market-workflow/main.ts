import { CronCapability, EVMClient, HTTPCapability, getNetwork, handler, Runner, type Workflow } from "@chainlink/cre-sdk";
import { marketFactoryBalanceTopUp } from "./handlers/cronHandlers/topUpMarket";
import { resoloveEvent } from "./handlers/cronHandlers/resolve";
import { syncCanonicalPrice } from "./handlers/cronHandlers/syncPrice";
import { arbitrateUnsafeMarketHandler } from "./handlers/cronHandlers/arbitrage";
import { adjudicateExpiredDisputeWindows } from "./handlers/cronHandlers/disputeResolution";
import { syncManualReviewMarketsToFirebase } from "./handlers/cronHandlers/manualReviewSync";
import { authWorkflow, createEventHelper, createPredictionMarketEvent } from "./handlers/cronHandlers/marketCreation";
import { type Config } from "./Constant-variable/config";
import { processPendingWithdrawalsHandler } from "./handlers/cronHandlers/marketWithdrawal";
import { sponsorUserOpPolicyHandler } from "./handlers/httpHandlers/httpSponsorPolicy";
import { executeReportHttpHandler } from "./handlers/httpHandlers/httpExecuteReport";
import { revokeSessionHttpHandler } from "./handlers/httpHandlers/httpRevokeSession";
import { fiatCreditHttpHandler } from "./handlers/httpHandlers/httpFiatCredit";
import { ethCreditFromLogsHandler } from "./handlers/eventsHandler/ethCreditFromLogs";

/**
 * Topic hash for `EthReceived(address,uint256)` used to subscribe router deposit logs.
 */
const ETH_RECEIVED_EVENT_SIG = "0xe98f6e2bbf18d38ab3110207f18cc6cc79ca9fcd98fb75e8f5fdc7fc4f09d5e3";

/**
 * Maps configured chain selector names to EVM chain IDs used by policy filters.
 */
const toChainId = (chainName: string): number | null => {
  if (chainName.includes("arbitrum")) return 421614;
  if (chainName.includes("base")) return 84532;
  if (chainName === "ethereum-testnet-sepolia") return 11155111;
  return null;
};

/**
 * Converts 0x-prefixed hex values to base64 because CRE log triggers expect base64 input.
 */
const hexToBase64 = (hex: string): string => Buffer.from(hex.replace(/^0x/, ""), "hex").toString("base64");

/**
 * Builds the full workflow graph by composing cron, HTTP, and EVM log triggers.
 * Each trigger group is enabled only when its required config keys/policies are present.
 */
const initWorkflow = (config: Config) => {
  const cron = new CronCapability();
  const http = new HTTPCapability();
  const httpAuthorizedKeys = config.httpTriggerAuthorizedKeys || [];
  const httpExecutionAuthorizedKeys = config.httpExecutionAuthorizedKeys || [];
  const httpFiatCreditAuthorizedKeys = config.httpFiatCreditAuthorizedKeys || [];
  const hasHttpTriggerKeys = httpAuthorizedKeys.length > 0;
  const hasHttpExecutionTriggerKeys = httpExecutionAuthorizedKeys.length > 0;
  const hasHttpFiatCreditKeys = httpFiatCreditAuthorizedKeys.length > 0;
  const ethCreditPolicy = config.ethCreditPolicy;
  const hasEthCredit = Boolean(ethCreditPolicy?.enabled);

  /**
   * Periodic automation handlers executed on the configured cron schedule.
   */
  const cronWorkflows: Workflow<Config> = [
 //  handler(cron.trigger({ schedule: config.schedule }), resoloveEvent),
 // handler(cron.trigger({ schedule: config.schedule }), marketFactoryBalanceTopUp),
    
  //  handler(cron.trigger({ schedule: config.schedule }), createPredictionMarketEvent),
    //ABove reveiwed
    // handler(cron.trigger({ schedule: config.schedule }), processPendingWithdrawalsHandler),
   // handler(cron.trigger({ schedule: config.schedule }), syncCanonicalPrice),
    // handler(cron.trigger({ schedule: config.schedule }), arbitrateUnsafeMarketHandler),
    // handler(cron.trigger({ schedule: config.schedule }), adjudicateExpiredDisputeWindows),
    // handler(cron.trigger({ schedule: config.schedule }), syncManualReviewMarketsToFirebase),
    
  ];

  /**
   * Sponsored action policy endpoints: approval and session revocation.
   */
  const sponsorHttpWorkflows: Workflow<Config> = hasHttpTriggerKeys
    ? [
        handler(
          http.trigger({
            authorizedKeys: httpAuthorizedKeys,
          }),
          sponsorUserOpPolicyHandler
        ),
        handler(
          http.trigger({
            authorizedKeys: httpAuthorizedKeys,
          }),
          revokeSessionHttpHandler
        ),
      ]
    : [];

  /**
   * Execution endpoint that consumes prior approvals and forwards on-chain reports.
   */
  const executeHttpWorkflows: Workflow<Config> = hasHttpExecutionTriggerKeys
    ? [
        handler(
          http.trigger({
            authorizedKeys: httpExecutionAuthorizedKeys,
          }),
          executeReportHttpHandler
        ),
      ]
    : [];

  /**
   * Fiat credit endpoint for approved off-chain payment-to-router credit flows.
   */
  //fiat test working as planed 
  const fiatCreditHttpWorkflows: Workflow<Config> = hasHttpFiatCreditKeys
    ? [
        handler(
          http.trigger({
            authorizedKeys: httpFiatCreditAuthorizedKeys,
          }),
          fiatCreditHttpHandler
        ),
      ]
    : [];

  /**
   * Log-driven ETH credit handlers bound per configured router receiver address.
   */
  //Log reviewed working as planned
  const ethCreditLogWorkflows: Workflow<Config> = hasEthCredit
    ? config.evms
        .filter((evm) => {
          const chainId = toChainId(evm.chainName);
          return (
            chainId !== null
            && ethCreditPolicy?.supportedChainIds.includes(chainId)
            && Boolean(evm.routerReceiverAddress)
          );
        })
        .map((evm) => {
          const network = getNetwork({
            chainFamily: "evm",
            chainSelectorName: evm.chainName,
            isTestnet: true,
          });
          if (!network) {
            throw new Error(`Unknown chain name for eth log trigger: ${evm.chainName}`);
          }
          const evmClient = new EVMClient(network.chainSelector.selector);
          return handler(
            evmClient.logTrigger({
              addresses: [hexToBase64(evm.routerReceiverAddress as string)],
              topics: [
                { values: [hexToBase64(ETH_RECEIVED_EVENT_SIG)] },
                { values: [] },
                { values: [] },
                { values: [] },
              ],
            }),
            ethCreditFromLogsHandler
          );
        })
    : [];

  return [
    ...cronWorkflows,
    ...sponsorHttpWorkflows,
    ...executeHttpWorkflows,
    ...fiatCreditHttpWorkflows,
    ...ethCreditLogWorkflows,
  ];
};

/**
 * CRE entrypoint: initializes the runner and starts the configured workflow graph.
 */
export async function main() {
  const runner = await Runner.newRunner<Config>();
  await runner.run(initWorkflow);
}
export {
  authWorkflow,
  createEventHelper,
  createPredictionMarketEvent,
  syncCanonicalPrice,
  arbitrateUnsafeMarketHandler,
  adjudicateExpiredDisputeWindows,
  syncManualReviewMarketsToFirebase,
  marketFactoryBalanceTopUp,
  resoloveEvent,
  sponsorUserOpPolicyHandler,
  executeReportHttpHandler,
  revokeSessionHttpHandler,
  fiatCreditHttpHandler,
  ethCreditFromLogsHandler,
};
