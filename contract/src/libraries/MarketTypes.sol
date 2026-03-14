// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

/// @notice Lifecycle state machine used by prediction markets.
enum State {
    Open,
    Closed,
    Review,
    Resolved
}

/// @notice Resolution outcomes used by market finalization logic.
enum Resolution {
    Unset,
    Yes,
    No,
    Inconclusive
}

/// @title MarketConstants
/// @notice Global constants shared by market and factory contracts.
library MarketConstants {
    /// @dev Base AMM swap fee in bps.
    uint256 internal constant SWAP_FEE_BPS = 400;
    /// @dev Fee charged on LMSR buy/sell trades (bps).
    uint256 internal constant LMSR_TRADE_FEE_BPS = 400;
    /// @dev Fee charged when minting complete sets.
    uint256 internal constant MINT_COMPLETE_SETS_FEE_BPS = 300;
    /// @dev Fee charged when redeeming complete sets or winnings.
    uint256 internal constant REDEEM_COMPLETE_SETS_FEE_BPS = 200;
    /// @dev Basis-point denominator (100%).
    uint256 internal constant FEE_PRECISION_BPS = 10_000;
    /// @dev Minimum per-side token amount for add-liquidity calls.
    uint256 internal constant MINIMUM_ADD_LIQUIDITY_SHARE = 50;
    /// @dev Minimum amount for complete-set mint/redeem.
    uint256 internal constant MINIMUM_AMOUNT = 1e6;
    /// @dev Minimum swap input amount.
    uint256 internal constant MINIMUM_SWAP_AMOUNT = 970_000;
    /// @dev Price precision for probabilities/canonical prices.
    uint256 internal constant PRICE_PRECISION = 1e6;
    /// @dev Per-user exposure cap for non-exempt mintCompleteSets callers.
    uint256 internal constant MAX_EXPOSURE_PRECISION = 10_000;
    uint256 internal constant MAX_EXPOSURE_BPS = 500; // 5% of total liquidity
    /// @dev Default duration for market resolution disputes.
    uint256 internal constant DEFAULT_DISPUTE_WINDOW = 1 hours;

    // ── LMSR Constants ───────────────────────────────────────────────
    /// @dev ln(2) scaled to 1e6. Used to compute max market-maker subsidy for binary markets.
    uint256 internal constant LMSR_LN2_E6 = 693_147;
    /// @dev Tolerance for CRE-reported price sum validation (0.1%).
    uint256 internal constant LMSR_PRICE_TOLERANCE = 1_000;
    /// @dev Minimum trade size for LMSR buy/sell (1 USDC).
    uint256 internal constant MINIMUM_LMSR_TRADE_AMOUNT = 1e6;
}

/// @title MarketEvents
/// @notice Events emitted by prediction market contracts.
library MarketEvents {
    /// @dev User swapped one outcome token for the other.
    event Trade(
        address indexed user,
        bool yesForNo,
        uint256 amountIn,
        uint256 amountOut
    );
    /// @dev Market reached final resolved state.
    event Resolved(Resolution outcome);
    /// @dev Initial market outcome proposed and pending dispute window expiry.
    event ResolutionProposed(
        Resolution indexed outcome,
        uint256 indexed disputeDeadline,
        string proofUrl
    );
    /// @dev Proposed resolution was disputed by a participant.
    event ResolutionDisputed(
        address indexed disputer,
        Resolution indexed proposedOutcome
    );
    /// @dev User redeemed winning token for collateral.
    event Redeemed(address indexed user, uint256 amount);
    /// @dev User minted YES+NO pair from collateral.
    event CompleteSetsMinted(address indexed user, uint256 amount);
    /// @dev User redeemed YES+NO pair into collateral.
    event CompleteSetsRedeemed(address indexed user, uint256 amount);
    /// @dev One-time pool bootstrap event.
    event LiquiditySeeded(uint256 amount);
    /// @dev LP added balanced liquidity.
    event LiquidityAdded(
        address indexed user,
        uint256 yesAmount,
        uint256 noAmount,
        uint256 shares
    );
    /// @dev LP removed proportional liquidity.
    event LiquidityRemoved(
        address indexed user,
        uint256 yesAmount,
        uint256 noAmount,
        uint256 shares
    );
    /// @dev LP share transfer between accounts.
    event SharesTransferred(
        address indexed from,
        address indexed to,
        uint256 shares
    );
    /// @dev LP collateral withdrawal after resolution.
    event WithDrawnLiquidity(
        address indexed user,
        uint256 amount,
        uint256 shares
    );
    /// @dev Market marked for manual review due to inconclusive resolution.
    event IsUnderManualReview(Resolution indexed outcome);
    /// @dev Cross-chain controller configured.
    event CrossChainControllerSet(address indexed controller);
    /// @dev Market id assigned.
    event MarketIdSet(uint256 indexed marketId);
    event MarketIdAlreadySet();
    /// @dev Canonical price snapshot synced from hub.
    event SyncCanonicalPrice(
        uint256 indexed yesPriceE6,
        uint256 indexed noPriceE6,
        uint256 indexed validUntil,
        uint64 nonce
    );
    /// @dev Protocol fee withdrawal executed.
    event WithdrawProtocolFees(address indexed owner, uint256 amount);

    // ── LMSR Events ──────────────────────────────────────────────────
    /// @dev LMSR market initialized with liquidity parameter and subsidy deposit.
    event MarketInitialized(uint256 liquidityParam, uint256 subsidyDeposit);
    /// @dev CRE-driven LMSR buy trade executed.
    event LMSRBuyExecuted(
        address indexed trader,
        uint8 indexed outcomeIndex,
        uint256 sharesDelta,
        uint256 costDelta,
        uint256 newYesPriceE6,
        uint256 newNoPriceE6,
        uint64 nonce
    );
    /// @dev CRE-driven LMSR sell trade executed.
    event LMSRSellExecuted(
        address indexed trader,
        uint8 indexed outcomeIndex,
        uint256 sharesDelta,
        uint256 refundDelta,
        uint256 newYesPriceE6,
        uint256 newNoPriceE6,
        uint64 nonce
    );
}

