export type EvmConfig = {
  marketFactoryAddress: string;
  chainName: string;
};

export type Config = {
  schedule: string;
  evms: EvmConfig[];
};

export const sender = "0xA85926f9598AA43A2D8f24246B5e7886C4A5FeEc";

export const ARB_MAX_SPEND_COLLATERAL = 200_000_000n; // 200 USDC (6 decimals)
export const ARB_MIN_DEVIATION_IMPROVEMENT_BPS = 10n; // 0.10%
export const PROCESS_PENDING_WITHDRAWALS_ACTION = "processPendingWithdrawals";
export const WITHDRAW_BATCH_SIZE = 20n;
