import { type HTTPPayload, type Runtime } from "@chainlink/cre-sdk";
import { type Config } from "../../Constant-variable/config";
import { revokeSessionHttpHandler } from "./httpRevokeSession";

/**
 * Agent revoke endpoint delegates to the canonical session-revoke handler.
 * This keeps a single revocation validation path and avoids policy drift.
 */
export const agentRevokeHttpHandler = async (runtime: Runtime<Config>, payload: HTTPPayload): Promise<string> => {
  const agentPolicy = runtime.config.agentPolicy;
  if (!agentPolicy?.enabled) {
    return JSON.stringify({
      revoked: false,
      requestId: `agent_revoke_${runtime.now().toISOString()}`,
      reason: "agent policy disabled",
    });
  }
  return revokeSessionHttpHandler(runtime, payload);
};
