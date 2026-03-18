import { CronCapability, handler, Runner, type Workflow } from "@chainlink/cre-sdk";
import { marketFactoryBalanceTopUp } from "./handlers/cronHandlers/topUpMarket";
import { resoloveEvent } from "./handlers/cronHandlers/resolve";
import { syncCanonicalPrice } from "./handlers/cronHandlers/syncPrice";
import { arbitrateUnsafeMarketHandler } from "./handlers/cronHandlers/arbitrage";
import { adjudicateExpiredDisputeWindows } from "./handlers/cronHandlers/disputeResolution";
import { syncManualReviewMarketsToFirebase } from "./handlers/cronHandlers/manualReviewSync";
import { authWorkflow, createEventHelper, createPredictionMarketEvent } from "./handlers/cronHandlers/marketCreation";
import { type Config } from "./Constant-variable/config";
import { processPendingWithdrawalsHandler } from "./handlers/cronHandlers/marketWithdrawal";
import { preCloseLmsrSellHandler } from "./handlers/cronHandlers/preCloseLmsrSell";

/**
 * Creates the market cron workflow graph from runtime config.
 */
const initWorkflow = (config: Config) => {
  const cron = new CronCapability();

  /**
   * Periodic automation handlers executed on the configured cron schedule.
   */
  const cronWorkflows: Workflow<Config> = [
   handler(cron.trigger({ schedule: config.schedule }), resoloveEvent),
handler(cron.trigger({ schedule: config.schedule }), marketFactoryBalanceTopUp),
    
    handler(cron.trigger({ schedule: config.schedule }), createPredictionMarketEvent),
    
     handler(cron.trigger({ schedule: config.schedule }), processPendingWithdrawalsHandler),
    handler(cron.trigger({ schedule: config.schedule }), preCloseLmsrSellHandler),
    handler(cron.trigger({ schedule: config.schedule }), syncCanonicalPrice),
    handler(cron.trigger({ schedule: config.schedule }), arbitrateUnsafeMarketHandler),
     handler(cron.trigger({ schedule: config.schedule }), adjudicateExpiredDisputeWindows),
     handler(cron.trigger({ schedule: config.schedule }), syncManualReviewMarketsToFirebase),
    
  ];

  return cronWorkflows;
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
  processPendingWithdrawalsHandler,
  preCloseLmsrSellHandler,
};
