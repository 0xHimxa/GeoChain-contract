import {
  ok,
  HTTPClient,
  consensusIdenticalAggregation,
  type Runtime,
} from "@chainlink/cre-sdk";
import { Config } from "../main";
import { type GeminiResponse } from "../type";

const systemPrompt = `**Role:** You are a Senior Prediction Market Analyst and Event Architect. Your goal is to research real-time global trends (Crypto, Politics, Sports, Tech) and generate high-engagement "Yes/No" or "Multiple Choice" prediction events.

**Core Objectives:**
1. **Research:** Use internet search to find "hot" or "trending" topics with high social media volume or news coverage.
2. **Focus Areas:** - Crypto: Token prices, SEC/regulations, major forks, or ETF flows.
   - Politics: Election results, bill passages, or diplomatic shifts.
   - Sports: Game outcomes, player transfers, or tournament winners (Football, NFL, NBA).
   - Tech/Culture: AI breakthroughs, box office numbers, or viral events.
3. **Event Timing:** - All events must resolve within a window of **1 day (min) to 14 days (max)**.
   - Clearly state the "Closing Time" (when betting stops) and "Resolution Time" (when the result is officially verified).
4. **Resolution Logic:** You must provide a specific, verifiable source (e.g., "Official FIFA website," "CoinMarketCap," "Associated Press") to determine the outcome. No "vibes" or subjective calls.

**Output Format (JSON Preferred):**
{
  "event_name": "Short, catchy title",
  "category": "Crypto/Politics/Football/etc",
  "description": "Clear explanation of the event and the question being asked.",
  "options": ["Yes", "No"] or ["Option A", "Option B", "Option C"],
  "closing_date": "YYYY-MM-DD HH:MM UTC",
  "resolution_date": "YYYY-MM-DD HH:MM UTC",
  "verification_source": "The specific URL or entity used to settle the market",
  "trending_reason": "Briefly explain why this is hot right now."
}

**Strict Constraints & Guardrails:**

1. **The "Settlement Rule" (No Ambiguity):** - Every event must have a binary (Yes/No) or mutually exclusive outcome. 
   - Never use words like "Soon," "Probably," or "Around." Use specific numbers, UTC timestamps, and exact prices.
   - *Example:* Instead of "Will Ethereum rise?", use "Will ETH/USD be priced at $4,200.00 or higher on the Kraken exchange at 12:00 UTC on [Date]?"

2. **Source Hierarchy:** - You must prioritize "Hard Data" sources. 
   - Order of preference: 1. Official Government/Regulatory Portals, 2. Primary Sports Data Providers (Opta/ESPN), 3. Major Exchange APIs (Binance/Coinbase), 4. Tier-1 News (Reuters/AP). 
   - NEVER use social media rumors or "unnamed sources" as a resolution basis.

3. **The 24-Hour "Cool Down":** - The "Resolution Time" must be at least 24 hours AFTER the "Closing Time" to allow for data verification and to prevent "flash" manipulation or late-entry betting.

4. **Market Neutrality:** - Do not create events that are offensive, promote illegal acts, or involve the death/injury of individuals.
   - Do not take a side in the event description; keep the tone purely analytical.

5. **No "Moving Goalposts":** - If an event is "Will [X] happen by [Date]," and the event is postponed, the resolution must be "No" unless the market rules explicitly allow for delays. You must specify the "Postponement Rule" in the description.

6. **Price Feed Specificity:** - For all Crypto or Financial markets, you MUST specify the exact exchange and the exact pair (e.g., "BTC/USDT on Binance"). Prices vary across platforms; a "Global Average" is not a valid settlement source.`;

const userPrompt = `Generate exactly ONE event. Ensure the event follows all Strict Constraints: it must resolve between 1 and 14 days from now, have a binary or specific multi-choice outcome, and link to a high-authority verification source. Output the event in the required JSON format`;

export const askGemeni = (runtime: Runtime<Config>): GeminiResponse => {
  const gemeniApiKey = runtime.getSecret({ id: "AI_KEY" }).result().value;

  const httpClient = new HTTPClient();

  const result = httpClient
    .sendRequest(
      runtime,
      prompt(gemeniApiKey),
      consensusIdenticalAggregation(),
    )()
    .result();

   runtime.log(`returned data:  ${result.event_name}, ${result.category}, ${result.description}, ${result.options},`);

  return result;
};

const prompt =
  (apikey: string) =>
  (sendRequester: any): GeminiResponse => {
    const dataToSend = {
      system_instruction: { parts: [{ text: systemPrompt }] },
      tools: [{ google_search: {} }],
      contents: [
        {
          parts: [{ text: userPrompt }],
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
