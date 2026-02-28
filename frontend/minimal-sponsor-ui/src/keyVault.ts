import { Wallet } from "ethers";
import type { SessionIdentity } from "./types";

type StoredWalletPayload = {
  version: 1;
  address: string;
  publicKey: string;
  cipherHex: string;
  ivHex: string;
  saltHex: string;
  createdAtUnix: number;
};

const STORAGE_KEY = "pm_local_session_wallet_v1";

const toHex = (bytes: Uint8Array): string => Array.from(bytes).map((b) => b.toString(16).padStart(2, "0")).join("");
const fromHex = (hex: string): Uint8Array => {
  const clean = hex.trim();
  if (clean.length % 2 !== 0) throw new Error("invalid hex");
  const out = new Uint8Array(clean.length / 2);
  for (let i = 0; i < clean.length; i += 2) {
    out[i / 2] = parseInt(clean.slice(i, i + 2), 16);
  }
  return out;
};

const deriveKey = async (password: string, salt: Uint8Array): Promise<CryptoKey> => {
  const base = await crypto.subtle.importKey("raw", new TextEncoder().encode(password), "PBKDF2", false, ["deriveKey"]);
  return crypto.subtle.deriveKey(
    {
      name: "PBKDF2",
      salt: salt as unknown as BufferSource,
      iterations: 250_000,
      hash: "SHA-256",
    },
    base,
    {
      name: "AES-GCM",
      length: 256,
    },
    false,
    ["encrypt", "decrypt"]
  );
};

const encryptPrivateKey = async (privateKey: string, password: string) => {
  const salt = crypto.getRandomValues(new Uint8Array(16));
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const key = await deriveKey(password, salt);
  const cipher = await crypto.subtle.encrypt({ name: "AES-GCM", iv }, key, new TextEncoder().encode(privateKey));
  return {
    cipherHex: toHex(new Uint8Array(cipher)),
    ivHex: toHex(iv),
    saltHex: toHex(salt),
  };
};

const decryptPrivateKey = async (payload: StoredWalletPayload, password: string): Promise<string> => {
  const key = await deriveKey(password, fromHex(payload.saltHex));
  const iv = fromHex(payload.ivHex) as unknown as BufferSource;
  const cipher = fromHex(payload.cipherHex) as unknown as BufferSource;
  const plain = await crypto.subtle.decrypt(
    { name: "AES-GCM", iv },
    key,
    cipher
  );
  return new TextDecoder().decode(plain);
};

export const getStoredWalletMeta = (): { address: string; publicKey: string; createdAtUnix: number } | null => {
  const raw = localStorage.getItem(STORAGE_KEY);
  if (!raw) return null;
  try {
    const parsed = JSON.parse(raw) as StoredWalletPayload;
    return {
      address: parsed.address,
      publicKey: parsed.publicKey,
      createdAtUnix: parsed.createdAtUnix,
    };
  } catch {
    return null;
  }
};

export const createOrLoadWallet = async (password: string): Promise<SessionIdentity> => {
  if (!password || password.length < 8) {
    throw new Error("password must be at least 8 characters");
  }

  const existingRaw = localStorage.getItem(STORAGE_KEY);
  if (existingRaw) {
    const existing = JSON.parse(existingRaw) as StoredWalletPayload;
    const privateKey = await decryptPrivateKey(existing, password);
    const restored = new Wallet(privateKey);
    if (restored.address.toLowerCase() !== existing.address.toLowerCase()) {
      throw new Error("wallet integrity check failed");
    }
    return {
      address: restored.address,
      publicKey: restored.signingKey.publicKey,
      privateKey,
    };
  }

  const wallet = Wallet.createRandom();
  const enc = await encryptPrivateKey(wallet.privateKey, password);
  const stored: StoredWalletPayload = {
    version: 1,
    address: wallet.address,
    publicKey: wallet.signingKey.publicKey,
    ...enc,
    createdAtUnix: Math.floor(Date.now() / 1000),
  };
  localStorage.setItem(STORAGE_KEY, JSON.stringify(stored));
  return {
    address: wallet.address,
    publicKey: wallet.signingKey.publicKey,
    privateKey: wallet.privateKey,
  };
};

export const clearStoredWallet = (): void => {
  localStorage.removeItem(STORAGE_KEY);
};
