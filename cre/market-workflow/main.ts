import { CronCapability, handler, Runner } from "@chainlink/cre-sdk";
import {
  arbitrateUnsafeMarketHandler,
  resoloveEvent,
  syncCanonicalPrice,
  marketFactoryBalanceTopUp,
} from "./handlers/maintenance";
import { authWorkflow, createEventHelper, createPredictionMarketEvent } from "./handlers/marketCreation";
import { type Config } from "./Constant-variable/config";

const initWorkflow = (config: Config) => {
  const cron = new CronCapability();

  return [
    handler(cron.trigger({ schedule: config.schedule }), resoloveEvent),
    // handler(cron.trigger({ schedule: config.schedule }), createPredictionMarketEvent),
    // handler(cron.trigger({ schedule: config.schedule }), createEventHelper),
    // handler(cron.trigger({ schedule: config.schedule }), authWorkflow),
    // handler(cron.trigger({ schedule: config.schedule }), syncCanonicalPrice),
    // handler(cron.trigger({ schedule: config.schedule }), arbitrateUnsafeMarketHandler),
    // handler(cron.trigger({ schedule: config.schedule }), marketFactoryBalanceTopUp),
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
};
