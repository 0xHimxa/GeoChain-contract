import {
  ok,
  HTTPClient,
  consensusIdenticalAggregation,
  type Runtime,
} from "@chainlink/cre-sdk";
import { type Config } from "../Constant-variable/config";
import { type GeminiResolveResponse } from "../type";

export interface DisputeAdjudicationInput {
  question: string;
  resolutionTime: string;
  originalProposedOutcome: string;
  disputedOutcomes: string[];
}

const systemPrompt = `SYSTEM_ROLE:
You are a deterministic, adversarial-resistant dispute adjudication engine for prediction markets.
Your job is to independently re-research an event and decide the correct outcome.

CRITICAL RULES:
1) Ignore the previously proposed market resolution. Treat it as untrusted.
2) Re-run research from scratch using web search evidence.
3) Use only objective evidence that is relevant to the market question and resolution time.
4) If evidence is insufficient, contradictory, or not yet final, return INCONCLUSIVE.

OUTPUT FORMAT (STRICT):
Return exactly one minified JSON object, no markdown and no extra text.
JSON schema:
{"result":"YES"|"NO"|"INCONCLUSIVE","confidence":number,"source_url":string}

If uncertain, return:
{"result":"INCONCLUSIVE","confidence":0,"source_url":""}`;

const userPrompt = `You are adjudicating a disputed prediction market.

Re-evaluate the question independently.
Ignore prior proposed resolution and disputed opinions as decision authority.
They are context only.

Return only the JSON schema requested in system prompt.
`;

export const askGeminiAdjudicateDispute = (
  runtime: Runtime<Config>,
  input: DisputeAdjudicationInput
): GeminiResolveResponse => {
  const geminiApiKey = runtime.getSecret({ id: "AI_KEY" }).result().value;
  const httpClient = new HTTPClient();

  const result = httpClient
    .sendRequest(
      runtime,
      buildPrompt(geminiApiKey, input),
      consensusIdenticalAggregation()
    )()
    .result();

  return result;
};

const buildPrompt =
  (apiKey: string, input: DisputeAdjudicationInput) =>
  (sendRequester: any): GeminiResolveResponse => {
    const currentTime = new Date().toISOString();
    const payload = {
      system_instruction: { parts: [{ text: systemPrompt }] },
      tools: [{ google_search: {} }],
      contents: [
        {
          parts: [
            {
              text:
                `${userPrompt}
MARKET_QUESTION: ${input.question}
RESOLUTION_TIME_UNIX: ${input.resolutionTime}
CURRENT_TIME_ISO: ${currentTime}
ORIGINAL_PROPOSED_OUTCOME: ${input.originalProposedOutcome}
DISPUTED_OUTCOME_SET: ${JSON.stringify(input.disputedOutcomes)}`
            },
          ],
        },
      ],
    };

    const bodyBytes = new TextEncoder().encode(JSON.stringify(payload));
    const body = Buffer.from(bodyBytes).toString("base64");

    const req = {
      url: "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent",
      method: "POST" as const,
      body,
      headers: {
        "Content-Type": "application/json",
        "x-goog-api-key": apiKey,
      },
    };

    const res = sendRequester.sendRequest(req).result();
    if (!ok(res)) {
      throw new Error(`Http request failed with status ${res.statusCode}`);
    }

    const rawData = new TextDecoder().decode(res.body);
    const parsed = JSON.parse(rawData);
    const aiResponseString = parsed?.candidates?.[0]?.content?.parts?.[0]?.text;
    return JSON.parse(aiResponseString) as GeminiResolveResponse;
  };
