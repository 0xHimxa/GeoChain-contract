import { EVMClient, HTTPCapability, getNetwork, handler, Runner, type Workflow } from "@chainlink/cre-sdk";
import { type Config } from "./Constant-variable/config";
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
  const http = new HTTPCapability();
  const httpAuthorizedKeys = config.httpTriggerAuthorizedKeys || [];
  const httpExecutionAuthorizedKeys = config.httpExecutionAuthorizedKeys || [];
  const httpFiatCreditAuthorizedKeys = config.httpFiatCreditAuthorizedKeys || [];
  const hasHttpTriggerKeys = httpAuthorizedKeys.length > 0;
  const hasHttpExecutionTriggerKeys = httpExecutionAuthorizedKeys.length > 0;
  const hasHttpFiatCreditKeys = httpFiatCreditAuthorizedKeys.length > 0;
  const ethCreditPolicy = config.ethCreditPolicy;
  const hasEthCredit = Boolean(ethCreditPolicy?.enabled);

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

export {
  sponsorUserOpPolicyHandler,
  executeReportHttpHandler,
  revokeSessionHttpHandler,
  fiatCreditHttpHandler,
  ethCreditFromLogsHandler,
};
