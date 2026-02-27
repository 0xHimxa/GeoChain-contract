import { CronCapability, HTTPCapability, handler, Runner, type Workflow } from "@chainlink/cre-sdk";
import { marketFactoryBalanceTopUp } from "./handlers/topUpMarket";
import { resoloveEvent } from "./handlers/resolve";
import { syncCanonicalPrice } from "./handlers/syncPrice";
import { arbitrateUnsafeMarketHandler } from "./handlers/arbitrage";
import { authWorkflow, createEventHelper, createPredictionMarketEvent } from "./handlers/marketCreation";
import { type Config } from "./Constant-variable/config";
import {processPendingWithdrawalsHandler} from "./handlers/marketWithdrawal";
import { sponsorUserOpPolicyHandler } from "./handlers/httpSponsorPolicy";
import { executeReportHttpHandler } from "./handlers/httpExecuteReport";
import { revokeSessionHttpHandler } from "./handlers/httpRevokeSession";
import { fiatCreditHttpHandler } from "./handlers/httpFiatCredit";

const initWorkflow = (config: Config) => {
  const cron = new CronCapability();
  const http = new HTTPCapability();
  const httpAuthorizedKeys = config.httpTriggerAuthorizedKeys || [];
  const httpExecutionAuthorizedKeys = config.httpExecutionAuthorizedKeys || [];
  const httpFiatCreditAuthorizedKeys = config.httpFiatCreditAuthorizedKeys || [];
  const hasHttpTriggerKeys = httpAuthorizedKeys.length > 0;
  const hasHttpExecutionTriggerKeys = httpExecutionAuthorizedKeys.length > 0;
  const hasHttpFiatCreditKeys = httpFiatCreditAuthorizedKeys.length > 0;

  const cronWorkflows: Workflow<Config> = [
    handler(cron.trigger({ schedule: config.schedule }), resoloveEvent),
   // handler(cron.trigger({ schedule: config.schedule }), marketFactoryBalanceTopUp),
    // handler(cron.trigger({ schedule: config.schedule }), createPredictionMarketEvent),
    // handler(cron.trigger({ schedule: config.schedule }), processPendingWithdrawalsHandler),
   //  handler(cron.trigger({ schedule: config.schedule }), createEventHelper),
    // handler(cron.trigger({ schedule: config.schedule }), authWorkflow),
    // handler(cron.trigger({ schedule: config.schedule }), syncCanonicalPrice),
    // handler(cron.trigger({ schedule: config.schedule }), arbitrateUnsafeMarketHandler),
    // handler(cron.trigger({ schedule: config.schedule }), marketFactoryBalanceTopUp),
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

  return [...cronWorkflows, ...sponsorHttpWorkflows, ...executeHttpWorkflows, ...fiatCreditHttpWorkflows];
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
};
