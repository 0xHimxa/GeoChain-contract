import {
  ok,
  HTTPClient,
  consensusIdenticalAggregation,
  type Runtime,
} from "@chainlink/cre-sdk";
import { Config } from "../main";
import { type IsDuplicate } from "../type";
 

const systemPrompt = `You are a strict duplicate & rephrase detector for a decentralized prediction market platform.
Your only task is to determine whether a NEW proposed market question describes THE SAME underlying real-world event/outcome as any of the previous recent markets — or if it is meaningfully different.

Core rules you MUST follow:

1. SAME EVENT = DUPLICATE
   → even if the wording is completely different
   → even if resolution date, phrasing, or probability direction is reworded
   → covers the exact same question people would bet on in reality

   Classic duplicate examples:
   • "Will Bitcoin reach $100,000 by Dec 31 2025?"
   • "BTC above 100k before 2026?"
   • "Does Bitcoin hit 6 figures in 2025?"
   • "Probability Bitcoin ≥ $100,000 end of 2025"

   All of the above → DUPLICATE

2. DIFFERENT EVENT = UNIQUE
   → different person wins
   → different threshold / price level
   → different time window (month/year difference matters)
   → different outcome being predicted
   → completely separate real-world happening

   Examples that are UNIQUE:
   • "Will Bitcoin reach $100,000 by Dec 31 2025?" vs "Will Bitcoin reach $150,000 by Dec 31 2025?"
   • "Will Trump win 2024?" vs "Will Harris win 2024?"
   • "Will Ethereum ETF be approved in 2025?" vs "Will Solana ETF be approved in 2025?"


OUTPUT FORMAT (CRITICAL):
You MUST respond with a SINGLE, MINIFIED JSON object on one line. No prose, no markdown, no backticks. Any text outside the JSON is a system failure.


{"is_duplicate": boolean}
Rules:
- is_duplicate = true  if the new question is the same event/outcome (different wording is still duplicate)
- If no match  is_duplicate: false

You are extremely conservative: when in doubt, call it a duplicate.`




interface InputType{

    question: string
    resolutionTime: string

}





export const askGemeniDuplicateCheck = (runtime: Runtime<Config>, marketInfo:InputType[],newEvent:InputType ): IsDuplicate => {
  const gemeniApiKey = runtime.getSecret({ id: "AI_KEY" }).result().value;

  const httpClient = new HTTPClient();

  const result = httpClient
    .sendRequest(
      runtime,
      prompt(gemeniApiKey, marketInfo,newEvent),
      consensusIdenticalAggregation(),
    )()
    .result();



 return result   
}





const prompt =
  (apikey: string, marketInput:InputType[],newEvent:InputType) =>
  (sendRequester: any):IsDuplicate  => {
    const currentTime = new Date().toISOString();
    const dataToSend = {
      system_instruction: { parts: [{ text: systemPrompt }] },
      tools: [{ google_search: {} }],
      contents: [
        {
          parts: [{ text: `previous_question: ${marketInput}   new_event:${newEvent}` }],
        },
      ],
      

    };

    // Encode request body as base64 (required by CRE HTTP capability)
    const bodyBytes = new TextEncoder().encode(JSON.stringify(dataToSend));
    const body = Buffer.from(bodyBytes).toString("base64");

    const req = {
      url: `https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent`,
      method: "POST" as const,
      body,
      headers: {
        "Content-Type": "application/json",
        "x-goog-api-key": apikey,
      },
     
    };

    const res = sendRequester.sendRequest(req).result();
    if (!ok(res))
      throw new Error(`Http request failed with status ${res.statusCode}`);

    const rawData = new TextDecoder().decode(res.body);
    const aires = JSON.parse(rawData);



    // Parse and extract the model text
    const aiResponseString = aires?.candidates?.[0]?.content?.parts?.[0]?.text;
    const readyToUse = JSON.parse(aiResponseString) as IsDuplicate ;

    return readyToUse;
  };