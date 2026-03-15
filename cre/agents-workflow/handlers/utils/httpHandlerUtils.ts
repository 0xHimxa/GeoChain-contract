import { type HTTPPayload } from "@chainlink/cre-sdk";

export const decodePayloadInput = (payload: HTTPPayload): string => {
  return new TextDecoder().decode(payload.input);
};

export const parseJsonPayload = <T>(payload: HTTPPayload): T => {
  const raw = decodePayloadInput(payload);
  if (!raw.trim()) {
    throw new Error("empty payload");
  }
  return JSON.parse(raw) as T;
};

export const parseDecimalBigInt = (
  value: string | undefined,
  fieldName: string,
  allowEmpty: boolean
): bigint => {
  if (!value) {
    if (allowEmpty) return 0n;
    throw new Error(`${fieldName} must be a numeric string`);
  }
  if (!/^\d+$/.test(value)) {
    throw new Error(`${fieldName} must be a numeric string`);
  }
  return BigInt(value);
};
