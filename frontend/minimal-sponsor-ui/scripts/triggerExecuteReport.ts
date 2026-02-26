const required = [
  "CRE_EXECUTE_TRIGGER_URL",
  "CRE_APPROVAL_ID",
  "CHAIN_ID",
  "AMOUNT_USDC",
  "REPORT_ACTION_TYPE",
  "REPORT_PAYLOAD_HEX",
] as const;
for (const key of required) {
  if (!process.env[key]) {
    throw new Error(`Missing env var: ${key}`);
  }
}

const body = {
  requestId: `manual_${Date.now()}`,
  approvalId: process.env.CRE_APPROVAL_ID,
  chainId: Number(process.env.CHAIN_ID),
  amountUsdc: process.env.AMOUNT_USDC,
  actionType: process.env.REPORT_ACTION_TYPE,
  payloadHex: process.env.REPORT_PAYLOAD_HEX,
  receiver: process.env.REPORT_RECEIVER || undefined,
  gasLimit: process.env.REPORT_GAS_LIMIT || undefined,
};

const res = await fetch(process.env.CRE_EXECUTE_TRIGGER_URL as string, {
  method: "POST",
  headers: { "content-type": "application/json" },
  body: JSON.stringify(body),
});

const json = await res.json();
console.log(JSON.stringify({ status: res.status, body: json }, null, 2));
