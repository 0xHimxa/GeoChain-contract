import {
  type Runtime,
  HTTPClient,
  consensusIdenticalAggregation,
  ok,
} from "@chainlink/cre-sdk";
import { type Config } from "../Constant-variable/config";
import { type SignupNewUserResponse } from "../type";

export const signUpWorkFlow = (runtime: Runtime<Config>) => {
  const firestoreApiKey = runtime.getSecret({ id: "FIREBASE_API_KEY" }).result();

  const httpClient = new HTTPClient();
  const url = `https://identitytoolkit.googleapis.com/v1/accounts:signUp?key=${firestoreApiKey.value}`;
  const dataToSend = {
    returnSecureToken: true,
  };

  const authRequester = (sendRequester: any) => {
    const bodyBytes = new TextEncoder().encode(JSON.stringify(dataToSend));
    const body = Buffer.from(bodyBytes).toString("base64");
    const req = {
      url,
      method: "POST" as const,
      body,
      headers: {
        "Content-Type": "application/json",
      },
    };

    const res = sendRequester.sendRequest(req).result();
    if (!ok(res)) throw new Error(`Http request failed with status ${res.statusCode}`);

    const bodyText = new TextDecoder().decode(res.body);
    return JSON.parse(bodyText) as SignupNewUserResponse;
  };

  return httpClient.sendRequest(runtime, authRequester, consensusIdenticalAggregation())().result();
};
