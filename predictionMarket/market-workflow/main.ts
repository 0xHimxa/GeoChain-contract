import {
  CronCapability,
  handler,
  Runner,
  type Runtime,
  getNetwork,
  EVMClient,
  encodeCallMsg,
  bytesToHex,
  prepareReportRequest,

} from "@chainlink/cre-sdk";
import { decodeErrorResult, encodeFunctionData, decodeFunctionResult,encodeAbiParameters, parseAbiParameters } from "viem";
//import { OutcomeTokenAbi } from "./outComeToken";
import { MarketFactoryAbi } from "./contractsAbi/marketFactory";
//import { PredictionMarketAbi } from "./predictionMarket";
import {signUpWorkFlow,SignupNewUserResponse} from "./firebase";

import {askGemeni} from "./createEventPrompt";
import {type GeminiResponse} from "./type";




const sender = "0xA85926f9598AA43A2D8f24246B5e7886C4A5FeEc";


type EvmConfig = {
  marketFactoryAddress: string;
  chainName: string;
};

export type Config = {
  schedule: string;
  evms: EvmConfig[];
};


//this triger will check the market factory that create event, fix arbtrage balance after cartain time
//if the balance is below certain amount fund it
const marketFactoryBalanceTopUp= (runtime: Runtime<Config>): string => {

const marketFactoryCallData = encodeFunctionData({
  abi: MarketFactoryAbi,
  functionName: "getMarketFactoryCollateralBalance"
});


 const marketFactoryAddliquidityCall = encodeFunctionData({
  abi: MarketFactoryAbi,
  functionName: "addLiquidityToFactory"
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
   const contractBalance:any =  decodeFunctionResult({
    abi: MarketFactoryAbi,
    functionName: "getMarketFactoryCollateralBalance",
    data: bytesToHex(callResult.data),
  });


if(contractBalance <= 100000000000){



  const actionType = "addLiquidityToFactory";
  
  // For 'mint', the payload is ignored, so we send an empty hex string '0x'
  const dummyPayload = "0x"; 

  // Encode as (string, bytes)
  const encodedReport = encodeAbiParameters(
    parseAbiParameters('string actionType, bytes payload'),
    [actionType, dummyPayload]
  );

  // Generate the consensus report
  const reportResponse =  runtime.report({
    ...prepareReportRequest(encodedReport),
  }).result();



    // Step 2: Submit the report to the consumer contract
  const writeReportResult = evmClient
    .writeReport(runtime, {
      receiver: evmConfig.marketFactoryAddress,
      report: reportResponse,
    })
    .result()

  runtime.log("Waiting for write report response")

  const txHash = bytesToHex(writeReportResult.txHash || new Uint8Array(32));
  runtime.log(`Write report transaction succeeded: ${txHash}`);
  runtime.log(`View transaction at https://sepolia.etherscan.io/tx/${txHash}`);
  return 

}
  return contractBalance;


});







  

runtime.log(`returned data:  arbturm one chain`);


  return `Hello world! ${balances[0]} ${balances[1]}`;
};



const authWorkflow = (runtime: Runtime<Config>): string => {

  const response:SignupNewUserResponse = signUpWorkFlow(runtime);

runtime.log(`returned data:  ${response.localId}`);

return `returned data:  ${response.expiresIn}`;



}


const gemeniEvent = (runtime: Runtime<Config>): string => {

  const response:GeminiResponse = askGemeni(runtime);

runtime.log(`returned data:  ${response.event_name}: ${response.category}: ${response.description}: ${response.options}: ${response.closing_date}: ${response.resolution_date}: ${response.verification_source}: ${response.trending_reason}`);


return `returned data:  ${response.event_name}`;


}



const initWorkflow = (config: Config) => {
  const cron = new CronCapability();

  return [handler(cron.trigger({ schedule: config.schedule }), gemeniEvent)];
};

export async function main() {
  const runner = await Runner.newRunner<Config>();
  await runner.run(initWorkflow);
}
