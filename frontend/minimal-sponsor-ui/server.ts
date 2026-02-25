import { readFileSync } from "node:fs";
import { join } from "node:path";

type SponsorApiRequest = {
  creTriggerUrl: string;
  creExecuteTriggerUrl: string;
  chainId: number;
  action: string;
  amountUsdc: string;
  slippageBps: number;
  reportActionType: string;
  reportPayloadHex: string;
  reportReceiver?: string;
  reportGasLimit?: string;
  permit?: Record<string, unknown>;
  userOp: Record<string, unknown>;
};

const indexHtml = readFileSync(join(import.meta.dir, "index.html"), "utf-8");

const json = (status: number, payload: unknown) =>
  new Response(JSON.stringify(payload, null, 2), {
    status,
    headers: {
      "content-type": "application/json; charset=utf-8",
      "access-control-allow-origin": "*",
      "access-control-allow-headers": "content-type",
    },
  });

// Single endpoint that:
// 1) asks CRE for sponsorship approval
// 2) if approved, calls CRE execution trigger (writeReport onchain)
const handleSponsor = async (req: Request): Promise<Response> => {
  let body: SponsorApiRequest;
  try {
    body = (await req.json()) as SponsorApiRequest;
  } catch {
    return json(400, { error: "invalid JSON body" });
  }

  if (!body.creTriggerUrl || !body.creExecuteTriggerUrl) {
    return json(400, { error: "missing creTriggerUrl/creExecuteTriggerUrl" });
  }

  const crePayload = {
    requestId: `ui_${Date.now()}`,
    chainId: body.chainId,
    action: body.action,
    amountUsdc: body.amountUsdc,
    slippageBps: body.slippageBps,
    permit: body.permit,
    userOp: body.userOp,
  };

  const creResponse = await fetch(body.creTriggerUrl, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(crePayload),
  });

  const creDecision = await creResponse.json();
  if (!creResponse.ok || !creDecision?.approved) {
    return json(403, {
      approved: false,
      stage: "cre-policy",
      creDecision,
    });
  }

  if (!body.reportActionType || !body.reportPayloadHex) {
    return json(400, {
      approved: false,
      stage: "cre-execute",
      error: "missing reportActionType/reportPayloadHex",
    });
  }

  const executePayload = {
    requestId: `exec_${Date.now()}`,
    approvalId: creDecision.approvalId,
    chainId: body.chainId,
    amountUsdc: body.amountUsdc,
    permit: body.permit,
    actionType: body.reportActionType,
    payloadHex: body.reportPayloadHex,
    receiver: body.reportReceiver,
    gasLimit: body.reportGasLimit,
  };

  const executeRes = await fetch(body.creExecuteTriggerUrl, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(executePayload),
  });
  const executeJson = await executeRes.json();

  return json(executeRes.ok ? 200 : 502, {
    approved: !!executeJson?.submitted,
    stage: "cre-execute",
    creDecision,
    execute: executeJson,
  });
};

const port = Number(process.env.PORT || 5173);

const server = Bun.serve({
  port,
  async fetch(req) {
    if (req.method === "OPTIONS") {
      return new Response(null, {
        status: 204,
        headers: {
          "access-control-allow-origin": "*",
          "access-control-allow-headers": "content-type",
          "access-control-allow-methods": "GET,POST,OPTIONS",
        },
      });
    }

    const url = new URL(req.url);
    if (url.pathname === "/api/sponsor" && req.method === "POST") {
      return handleSponsor(req);
    }
    if (url.pathname === "/" && req.method === "GET") {
      return new Response(indexHtml, {
        headers: { "content-type": "text/html; charset=utf-8" },
      });
    }
    return new Response("Not Found", { status: 404 });
  },
});

console.log(`Minimal sponsor UI running at http://localhost:${server.port}`);
