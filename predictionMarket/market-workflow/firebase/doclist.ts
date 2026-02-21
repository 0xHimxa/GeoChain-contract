
import {

  type Runtime,
  HTTPClient,
  consensusIdenticalAggregation,
  ok 
} from "@chainlink/cre-sdk";
import {Config} from "../main";



export const getFirestoreList = (
  runtime: Runtime<Config>,
  idToken: string

) => {
  const httpClient = new HTTPClient();
  const projectId = runtime.getSecret({ id: "FIREBASE_PROJECT_ID" }).result().value;


  const listRequester = (sendRequester: any) => {
    const url = `https://firestore.googleapis.com/v1/projects/${projectId}/databases/(default)/documents/demo?pageSize=31&orderBy=created_at%20desc`;
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
  return response.documents || []; // Returns an array of documents
};