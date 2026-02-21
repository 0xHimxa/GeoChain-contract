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
  TxStatus,
} from "@chainlink/cre-sdk";
import { decodeErrorResult, encodeFunctionData, decodeFunctionResult,encodeAbiParameters, parseAbiParameters } from "viem";
//import { OutcomeTokenAbi } from "./outComeToken";
import { MarketFactoryAbi } from "./contractsAbi/marketFactory";
import { PredictionMarketAbi } from "./contractsAbi/predictionMarket";
import {signUpWorkFlow} from "./firebase/firebase";

import {askGemeni} from "./gemini/uniqueEvent";
import {type GeminiResponse, type SignupNewUserResponse} from "./type";
import {askGemeniResolve} from "./gemini/resolveEvent";

import { writeToFirestore } from "./firebase/write";
import { getFirestoreList} from "./firebase/doclist";






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
      gasConfig: {
        gasLimit: "10000000",
      },
    })
    .result()

  runtime.log("Waiting for write report response")

  if (writeReportResult.txStatus === TxStatus.REVERTED) {
    runtime.log(`[${evmConfig.chainName}] addLiquidity REVERTED: ${writeReportResult.errorMessage || "unknown"}`);
    throw new Error(`addLiquidity failed on ${evmConfig.chainName}: ${writeReportResult.errorMessage}`);
  }

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

 // const response:GeminiResponse = askGemeni(runtime);

//runtime.log(`returned data:  ${response.event_name}: ${response.category}: ${response.description}: ${response.options}: ${response.closing_date}: ${response.resolution_date}: ${response.verification_source}: ${response.trending_reason}`);


return `returned data:`;


}


const geminiReslove = (runtime: Runtime<Config>): string => {

  const testQuestion = {
    question: "will FIFA world Cup be played in  2026",
    resolutionTime: `${new Date().toISOString()}`
  }


  



const response = askGemeniResolve(runtime,testQuestion);

runtime.log(`returned data:  ${response.result}: ${response.confidence}: ${response.source_url}`);


return `returned data:  ${response.result}`;



}


