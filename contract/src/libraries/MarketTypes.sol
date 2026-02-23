// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

/**
 * @title MarketTypes
 * @author 0xHimxa
 * @notice Shared type declarations, constants, errors, and events for the PredictionMarket system
 */

// ========================================
// ENUMS
// ========================================

/// @notice Market state lifecycle
enum State {
    Open, // Market is active for trading
    Closed, // Market closed for trading, awaiting resolution
    Review, // Market under manual review
    Resolved // Outcome determined, users can redeem winning tokens
}

/// @notice Possible market resolution outcomes
enum Resolution {
    Unset, // Not yet resolved
    Yes, // YES outcome won
    No, // NO outcome won
    Inconclusive // Outcome is inconclusive
}

// ========================================
// CONSTANTS
// ========================================

/// @title MarketConstants
/// @notice Central place for all protocol constants
library MarketConstants {
    /// @notice Swap fee in basis points (400 = 4%)
    uint256 internal constant SWAP_FEE_BPS = 400;

    /// @notice Fee for minting complete sets in basis points (300 = 3%)
    uint256 internal constant MINT_COMPLETE_SETS_FEE_BPS = 300;

    /// @notice Fee for redeeming complete sets in basis points (200 = 2%)
    uint256 internal constant REDEEM_COMPLETE_SETS_FEE_BPS = 200;

    /// @notice Basis points precision (10,000 = 100%)
    uint256 internal constant FEE_PRECISION_BPS = 10_000;

    /// @notice Minimum amount required to add liquidity (prevents dust)
    uint256 internal constant MINIMUM_ADD_LIQUIDITY_SHARE = 50;

    /// @notice Minimum amount for minting/redeeming complete sets (1 USDC with 6 decimals)
    uint256 internal constant MINIMUM_AMOUNT = 1e6;

    /// @notice Minimum amount for swaps (0.97 USDC with 6 decimals)
    uint256 internal constant MINIMUM_SWAP_AMOUNT = 970_000;

    /// @notice Fee precision for price calculations (1e6 = 100%)
    uint256 internal constant PRICE_PRECISION = 1e6;
    /// @notice Maximum collateral a single user can commit per market (10,000 USDC with 6 decimals)
    /// @dev Enforced in mintCompleteSets() to prevent any one user from over-concentrating risk
    uint256 internal constant MAX_RISK_EXPOSURE = 10000e6;
}

// ========================================
// EVENTS
// ========================================

/// @title MarketEvents
/// @notice All events emitted by the PredictionMarket system
library MarketEvents {
    /// @notice Emitted when a user swaps YES for NO or NO for YES
    event Trade(address indexed user, bool yesForNo, uint256 amountIn, uint256 amountOut);

    /// @notice Emitted when market is resolved
    event Resolved(Resolution outcome);

    /// @notice Emitted when a user redeems winning tokens for collateral
    event Redeemed(address indexed user, uint256 amount);

    /// @notice Emitted when a user mints complete sets (YES + NO tokens)
    event CompleteSetsMinted(address indexed user, uint256 amount);

    /// @notice Emitted when a user redeems complete sets for collateral
    event CompleteSetsRedeemed(address indexed user, uint256 amount);

    /// @notice Emitted when initial liquidity is seeded by owner
    event LiquiditySeeded(uint256 amount);

    /// @notice Emitted when liquidity is added to the pool
    event LiquidityAdded(address indexed user, uint256 yesAmount, uint256 noAmount, uint256 shares);

    /// @notice Emitted when liquidity is removed from the pool
    event LiquidityRemoved(address indexed user, uint256 yesAmount, uint256 noAmount, uint256 shares);

    /// @notice Emitted when LP shares are transferred between addresses
    event SharesTransferred(address indexed from, address indexed to, uint256 shares);

    /// @notice Emitted when liquidity is withdrawn after resolution
    event WithDrawnLiquidity(address indexed user, uint256 amount, uint256 shares);

    /// @notice Emitted when market is placed under manual review
    event IsUnderManualReview(Resolution indexed outcome);
    event CrossChainControllerSet(address indexed controller);
    event MarketIdSet(uint256 indexed marketId);
    event MarketIdAlreadySet();
    event  SyncCanonicalPrice(uint256 indexed yesPriceE6,uint256 indexed noPriceE6,uint256 indexed validUntil, uint64 nonce);
    event WithdrawProtocolFees(address indexed owner,uint256 amount);
    
}

// ========================================
// ERRORS
// ========================================

/// @title MarketErrors
/// @notice All custom errors for the PredictionMarket system
library MarketErrors {
    /* ─────────── Constructor Errors ─────────── */
    error PredictionMarket__CloseTimeGreaterThanResolutionTime();
    error PredictionMarket__InvalidArguments_PassedInConstructor();

    /* ─────────── Market State Errors ─────────── */
    error PredictionMarket__Isclosed();
    error PredictionMarket__IsPaused();

    /* ─────────── Liquidity Seeding Errors ─────────── */
    error PredictionMarket__InitailConstantLiquidityNotSetYet();
    error PredictionMarket__InitailConstantLiquidityFundedAmountCantBeZero();
    error PredictionMarket__InitailConstantLiquidityAlreadySet();
    error PredictionMarket__FundingInitailAountGreaterThanAmountSent();

    /* ─────────── Add Liquidity Errors ─────────── */
    error PredictionMarket__AddLiquidity_YesAndNoCantBeZero();
    error PredictionMarket__AddLiquidity_ShareSendingIsLessThanMinShares();
    error PredictionMarket__AddLiquidity_Yes_No_LessThanMiniMum();
    error PredictionMarket__AddLiquidity_InsuffientTokenBalance();

    /* ─────────── Remove Liquidity Errors ─────────── */
    error PredictionMarket__WithDrawLiquidity_SlippageExceeded();
    error PredictionMarket__WithDrawLiquidity_InsufficientSharesBalance();
    error PredictionMarket__WithDrawLiquidity_ZeroSharesPassedIn();

    /* ─────────── Share Transfer Errors ─────────── */
    error PredictionMarket__TransferShares_CantbeSendtoZeroAddress();
    error PredictionMarket__TransferShares_InsufficientShares();

    /* ─────────── Complete Sets Errors ─────────── */
    error PredictionMarket__MintCompleteSets_InsuffientTokenBalance();
    error PredictionMarket__redeemCompleteSets_InsuffientTokenBalance();

    /* ─────────── General Errors ─────────── */
    error PredictionMarket__AmountCantBeZero();
    error PredictionMarket__AmountLessThanMinSwapAllwed();
    error PredictionMarket__SwapingExceedSlippage();
    error PredictionMarket__SwapYesFoNo_YesExeedBalannce();
    error PredictionMarket__SwapNoFoYes_NoExeedBalannce();
    error PredictionMarket__RedeemCompletesetLessThanMinAllowed();
    error PredictionMarket__MintingCompleteset__AmountLessThanMinimu();
    error PredictionMarket__NotOwner_Or_CrossChainController();
      
    error PredictionMarket__AmountLessThanMinAllwed();
    /// @notice Thrown when a user's cumulative collateral exposure exceeds MAX_RISK_EXPOSURE in a single market
    error PredictionMarket__RiskExposureExceeded();

    /* ─────────── Resolution Errors ─────────── */
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
   error  PredictionMarket__MarketFactoryAddressCantBeZero();
   error PredictionMarket__CrossChainControllerCantBeZero();
}
