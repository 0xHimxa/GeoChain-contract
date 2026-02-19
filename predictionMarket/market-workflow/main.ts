import {
  CronCapability,
  handler,
  Runner,
  type Runtime,
  getNetwork,
  EVMClient,
  encodeCallMsg,
  bytesToHex,

} from "@chainlink/cre-sdk";
import { decodeErrorResult, encodeFunctionData, decodeFunctionResult } from "viem";
//import { OutcomeTokenAbi } from "./outComeToken";
import { MarketFactoryAbi } from "./contractsAbi/marketFactory";
//import { PredictionMarketAbi } from "./predictionMarket";




const sender = "0xA85926f9598AA43A2D8f24246B5e7886C4A5FeEc";


type EvmConfig = {
  marketFactoryAddress: string;
  chainName: string;
};

type Config = {
  schedule: string;
  evms: EvmConfig[];
};

const onCronTrigger = (runtime: Runtime<Config>): string => {

const marketFactoryCallData = encodeFunctionData({
  abi: MarketFactoryAbi,
  functionName: "getMarketFactoryCollateralBalance"
});


const balances = runtime.config.evms.map((evmConfig) => {
  const network = getNetwork({
    chainFamily: "evm",
    chainSelectorName: evmConfig.chainName,
    isTestnet: true,
  });

  if (!network) {
    throw new Error(`Unknown chain name: ${evmConfig.chainName}`);
  }

  const evmClient = new EVMClient(network.chainSelector.selector);

  // Perform the call
  const callResult = evmClient.callContract(runtime, {
    call: encodeCallMsg({
      from: sender,
      to: evmConfig.marketFactoryAddress as `0x${string}`,
      data: marketFactoryCallData,
    }),
  }).result();

  // Decode and return the data
  return decodeFunctionResult({
    abi: MarketFactoryAbi,
    functionName: "getMarketFactoryCollateralBalance",
    data: bytesToHex(callResult.data),
  });
});

// 2. Access your data by index
const factoryBalanceDecode = balances[0];
const ab1factroyBalanceDecode = balances[1];

  

runtime.log(`returned data:  arbturm one chain`);


  return `Hello world! ${factoryBalanceDecode}  ${ab1factroyBalanceDecode}`;
};

const initWorkflow = (config: Config) => {
  const cron = new CronCapability();

  return [handler(cron.trigger({ schedule: config.schedule }), onCronTrigger)];
};

export async function main() {
  const runner = await Runner.newRunner<Config>();
  await runner.run(initWorkflow);
}