const geminiDuplicateCheck = (runtime: Runtime<Config>): string => {

const prevQuestion = [
    {
      question: "Will Bitcoin reach $100,000 by December 31, 2025?",
      resolutionTime: "2025-11-10T14:22:00Z"
    }
  
  ]
  const authInfo:SignupNewUserResponse = signUpWorkFlow(runtime);


const eventName = "Will BTC price be above $3,000 in 1 hour?";
const closeTime = BigInt(Math.floor(Date.now() / 1000) + 5 * 60);
const resolutionTime = BigInt(Math.floor(Date.now() / 1000) + 20 * 60);
runtime.log(` id token: ${authInfo.idToken} `);
    // writeToFirestore(runtime,authInfo.idToken,eventName,resolutionTime.toString(),'');

  const documents = getFirestoreList(runtime,authInfo.idToken);
  
  //const response = askGemeni(runtime,prevQuestion);
  const hasMore = documents.length === 31;

const events = hasMore ? documents.slice(0, 30) : documents;
  runtime.log(`returned data:  ${documents.length}`);

  return `returned data: `

  }   


  function createPredictionMarketEvent(runtime: Runtime<Config>): string {
 
 
  const authInfo:SignupNewUserResponse = signUpWorkFlow(runtime);
  const documents = getFirestoreList(runtime,authInfo.idToken);

const hasMore = documents.length === 31;

const events = hasMore ? documents.slice(0, 30) : documents;
const filteredEvent = events.length > 0 ?  events.map((event:any)=>({
  question: event.question,
  resolutionTime: event.resolutionTime
})) : []; 

   const eventInfo:GeminiResponse = askGemeni(runtime,filteredEvent);

 const closeTime = BigInt(Math.floor(new Date(eventInfo.closing_date).getTime() / 1000));
const resolutionTime = BigInt(Math.floor(new Date(eventInfo.resolution_date).getTime() / 1000));

runtime.log(`returned data:  ${documents.length}, ${54}, Data from db`);

    writeToFirestore(runtime,authInfo.idToken,eventInfo.event_name,resolutionTime.toString(),'');

//const eventName = eventInfo.event_name;


  
//const eventName = "Will BTC price be above $3,000 in 1 hour?";
//const closeTime = BigInt(Math.floor(Date.now() / 1000) + 2 * 60);
//const resolutionTime = BigInt(Math.floor(Date.now() / 1000) + 4 * 60);
runtime.log(` id token: ${authInfo.idToken} `);


const txExplorer = (chainName: string, txHash: string): string => {
  if (chainName.includes("arbitrum")) {
    return `https://sepolia.arbiscan.io/tx/${txHash}`;
  }
  return `https://sepolia.etherscan.io/tx/${txHash}`;
};


const marketFactoryCall = runtime.config.evms.map((evmConfig) => {
  const network = getNetwork({
    chainFamily: "evm",
    chainSelectorName: evmConfig.chainName,
    isTestnet: true,
  });

  if (!network) {
    throw new Error(`Unknown chain name: ${evmConfig.chainName}`);
  }

  const evmClient = new EVMClient(network.chainSelector.selector);

  const sendActionReport = (actionType: string, payload: `0x${string}`) => {
    const encodedReport = encodeAbiParameters(
      parseAbiParameters("string actionType, bytes payload"),
      [actionType, payload]
    );

    const reportResponse = runtime.report({
      ...prepareReportRequest(encodedReport),
    }).result();

    const writeReportResult = evmClient.writeReport(runtime, {
      receiver: evmConfig.marketFactoryAddress,
      report: reportResponse,
      gasConfig: {
        gasLimit: "10000000",
      },
    }).result();

    if (writeReportResult.txStatus === TxStatus.REVERTED) {
      runtime.log(`[${evmConfig.chainName}] ${actionType} REVERTED: ${writeReportResult.errorMessage || "unknown"}`);
      throw new Error(`${actionType} failed on ${evmConfig.chainName}: ${writeReportResult.errorMessage}`);
    }

    const txHash = bytesToHex(writeReportResult.txHash || new Uint8Array(32));
    runtime.log(`[${evmConfig.chainName}] ${actionType} tx: ${txHash}`);
    runtime.log(`[${evmConfig.chainName}] ${txExplorer(evmConfig.chainName, txHash)}`);
    return txHash;
  };

  const createPayload = encodeAbiParameters(
    parseAbiParameters("string question, uint256 closeTime, uint256 resolutionTime"),
    [eventInfo.event_name, closeTime, resolutionTime]
  );

  sendActionReport("createMarket", createPayload);

  return `[${evmConfig.chainName}] ok`;
}); // 

return marketFactoryCall.join(", ");
} 




