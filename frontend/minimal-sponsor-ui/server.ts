import { readFileSync } from "node:fs";
import { join } from "node:path";

type SponsorApiRequest = {
  requestId?: string;
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
  session?: Record<string, unknown>;
  permit?: Record<string, unknown>;
  userOp: Record<string, unknown>;
};

type RevokeSessionApiRequest = {
  requestId?: string;
  creRevokeTriggerUrl: string;
  sessionId: string;
  owner: string;
  chainId: number;
  revokeSignature: string;
};

type CrePolicyDecision = {
  approved?: boolean;
  approvalId?: string;
};

type ExecuteDecision = {
  submitted?: boolean;
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
    requestId: body.requestId || `ui_${Date.now()}`,
    chainId: body.chainId,
    action: body.action,
    amountUsdc: body.amountUsdc,
    slippageBps: body.slippageBps,
    session: body.session,
    permit: body.permit,
    userOp: body.userOp,
  };

  const creResponse = await fetch(body.creTriggerUrl, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(crePayload),
  });

  const creDecision = (await creResponse.json()) as CrePolicyDecision;
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
    requestId: `${body.requestId || `ui_${Date.now()}`}_exec`,
    approvalId: creDecision.approvalId,
    chainId: body.chainId,
    amountUsdc: body.amountUsdc,
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
  const executeJson = (await executeRes.json()) as ExecuteDecision;

  return json(executeRes.ok ? 200 : 502, {
    approved: !!executeJson?.submitted,
    stage: "cre-execute",
    creDecision,
    execute: executeJson,
  });
};

const handleSessionRevoke = async (req: Request): Promise<Response> => {
  let body: RevokeSessionApiRequest;
  try {
    body = (await req.json()) as RevokeSessionApiRequest;
  } catch {
    return json(400, { error: "invalid JSON body" });
  }

  if (!body.creRevokeTriggerUrl) {
    return json(400, { error: "missing creRevokeTriggerUrl" });
  }

  const revokePayload = {
    requestId: body.requestId || `revoke_${Date.now()}`,
    sessionId: body.sessionId,
    owner: body.owner,
    chainId: body.chainId,
    revokeSignature: body.revokeSignature,
  };

  const revokeRes = await fetch(body.creRevokeTriggerUrl, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(revokePayload),
  });

  const revokeJson = await revokeRes.json();
  return json(revokeRes.ok ? 200 : 502, revokeJson);
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
    if (url.pathname === "/api/session/revoke" && req.method === "POST") {
      return handleSessionRevoke(req);
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
