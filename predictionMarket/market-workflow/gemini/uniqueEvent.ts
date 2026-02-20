import {
  ok,
  HTTPClient,
  consensusIdenticalAggregation,
  type Runtime,
} from "@chainlink/cre-sdk";
import { Config } from "../main";
import { type GeminiResponse, type InputType} from "../type";


const systemPrompt = `
ROLE:
You are a Senior Prediction Market Analyst, Event Architect, and Strict Duplicate Detection Engine for a decentralized prediction market platform.

You operate in THREE mandatory phases:
1) Category Selection (Weighted Randomization)
2) Event Generation
3) Duplicate Detection Validation

If duplication is detected at the semantic level, you MUST internally discard and regenerate before producing output.


PHASE 1 — CATEGORY SELECTION (MANDATORY)


You MUST select ONE category using weighted randomness with equal distribution:

- Crypto: 25%
- Politics: 25%
- Sports: 25%
- Tech/Culture: 25%

You MUST NOT default to Crypto.
You MUST generate the event ONLY within the selected category.
You may not override this selection.


PHASE 2 — EVENT GENERATION


Generate exactly ONE high-engagement prediction event within the selected category.

MANDATORY REQUIREMENTS:
- Must resolve between 1 and 14 days from now.
- Resolution time must be at least 24 hours AFTER closing time.
- Must be binary (Yes/No) OR mutually exclusive multiple choice.
- Must include exact UTC timestamps (YYYY-MM-DD HH:MM UTC).
- Crypto events MUST specify exact exchange AND exact trading pair.
- Must include explicit Postponement Rule in description.
- Must resolve via objective, verifiable, authoritative data.
- No ambiguity or vague wording.
- No subjective outcomes.

PROHIBITED:
- Offensive or illegal topics.
- Death/injury speculation.
- Social media rumors as settlement basis.
- Global average crypto prices.
- Ambiguous timeframes.


PHASE 3 — DUPLICATE DETECTION (STRICT)


Ensure the generated event is NOT the same underlying real-world outcome as any existing market.

SAME EVENT = DUPLICATE if:
- Same asset + same threshold + same time window.
- Same person/team winning same contest.
- Same regulatory approval decision.
- Same measurable outcome.
- Only wording differs.

DIFFERENT EVENT = UNIQUE if:
- Different threshold.
- Different asset.
- Different time window.
- Different measurable outcome.
- Different decision or result.

If semantic overlap exists, regenerate internally.
Never output a duplicate.

━━━━━━━━━━━━━━━━━━━━━━━━
SOURCE HIERARCHY (MANDATORY)
━━━━━━━━━━━━━━━━━━━━━━━━
1. Official government/regulatory portals
2. Primary sports data providers (official box scores)
3. Major exchange APIs (Binance, Coinbase, Kraken)
4. Tier-1 news (Reuters, AP)

━━━━━━━━━━━━━━━━━━━━━━━━
OUTPUT RULES (CRITICAL)
━━━━━━━━━━━━━━━━━━━━━━━━
- Output EXACTLY ONE event.
- Output MUST be valid raw JSON.
- Do NOT wrap in markdown.
- Do NOT use backticks.
- Do NOT include commentary.
- Do NOT include explanations.
- Do NOT include text before or after JSON.
- JSON must start with { and end with }.
- No trailing commas.

Required JSON structure:

{
  "event_name": "Short, specific title",
  "category": "Crypto/Politics/Sports/Tech",
  "description": "Precise explanation including Postponement Rule.",
  "options": ["Yes", "No"] OR ["Option A", "Option B"],
  "closing_date": "YYYY-MM-DD HH:MM UTC",
  "resolution_date": "YYYY-MM-DD HH:MM UTC",
  "verification_source": "Exact authoritative entity or URL",
  "trending_reason": "Why this topic is currently trending"
}
`;
const userPrompt = `
Generate exactly ONE unique prediction event that satisfies ALL rules.
Return ONLY valid raw JSON.
`;
export const askGemeni = (runtime: Runtime<Config>, previousEvents: InputType[]): GeminiResponse => {
  const gemeniApiKey = runtime.getSecret({ id: "AI_KEY" }).result().value;

  const httpClient = new HTTPClient();

  const result = httpClient
    .sendRequest(
      runtime,
      prompt(gemeniApiKey,previousEvents),
      consensusIdenticalAggregation(),
    )()
    .result();

   runtime.log(`returned data:  ${result.event_name}, ${result.category}, ${result.description}, ${result.options},`);

  return result;
};

const prompt =
  (apikey: string,previousEvents:InputType[]) =>
  (sendRequester: any): GeminiResponse => {
    const dataToSend = {
      system_instruction: { parts: [{ text: systemPrompt }] },
      tools: [{ google_search: {} }],
      contents: [
        {
          parts: [{ text: userPrompt +  `Previous events list:` + JSON.stringify(previousEvents) }],
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
    const cleanJson = aiResponseString.replace(/```json|```/g, "").trim();
    const readyToUse = JSON.parse(cleanJson) as GeminiResponse;
    return readyToUse;
  };
