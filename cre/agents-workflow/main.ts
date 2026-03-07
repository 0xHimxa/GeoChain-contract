import { HTTPCapability, handler, Runner, type Workflow } from "@chainlink/cre-sdk";
import { type Config } from "./Constant-variable/config";
import { agentPlanTradeHttpHandler } from "./handlers/httpHandlers/httpAgentPlanTrade";
import { agentSponsorTradeHttpHandler } from "./handlers/httpHandlers/httpAgentSponsorTrade";
import { agentExecuteTradeHttpHandler } from "./handlers/httpHandlers/httpAgentExecuteTrade";
import { agentRevokeHttpHandler } from "./handlers/httpHandlers/httpAgentRevoke";

/**
 * Builds the dedicated agent workflow graph.
 * Agent endpoints intentionally use a separate authorized-key set so trading automation can be
 * isolated from the broader market-operations workflow.
 */
export const initWorkflow = (config: Config): Workflow<Config> => {
  const http = new HTTPCapability();
  const httpAuthorizedKeys = config.httpTriggerAuthorizedKeys || [];
  const httpAgentAuthorizedKeys = config.httpAgentAuthorizedKeys || httpAuthorizedKeys;
  const hasHttpAgentKeys = httpAgentAuthorizedKeys.length > 0;

  const agentHttpWorkflows: Workflow<Config> = hasHttpAgentKeys
    ? [
        handler(
          http.trigger({ authorizedKeys: httpAgentAuthorizedKeys }),
          agentPlanTradeHttpHandler
        ),
        handler(
          http.trigger({ authorizedKeys: httpAgentAuthorizedKeys }),
          agentSponsorTradeHttpHandler
        ),
        handler(
          http.trigger({ authorizedKeys: httpAgentAuthorizedKeys }),
          agentExecuteTradeHttpHandler
        ),
        handler(
          http.trigger({ authorizedKeys: httpAgentAuthorizedKeys }),
          agentRevokeHttpHandler
        ),
      ]
    : [];

  return [...agentHttpWorkflows];
};

export async function main() {
  const runner = await Runner.newRunner<Config>();
  await runner.run(initWorkflow);
}
