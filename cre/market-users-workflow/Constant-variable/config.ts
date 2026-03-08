export type EvmConfig = {
  marketFactoryAddress: string;
  chainName: string;
  routerReceiverAddress?: string;
  collateralTokenAddress?: string;
  reportGasLimit?: string;
  ethToUsdcRateE6?: string;
};

export type AuthorizedKeyConfig = {
  type: "KEY_TYPE_ECDSA_EVM";
  publicKey: string;
};

export type SponsorPolicyConfig = {
  enabled: boolean;
  supportedChainIds: number[];
  allowedActions: string[];
  maxAmountUsdc: string;
  maxSlippageBps: number;
  requireSessionAuthorization?: boolean;
  sessionMaxDurationSec?: number;
};

export type ExecutePolicyConfig = {
  enabled: boolean;
  allowedActionTypes: string[];
};

export type FiatCreditPolicyConfig = {
  enabled: boolean;
  supportedChainIds: number[];
  maxAmountUsdc: string;
  allowedProviders: string[];
};

export type EthCreditPolicyConfig = {
  enabled: boolean;
  supportedChainIds: number[];
  maxAmountUsdc: string;
};

export type AgentPolicyConfig = {
  enabled: boolean;
  supportedChainIds: number[];
  allowedActions: string[];
  maxAmountUsdc: string;
  maxSlippageBps: number;
  defaultSlippageBps: number;
};

export type Config = {
  schedule: string;
  evms: EvmConfig[];
  httpTriggerAuthorizedKeys?: AuthorizedKeyConfig[];
  httpExecutionAuthorizedKeys?: AuthorizedKeyConfig[];
  httpFiatCreditAuthorizedKeys?: AuthorizedKeyConfig[];
  httpAgentAuthorizedKeys?: AuthorizedKeyConfig[];
  sponsorPolicy?: SponsorPolicyConfig;
  executePolicy?: ExecutePolicyConfig;
  fiatCreditPolicy?: FiatCreditPolicyConfig;
  ethCreditPolicy?: EthCreditPolicyConfig;
  agentPolicy?: AgentPolicyConfig;
};

export const sender = "0xA85926f9598AA43A2D8f24246B5e7886C4A5FeEc";

export const ARB_MAX_SPEND_COLLATERAL = 500_000_000n;
export const ARB_MIN_DEVIATION_IMPROVEMENT_BPS = 10n;
export const PROCESS_PENDING_WITHDRAWALS_ACTION = "processPendingWithdrawals";
export const WITHDRAW_BATCH_SIZE = 20n;
