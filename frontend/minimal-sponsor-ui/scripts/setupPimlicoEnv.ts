import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";

const required = ["PIMLICO_API_KEY", "AA_RPC_URL", "AA_OWNER_PRIVATE_KEY"] as const;
for (const key of required) {
  if (!process.env[key]) {
    throw new Error(`Missing env var: ${key}`);
  }
}

const chain = process.env.AA_CHAIN || "baseSepolia";
const apiKey = process.env.PIMLICO_API_KEY as string;
const rpcUrl = process.env.AA_RPC_URL as string;
const ownerPk = process.env.AA_OWNER_PRIVATE_KEY as string;
const creTriggerUrl = process.env.CRE_TRIGGER_URL || "https://YOUR_CRE_HTTP_TRIGGER_URL";
const testTo = process.env.AA_TEST_TO || "0x0000000000000000000000000000000000000000";

const chainSlugMap: Record<string, string> = {
  baseSepolia: "base-sepolia",
  arbitrumSepolia: "arbitrum-sepolia",
  sepolia: "sepolia",
};

const chainSlug = chainSlugMap[chain];
if (!chainSlug) {
  throw new Error(`Unsupported AA_CHAIN: ${chain}. Use one of: baseSepolia, arbitrumSepolia, sepolia`);
}

const pimlicoRpc = `https://api.pimlico.io/v2/${chainSlug}/rpc?apikey=${apiKey}`;
const envPath = join(process.cwd(), ".env");

if (existsSync(envPath)) {
  const existing = readFileSync(envPath, "utf-8");
  if (existing.includes("AA_BUNDLER_URL=") || existing.includes("AA_PAYMASTER_URL=")) {
    throw new Error(".env already has AA_BUNDLER_URL or AA_PAYMASTER_URL. Edit manually to avoid overwriting secrets.");
  }
}

const content = [
  `CRE_TRIGGER_URL=${creTriggerUrl}`,
  `AA_CHAIN=${chain}`,
  `AA_RPC_URL=${rpcUrl}`,
  `AA_BUNDLER_URL=${pimlicoRpc}`,
  `AA_PAYMASTER_URL=${pimlicoRpc}`,
  `AA_ENTRYPOINT=0x0000000071727de22e5e9d8baf0edac6f37da032`,
  `AA_OWNER_PRIVATE_KEY=${ownerPk}`,
  `AA_TEST_TO=${testTo}`,
  "",
].join("\n");

writeFileSync(envPath, content, "utf-8");
console.log(`Wrote ${envPath}`);
console.log(`Bundler/Paymaster URL set to Pimlico (${chainSlug})`);
