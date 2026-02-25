import {
  EVMClient,
  bytesToHex,
  encodeCallMsg,
  getNetwork,
  type Runtime,
} from "@chainlink/cre-sdk";
import {
  decodeFunctionResult,
  encodeFunctionData,
  parseAbi,
  verifyTypedData,
  type Address,
  type Hex,
} from "viem";
import { sender, type Config } from "../Constant-variable/config";

export type PermitAuthorization = {
  token?: string;
  owner?: string;
  spender?: string;
  value?: string;
  nonce?: string;
  deadline?: string | number;
  signature?: string;
  domainName?: string;
  domainVersion?: string;
};

export type PermitValidationInput = {
  chainId: number;
  amount: bigint;
  permit?: PermitAuthorization;
  expectedOwner?: string;
};

export type PermitValidationResult = {
  ok: boolean;
  reason?: string;
};

const HEX_ADDRESS_REGEX = /^0x[a-fA-F0-9]{40}$/;
const HEX_BYTES_REGEX = /^0x([a-fA-F0-9]{2})*$/;
const erc20BalanceOfAbi = parseAbi(["function balanceOf(address account) view returns (uint256)"]);

const PERMIT_TYPES = {
  Permit: [
    { name: "owner", type: "address" },
    { name: "spender", type: "address" },
    { name: "value", type: "uint256" },
    { name: "nonce", type: "uint256" },
    { name: "deadline", type: "uint256" },
  ],
} as const;

const isAddressEqual = (a: string, b: string): boolean => a.toLowerCase() === b.toLowerCase();

const toChainId = (chainName: string): number | null => {
  if (chainName.includes("arbitrum")) return 421614;
  if (chainName.includes("base")) return 84532;
  if (chainName === "ethereum-testnet-sepolia") return 11155111;
  return null;
};

const parseUintString = (value: unknown): bigint | null => {
  if (typeof value === "string" && /^\d+$/.test(value)) return BigInt(value);
  if (typeof value === "number" && Number.isSafeInteger(value) && value >= 0) return BigInt(value);
  return null;
};

export const validatePermitAuthorization = async (
  runtime: Runtime<Config>,
  input: PermitValidationInput
): Promise<PermitValidationResult> => {
  const requirePermit = runtime.config.sponsorPolicy?.requirePermitAuthorization ?? true;
  if (!requirePermit) return { ok: true };

  const permit = input.permit;
  if (!permit) return { ok: false, reason: "missing permit authorization" };

  const token = permit.token || "";
  const owner = permit.owner || "";
  const spender = permit.spender || "";
  const signature = permit.signature || "";
  const domainName = permit.domainName || "";
  const domainVersion = permit.domainVersion || "1";

  if (!HEX_ADDRESS_REGEX.test(token)) return { ok: false, reason: "invalid permit.token" };
  if (!HEX_ADDRESS_REGEX.test(owner)) return { ok: false, reason: "invalid permit.owner" };
  if (!HEX_ADDRESS_REGEX.test(spender)) return { ok: false, reason: "invalid permit.spender" };
  if (!HEX_BYTES_REGEX.test(signature) || signature === "0x") {
    return { ok: false, reason: "invalid permit.signature" };
  }
  if (!domainName.trim()) return { ok: false, reason: "missing permit.domainName" };

  const permitValue = parseUintString(permit.value);
  const permitNonce = parseUintString(permit.nonce);
  const permitDeadline = parseUintString(permit.deadline);
  if (permitValue === null) return { ok: false, reason: "permit.value must be uint string" };
  if (permitNonce === null) return { ok: false, reason: "permit.nonce must be uint string" };
  if (permitDeadline === null) return { ok: false, reason: "permit.deadline must be uint string" };

  const nowSec = BigInt(Math.floor(runtime.now().getTime() / 1000));
  if (permitDeadline < nowSec) return { ok: false, reason: "permit expired" };

  if (permitValue < input.amount) {
    return { ok: false, reason: "permit.value below requested amount" };
  }

  if (input.expectedOwner && !isAddressEqual(input.expectedOwner, owner)) {
    return { ok: false, reason: "permit.owner must match userOp.sender" };
  }

  const configuredSpender = runtime.config.sponsorPolicy?.permitSpender;
  if (configuredSpender && HEX_ADDRESS_REGEX.test(configuredSpender) && !isAddressEqual(configuredSpender, spender)) {
    return { ok: false, reason: "permit.spender not allowed by policy" };
  }

  const configuredToken = runtime.config.sponsorPolicy?.permitTokenByChainId?.[String(input.chainId)];
  if (configuredToken && HEX_ADDRESS_REGEX.test(configuredToken) && !isAddressEqual(configuredToken, token)) {
    return { ok: false, reason: "permit.token not allowed by policy" };
  }

  try {
    const verified = await verifyTypedData({
      address: owner as Address,
      domain: {
        name: domainName,
        version: domainVersion,
        chainId: input.chainId,
        verifyingContract: token as Address,
      },
      types: PERMIT_TYPES,
      primaryType: "Permit",
      message: {
        owner: owner as Address,
        spender: spender as Address,
        value: permitValue,
        nonce: permitNonce,
        deadline: permitDeadline,
      },
      signature: signature as Hex,
    });

    if (!verified) return { ok: false, reason: "invalid permit signature" };
  } catch (error) {
    runtime.log(`[PERMIT_VERIFY] signature validation error: ${error instanceof Error ? error.message : String(error)}`);
    return { ok: false, reason: "invalid permit signature" };
  }

  const evmConfig = runtime.config.evms.find((evm) => toChainId(evm.chainName) === input.chainId);
  if (!evmConfig) return { ok: false, reason: "chainId not mapped in config.evms" };

  const network = getNetwork({
    chainFamily: "evm",
    chainSelectorName: evmConfig.chainName,
    isTestnet: true,
  });
  if (!network) return { ok: false, reason: `unknown chain name: ${evmConfig.chainName}` };

  const evmClient = new EVMClient(network.chainSelector.selector);
  const balanceOfData = encodeFunctionData({
    abi: erc20BalanceOfAbi,
    functionName: "balanceOf",
    args: [owner as Address],
  });

  const balanceCallResult = evmClient
    .callContract(runtime, {
      call: encodeCallMsg({
        from: sender,
        to: token as Address,
        data: balanceOfData,
      }),
    })
    .result();

  const balance = decodeFunctionResult({
    abi: erc20BalanceOfAbi,
    functionName: "balanceOf",
    data: bytesToHex(balanceCallResult.data),
  }) as bigint;

  if (balance < input.amount) {
    return { ok: false, reason: "insufficient token balance for requested amount" };
  }

  return { ok: true };
};
