
import {

  type Runtime,
  HTTPClient,
  consensusIdenticalAggregation,
  ok 
} from "@chainlink/cre-sdk";
import { type Config } from "../Constant-variable/config";



const flattenFirestore = (doc: any) => {
  if (!doc.fields) return doc;
  
  const flattened: any = { id: doc.name.split('/').pop() }; // Grabs the actual Doc ID
  
  for (const [key, value] of Object.entries(doc.fields)) {
    // This looks inside the field (e.g., 'question') 
    // and grabs the value regardless of if it's a string, map, or number.
    const valObj = value as any;
    const actualValue = valObj.stringValue ?? valObj.integerValue ?? valObj.booleanValue ?? valObj.timestampValue;
    
    flattened[key] = actualValue;
  }
  return flattened;
};


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
  const rawDocs = response.documents || []; // Returns an array of documents

  return rawDocs.map((doc: any) => flattenFirestore(doc));
};
