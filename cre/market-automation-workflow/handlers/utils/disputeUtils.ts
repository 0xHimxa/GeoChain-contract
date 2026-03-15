export const toOutcomeLabel = (outcome: number): string => {
  if (outcome === 1) return "YES";
  if (outcome === 2) return "NO";
  if (outcome === 3) return "INCONCLUSIVE";
  return "UNSET";
};

export const toOutcomeCode = (value: string): number => {
  const normalized = value.trim().toUpperCase();
  if (normalized === "YES") return 1;
  if (normalized === "NO") return 2;
  if (normalized === "INCONCLUSIVE") return 3;
  return 3;
};

export const toIsoUtc = (unixSeconds: bigint): string =>
  new Date(Number(unixSeconds) * 1000).toISOString();
