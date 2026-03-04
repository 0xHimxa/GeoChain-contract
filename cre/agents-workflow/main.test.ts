import { describe, expect, test } from "bun:test";
import { initWorkflow } from "./main";
import type { Config } from "./Constant-variable/config";

const baseConfig: Config = {
  schedule: "*/30 * * * * *",
  evms: [],
  httpTriggerAuthorizedKeys: [
    {
      type: "KEY_TYPE_ECDSA_EVM",
      publicKey: "0xA85926f9598AA43A2D8f24246B5e7886C4A5FeEc",
    },
  ],
  httpAgentAuthorizedKeys: [
    {
      type: "KEY_TYPE_ECDSA_EVM",
      publicKey: "0xA85926f9598AA43A2D8f24246B5e7886C4A5FeEc",
    },
  ],
};

describe("initWorkflow", () => {
  test("returns five agent HTTP handlers when agent keys are configured", () => {
    const handlers = initWorkflow(baseConfig);
    expect(handlers).toBeArray();
    expect(handlers).toHaveLength(5);
  });

  test("returns no handlers when no authorized agent keys are configured", () => {
    const handlers = initWorkflow({
      ...baseConfig,
      httpTriggerAuthorizedKeys: [],
      httpAgentAuthorizedKeys: [],
    });
    expect(handlers).toHaveLength(0);
  });
});
