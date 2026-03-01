import { CronCapability, EVMClient, HTTPCapability, getNetwork, handler, Runner, type Workflow } from "@chainlink/cre-sdk";
import { marketFactoryBalanceTopUp } from "./handlers/cronHandlers/topUpMarket";
import { resoloveEvent } from "./handlers/cronHandlers/resolve";
import { syncCanonicalPrice } from "./handlers/cronHandlers/syncPrice";
import { arbitrateUnsafeMarketHandler } from "./handlers/cronHandlers/arbitrage";
import { authWorkflow, createEventHelper, createPredictionMarketEvent } from "./handlers/cronHandlers/marketCreation";
import { type Config } from "./Constant-variable/config";
import { processPendingWithdrawalsHandler } from "./handlers/cronHandlers/marketWithdrawal";
import { sponsorUserOpPolicyHandler } from "./handlers/httpHandlers/httpSponsorPolicy";
import { executeReportHttpHandler } from "./handlers/httpHandlers/httpExecuteReport";
import { revokeSessionHttpHandler } from "./handlers/httpHandlers/httpRevokeSession";
import { fiatCreditHttpHandler } from "./handlers/httpHandlers/httpFiatCredit";
import { ethCreditFromLogsHandler } from "./handlers/eventsHandler/ethCreditFromLogs";

const ETH_RECEIVED_EVENT_SIG = "0xe98f6e2bbf18d38ab3110207f18cc6cc79ca9fcd98fb75e8f5fdc7fc4f09d5e3";

const toChainId = (chainName: string): number | null => {
  if (chainName.includes("arbitrum")) return 421614;
  if (chainName.includes("base")) return 84532;
  if (chainName === "ethereum-testnet-sepolia") return 11155111;
  return null;
};

const hexToBase64 = (hex: string): string => Buffer.from(hex.replace(/^0x/, ""), "hex").toString("base64");

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

  const cronWorkflows: Workflow<Config> = [
    handler(cron.trigger({ schedule: config.schedule }), resoloveEvent),
    handler(cron.trigger({ schedule: config.schedule }), marketFactoryBalanceTopUp),
     handler(cron.trigger({ schedule: config.schedule }), createPredictionMarketEvent),
     handler(cron.trigger({ schedule: config.schedule }), processPendingWithdrawalsHandler),
    handler(cron.trigger({ schedule: config.schedule }), createEventHelper),
     handler(cron.trigger({ schedule: config.schedule }), authWorkflow),
     handler(cron.trigger({ schedule: config.schedule }), syncCanonicalPrice),
     handler(cron.trigger({ schedule: config.schedule }), arbitrateUnsafeMarketHandler),
     handler(cron.trigger({ schedule: config.schedule }), marketFactoryBalanceTopUp),
  ];
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

export async function main() {
  const runner = await Runner.newRunner<Config>();
  await runner.run(initWorkflow);
}

// Keep exports available for quick handler switching in local workflows.
export {
  authWorkflow,
  createEventHelper,
  createPredictionMarketEvent,
  syncCanonicalPrice,
  arbitrateUnsafeMarketHandler,
  marketFactoryBalanceTopUp,
  resoloveEvent,
  sponsorUserOpPolicyHandler,
  executeReportHttpHandler,
  revokeSessionHttpHandler,
  fiatCreditHttpHandler,
  ethCreditFromLogsHandler,
};
