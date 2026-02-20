



import {

  type Runtime,
  HTTPClient,
  consensusIdenticalAggregation,
  ok 
} from "@chainlink/cre-sdk";
import {Config} from "../main";






export const writeToFirestore = (
  runtime: Runtime<Config>,
  idToken: string,
  question: string,
  resolutionTime: string,
  geminiData: any // This is the data you want to save
) => {
  const projectId = runtime.getSecret({ id: "FIREBASE_PROJECT_ID" }).result().value;

  const httpClient = new HTTPClient();

  const writeRequester = (sendRequester: any) => {
    // 1. Prepare the Firestore-specific JSON structure
    const dataToSend = {
      fields: {
        question: { stringValue: question },
        resolutionTime: { stringValue: resolutionTime },
        geminiResponse: { stringValue: geminiData.response || "No response" },
        // Firestore expects integers as strings in its REST API
        createdAt: { integerValue: Date.now().toString() }, 
      },
    };

 

const bodyBytes = new TextEncoder().encode(JSON.stringify(dataToSend));
    const body = Buffer.from(bodyBytes).toString("base64");

    // 2. Build the URL
    // We use a POST to the collection 'demo'. 
    // Firestore will auto-generate an ID if we don't specify one.
    const url = `https://firestore.googleapis.com/v1/projects/${projectId}/databases/(default)/documents/demo`;

    const req = {
      url: url,
      method: "POST" as const,
      body: body,
      headers: {
        "Authorization": `Bearer ${idToken}`,
        "Content-Type": "application/json",
      }
    };

    const res = sendRequester.sendRequest(req).result();

    if (res.statusCode !== 200) {
      const errorText = new TextDecoder().decode(res.body);
      throw new Error(`Firestore write failed: ${res.statusCode} - ${errorText}`);
    }

    return JSON.parse(new TextDecoder().decode(res.body));
  };

  const response = httpClient.sendRequest(
    runtime,
    writeRequester,
    consensusIdenticalAggregation()
  )().result();

  return response.value;
};