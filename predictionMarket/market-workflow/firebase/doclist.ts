
import {

  type Runtime,
  HTTPClient,
  consensusIdenticalAggregation,
  ok 
} from "@chainlink/cre-sdk";
import {Config} from "../main";



export const getFirestoreList = (
  runtime: Runtime<Config>,
  idToken: string,
  projectId: string
) => {
  const httpClient = new HTTPClient();

  const listRequester = (sendRequester: any) => {
    const url = `https://firestore.googleapis.com/v1/projects/${projectId}/databases/(default)/documents/demo`;

    const req = {
      url: url,
      method: "GET" as const,
      headers: {
        "Authorization": `Bearer ${idToken}`,
      },
    };

    const res = sendRequester.sendRequest(req).result();
    if (res.statusCode !== 200) throw new Error("Failed to fetch list");

    return JSON.parse(new TextDecoder().decode(res.body));
  };

  const response = httpClient.sendRequest(runtime, listRequester, consensusIdenticalAggregation())().result();
  return response.value.documents; // Returns an array of documents
};