const resoloveEvent = (runtime: Runtime<Config>): string => {




 

  const marketFactoryCallData = encodeFunctionData({
  abi: MarketFactoryAbi,
  functionName: "getActiveEventList"
});


  const PredictionCallData = encodeFunctionData({
  abi: PredictionMarketAbi,
  functionName: "checkResolutionTime"
});



  const sepoConfig = runtime.config.evms[0];
  
  const network = getNetwork({
    chainFamily: "evm",
    chainSelectorName: sepoConfig.chainName,
    isTestnet: true,
  });
  
  if (!network) {
    throw new Error(`Unknown chain name: ${sepoConfig.chainName}`);
  }
  const evmClient = new EVMClient(network.chainSelector.selector);

  // Perform the call
  const callResult = evmClient.callContract(runtime, {
    call: encodeCallMsg({
      from: sender,
      to: sepoConfig.marketFactoryAddress as `0x${string}`,
      data: marketFactoryCallData,
    }),
  }).result();



   const activeEventList:any =  decodeFunctionResult({
    abi: MarketFactoryAbi,
    functionName: "getActiveEventList",
    data: bytesToHex(callResult.data),
  });

 
  if(activeEventList.length == 0) return 'No Active Events'


 activeEventList.forEach((eventAddress:any) => {

  const callResult = evmClient.callContract(runtime, {
    call: encodeCallMsg({
      from: sender,
      to: eventAddress as `0x${string}`,
      data: PredictionCallData,
    }),
  }).result();



   const readyForResolve:any =  decodeFunctionResult({
    abi: PredictionMarketAbi,
    functionName: "checkResolutionTime",
    data: bytesToHex(callResult.data),
  });



  if(readyForResolve){

    const actionType = "ResolveMarket";

    // Step 1: Read the market's question from the contract
    const questionCallData = encodeFunctionData({
      abi: PredictionMarketAbi,
      functionName: "s_question",
    });
    const questionResult = evmClient.callContract(runtime, {
      call: encodeCallMsg({
        from: sender,
        to: eventAddress as `0x${string}`,
        data: questionCallData,
      }),
    }).result();
    const marketQuestion: any = decodeFunctionResult({
      abi: PredictionMarketAbi,
      functionName: "s_question",
      data: bytesToHex(questionResult.data),
    });

    // Step 2: Read the market's resolutionTime from the contract
    const rtCallData = encodeFunctionData({
      abi: PredictionMarketAbi,
      functionName: "resolutionTime",
    });
    const rtResult = evmClient.callContract(runtime, {
      call: encodeCallMsg({
        from: sender,
        to: eventAddress as `0x${string}`,
        data: rtCallData,
      }),
    }).result();
    const resTime: any = decodeFunctionResult({
      abi: PredictionMarketAbi,
      functionName: "resolutionTime",
      data: bytesToHex(rtResult.data),
    });

    runtime.log(`Market question: ${marketQuestion}, resolutionTime: ${resTime}`);

    // Step 3: Ask Gemini AI for resolution determination
    const geminiResponse = askGemeniResolve(runtime, {
      question: marketQuestion as string,
      resolutionTime: new Date(Number(resTime) * 1000).toISOString(),
    });

    runtime.log(`Gemini resolution: result=${geminiResponse.result}, confidence=${geminiResponse.confidence}, source_url=${geminiResponse.source_url}`);

    // Step 4: Map Gemini result to Solidity Resolution enum values
    // Resolution enum: 0=Unset, 1=Yes, 2=No, 3=Inconclusive
    const resolutionMap: Record<string, number> = { YES: 1, NO: 2, INCONCLUSIVE: 3 };
   const resolution = resolutionMap[geminiResponse.result] ?? 3;

   

    // Skip sending if source_url is empty (contract requires non-empty proofUrl)
    if (!geminiResponse.source_url || geminiResponse.source_url.length === 0) {
      runtime.log(`Skipping resolve for ${eventAddress}: Gemini returned empty source_url`);
      return;
    }

    // Step 5: Encode the proper payload as (uint8 outcome, string proofUrl)
    const resolvePayload = encodeAbiParameters(
      parseAbiParameters('uint8 outcome, string proofUrl'),
      [resolution, geminiResponse.source_url]
    );

    // Step 6: Encode the full report as (string actionType, bytes payload)
    const encodedReport = encodeAbiParameters(
      parseAbiParameters('string actionType, bytes payload'),
      [actionType, resolvePayload]
    );

    // Step 7: Generate the consensus report
    const reportResponse = runtime.report({
      ...prepareReportRequest(encodedReport),
    }).result();

    // Step 8: Submit the report to the market contract
     const writeReportResult = evmClient
       .writeReport(runtime, {
         receiver: eventAddress as `0x${string}`,
         report: reportResponse,
        gasConfig: {
          gasLimit: "10000000",
         },
       })
       .result();

    runtime.log("Waiting for write report response");

    if (writeReportResult.txStatus === TxStatus.REVERTED) {
    runtime.log(`[${sepoConfig.chainName}] ResolveMarket REVERTED for ${eventAddress}: ${writeReportResult.errorMessage || "unknown"}`);
      throw new Error(`ResolveMarket failed on ${sepoConfig.chainName}: ${writeReportResult.errorMessage}`);
    }

    const txHash = bytesToHex(writeReportResult.txHash || new Uint8Array(32));
    runtime.log(`ResolveMarket tx succeeded for ${eventAddress}: ${txHash}`);
    runtime.log(`View transaction at https://sepolia.etherscan.io/tx/${txHash}`);

  }

  runtime.log(`ready to be resolve ${readyForResolve}`)

 })

return `${activeEventList.length}`
}



























const initWorkflow = (config: Config) => {
  const cron = new CronCapability();

  return [handler(cron.trigger({ schedule: config.schedule }),  resoloveEvent)];
};

export async function main() {
  const runner = await Runner.newRunner<Config>();
  await runner.run(initWorkflow);
}
