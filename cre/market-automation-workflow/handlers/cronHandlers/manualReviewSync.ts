import { bytesToHex, encodeCallMsg, type Runtime } from "@chainlink/cre-sdk";
import { decodeFunctionResult, encodeFunctionData } from "viem";
import { type Config, sender } from "../../Constant-variable/config";
import { isHubFactoryConfig } from "../utils/isHub";
import { signUpWorkFlow } from "../../firebase/signUp";
import { upsertManualReviewMarketToFirestore } from "../../firebase/write";
import { createEvmClient } from "../utils/evmUtils";

const factoryAbi = [
  {
    type: "function",
    name: "getManualReviewEventList",
    inputs: [],
    outputs: [{ name: "", type: "address[]" }],
    stateMutability: "view",
  },
] as const;

const marketAbi = [
  {
    type: "function",
    name: "getDisputeResolutionSnapshot",
    inputs: [],
    outputs: [
      { name: "marketState", type: "uint8" },
      { name: "currentProposedResolution", type: "uint8" },
      { name: "isResolutionDisputed", type: "bool" },
      { name: "currentDisputeDeadline", type: "uint256" },
      { name: "currentResolutionTime", type: "uint256" },
      { name: "question", type: "string" },
      { name: "disputedUniqueOutcomes", type: "uint8[]" },
    ],
    stateMutability: "view",
  },
] as const;

type DisputeResolutionSnapshot = readonly [number, number, boolean, bigint, bigint, string, number[]];

export const syncManualReviewMarketsToFirebase = (runtime: Runtime<Config>): string => {
  const sepoConfig = runtime.config.evms[0];
  const evmClient = createEvmClient(runtime, sepoConfig);
  const isHub = isHubFactoryConfig(runtime, sepoConfig, evmClient);
  if (!isHub) {
    return `Configured manual-review sync chain is not hub: ${sepoConfig.chainName}`;
  }

  const manualReviewListData = encodeFunctionData({
    abi: factoryAbi,
    functionName: "getManualReviewEventList",
  });
  const listResult = evmClient
    .callContract(runtime, {
      call: encodeCallMsg({
        from: sender,
        to: sepoConfig.marketFactoryAddress as `0x${string}`,
        data: manualReviewListData,
      }),
    })
    .result();
  const manualReviewMarkets = decodeFunctionResult({
    abi: factoryAbi,
    functionName: "getManualReviewEventList",
    data: bytesToHex(listResult.data),
  }) as `0x${string}`[];

  if (manualReviewMarkets.length === 0) {
    return "No manual-review markets";
  }

  const auth = signUpWorkFlow(runtime);
  let written = 0;
  for (const market of manualReviewMarkets) {
    try {
      const snapshotData = encodeFunctionData({
        abi: marketAbi,
        functionName: "getDisputeResolutionSnapshot",
      });
      const snapshotResult = evmClient
        .callContract(runtime, {
          call: encodeCallMsg({
            from: sender,
            to: market,
            data: snapshotData,
          }),
        })
        .result();

      const snapshot = decodeFunctionResult({
        abi: marketAbi,
        functionName: "getDisputeResolutionSnapshot",
        data: bytesToHex(snapshotResult.data),
      }) as DisputeResolutionSnapshot;

      const question = snapshot[5] || "";
      const resolutionTime = snapshot[4].toString();
      const state = Number(snapshot[0]) === 2 ? "review" : "unknown";
      const docId = `${sepoConfig.chainName.replace(/[^a-zA-Z0-9_-]/g, "_")}_${market.toLowerCase()}`;

      upsertManualReviewMarketToFirestore(runtime, auth.idToken, docId, {
        chainName: sepoConfig.chainName,
        marketAddress: market,
        question,
        resolutionTime,
        state,
      });
      written++;
    } catch (error) {
      runtime.log(
        `manual-review firebase sync skipped for ${market}: ${error instanceof Error ? error.message : String(error)}`
      );
    }
  }

  return `manualReviewMarkets=${manualReviewMarkets.length}; synced=${written}`;
};
