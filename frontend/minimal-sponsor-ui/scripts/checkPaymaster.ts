const required = ["AA_PAYMASTER_URL", "AA_ENTRYPOINT"] as const;

for (const key of required) {
  if (!process.env[key]) {
    throw new Error(`Missing env var: ${key}`);
  }
}

const paymasterUrl = process.env.AA_PAYMASTER_URL as string;
const entryPoint = (process.env.AA_ENTRYPOINT as string).toLowerCase();

// Basic liveness and compatibility check before attempting real UserOps.
const rpc = async (method: string, params: unknown[]) => {
  const res = await fetch(paymasterUrl, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ jsonrpc: "2.0", id: 1, method, params }),
  });
  const body = await res.json();
  return { ok: res.ok, body };
};

const supported = await rpc("pm_supportedEntryPoints", []);
if (!supported.ok || supported.body?.error) {
  console.error("pm_supportedEntryPoints failed:", JSON.stringify(supported.body, null, 2));
  process.exit(1);
}

const supportedList = (supported.body?.result || []).map((x: string) => x.toLowerCase());
console.log("Supported entry points:", supportedList);

if (!supportedList.includes(entryPoint)) {
  console.error(`Configured AA_ENTRYPOINT ${entryPoint} is not supported by this paymaster.`);
  process.exit(1);
}

const gasPrice = await rpc("pimlico_getUserOperationGasPrice", []);
if (!gasPrice.ok || gasPrice.body?.error) {
  console.error("pimlico_getUserOperationGasPrice failed:", JSON.stringify(gasPrice.body, null, 2));
  process.exit(1);
}

console.log("Paymaster check OK");
console.log(JSON.stringify(gasPrice.body?.result, null, 2));