/// @title MarketErrors
/// @notice Custom errors used by prediction market contracts.
library MarketErrors {
    error PredictionMarket__CloseTimeGreaterThanResolutionTime();
    error PredictionMarket__InvalidArguments_PassedInConstructor();
    error PredictionMarket__Isclosed();
    error PredictionMarket__IsPaused();
    error PredictionMarket__InitailConstantLiquidityNotSetYet();
    error PredictionMarket__InitailConstantLiquidityFundedAmountCantBeZero();
    error PredictionMarket__InitailConstantLiquidityAlreadySet();
    error PredictionMarket__FundingInitailAountGreaterThanAmountSent();
    error PredictionMarket__AddLiquidity_YesAndNoCantBeZero();
    error PredictionMarket__AddLiquidity_ShareSendingIsLessThanMinShares();
    error PredictionMarket__AddLiquidity_Yes_No_LessThanMiniMum();
    error PredictionMarket__AddLiquidity_InsuffientTokenBalance();
    error PredictionMarket__WithDrawLiquidity_SlippageExceeded();
    error PredictionMarket__WithDrawLiquidity_InsufficientSharesBalance();
    error PredictionMarket__WithDrawLiquidity_ZeroSharesPassedIn();
    error PredictionMarket__TransferShares_CantbeSendtoZeroAddress();
    error PredictionMarket__TransferShares_InsufficientShares();
    error PredictionMarket__MintCompleteSets_InsuffientTokenBalance();
    error PredictionMarket__redeemCompleteSets_InsuffientTokenBalance();
    error PredictionMarket__AmountCantBeZero();
    error PredictionMarket__AmountLessThanMinSwapAllwed();
    error PredictionMarket__SwapingExceedSlippage();
    error PredictionMarket__SwapYesFoNo_YesExeedBalannce();
    error PredictionMarket__SwapNoFoYes_NoExeedBalannce();
    error PredictionMarket__RedeemCompletesetLessThanMinAllowed();
    error PredictionMarket__MintingCompleteset__AmountLessThanMinimu();
    error PredictionMarket__NotOwner_Or_CrossChainController();
    error PredictionMarket__AmountLessThanMinAllwed();
    error PredictionMarket__RiskExposureExceeded();
    error PredictionMarket__ResolveTimeNotReached();
    error PredictionMarket__AlreadyResolved();
    error PredictionMarket__MarketNotClosed();
    error PredictionMarket__NotResolved();
    error PredictionMarket__ProofUrlCantBeEmpty();
    error PredictionMarket__IsUnderManualReview();
    error PredictionMarket__StateNeedToResolvedToWithdrawLiquidity();
    error PredictionMarket__InvalidFinalOutcome();
    error PredictionMarket__ManualReviewNeeded();
    error PredictionMarket__MarketNotInReview();
    error PredictionMarket__WithDrawLiquidity_Insufficientfee();
    error PredictionMarket__InvalidReport();
    error PredictionMarket__MarketFactoryAddressCantBeZero();
    error PredictionMarket__CrossChainControllerCantBeZero();
    error PredictionMarket__DisputeWindowMustBeGreaterThanZero();
    error PredictionMarket__NoPendingResolution();
    error PredictionMarket__DisputeWindowNotPassed();
    error PredictionMarket__DisputeWindowClosed();
    error PredictionMarket__ResolutionAlreadyDisputed();
    error PredictionMarket__DisputeAlreadySubmittedByUser();

    // ── LMSR Errors ──────────────────────────────────────────────────
    /// @dev CRE-reported prices do not sum to ~1e6.
    error LMSR__InvalidPriceSum();
    /// @dev Trade report nonce is not strictly greater than current nonce.
    error LMSR__StaleTradeNonce();
    /// @dev Contract does not hold enough collateral for the LMSR subsidy.
    error LMSR__InsufficientSubsidy();
    /// @dev Trader does not hold enough outcome tokens to sell.
    error LMSR__InsufficientShares();
    /// @dev Market has already been initialized with LMSR parameters.
    error LMSR__AlreadyInitialized();
    /// @dev Market has not been initialized with LMSR parameters yet.
    error LMSR__NotInitialized();
    /// @dev Trade amount is below minimum.
    error LMSR__TradeBelowMinimum();
    /// @dev Invalid outcome index (must be 0 for YES or 1 for NO).
    error LMSR__InvalidOutcomeIndex();
    /// @dev Trader address cannot be zero.
    error LMSR__TraderCannotBeZero();
}
