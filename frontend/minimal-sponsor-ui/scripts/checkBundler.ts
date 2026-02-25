const required = ["AA_BUNDLER_URL", "AA_ENTRYPOINT"] as const;

for (const key of required) {
  if (!process.env[key]) {
    throw new Error(`Missing env var: ${key}`);
  }
}

const bundlerUrl = process.env.AA_BUNDLER_URL as string;
const entryPoint = (process.env.AA_ENTRYPOINT as string).toLowerCase();

const rpc = async (method: string, params: unknown[]) => {
  const res = await fetch(bundlerUrl, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ jsonrpc: "2.0", id: 1, method, params }),
  });
  const body = await res.json();
  return { ok: res.ok, body };
};

const chainIdRes = await rpc("eth_chainId", []);
if (!chainIdRes.ok || chainIdRes.body?.error) {
  console.error("eth_chainId failed:", JSON.stringify(chainIdRes.body, null, 2));
  process.exit(1);
}

const supported = await rpc("eth_supportedEntryPoints", []);
if (!supported.ok || supported.body?.error) {
  console.error("eth_supportedEntryPoints failed:", JSON.stringify(supported.body, null, 2));
  process.exit(1);
}

const supportedList = (supported.body?.result || []).map((x: string) => x.toLowerCase());
console.log("Bundler chainId:", chainIdRes.body?.result);
console.log("Supported entry points:", supportedList);

if (!supportedList.includes(entryPoint)) {
  console.error(`Configured AA_ENTRYPOINT ${entryPoint} is not supported by this bundler.`);
  process.exit(1);
}

console.log("Bundler check OK");
