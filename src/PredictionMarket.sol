// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

// ========================================
// IMPORTS
// ========================================

// OpenZeppelin ERC20 utilities for safe token operations
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

// OpenZeppelin security and access control utilities
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

// Custom outcome token for YES/NO positions
import {OutcomeToken} from "./OutcomeToken.sol";

// Protocol libraries
import {State, Resolution, MarketConstants, MarketEvents, MarketErrors} from "./libraries/MarketTypes.sol";
import {AMMLib} from "./libraries/AMMLib.sol";
import {FeeLib} from "./libraries/FeeLib.sol";
import {MarketFactory} from "src/MarketFactory.sol";
import {ReceiverTemplate} from "script/interfaces/ReceiverTemplate.sol";

/**
 * @title PredictionMarket
 * @author 0xHimxa
 * @notice A decentralized prediction market allowing users to trade on binary outcomes (YES/NO)
 * @dev This contract implements an automated market maker (AMM) with constant product formula (x * y = k)
 *      Users can provide liquidity, mint/redeem complete sets, swap between YES/NO tokens, and redeem winning positions
 *
 * Key Features:
 * - Time-based market lifecycle (Open -> Closed -> Resolved)
 * - Liquidity provision with LP shares
 * - Complete sets minting/redemption (1 collateral = 1 YES + 1 NO)
 * - Constant product AMM for swapping YES <-> NO tokens
 * - Owner-controlled resolution with binary outcome
 * - Fee collection on swaps and complete set operations
 */
contract PredictionMarket is ReentrancyGuard, Pausable, ReceiverTemplate {
    using SafeERC20 for IERC20;

    // ========================================
    // STATE VARIABLES
    // ========================================

    /* ─────────── Market Configuration ─────────── */

    /// @notice The prediction question for this market
    string public s_question;

    /// @notice URL to proof/evidence for market resolution
    string public s_Proof_Url;

    /// @notice The ERC20 token used as collateral (e.g., USDC, DAI)
    IERC20 public immutable i_collateral;

    /// @notice YES outcome token contract
    OutcomeToken public immutable yesToken;

    /// @notice NO outcome token contract
    OutcomeToken public immutable noToken;

    /// @notice Timestamp when market closes for trading
    uint256 public immutable closeTime;

    /// @notice Timestamp when market can be resolved by owner
    uint256 public immutable resolutionTime;

    /* ─────────── Protocol Fee Accumulator ─────────── */

    /// @notice Accumulated protocol fees from all operations
    uint256 public protocolCollateralFees;

    /* ─────────── AMM Liquidity Pool State ─────────── */

    /// @notice Reserve of YES tokens in the AMM pool
    uint256 public yesReserve;

    /// @notice Reserve of NO tokens in the AMM pool
    uint256 public noReserve;

    /// @notice Whether initial liquidity has been seeded
    bool public seeded;

    /// @notice Total liquidity provider shares issued
    uint256 public totalShares;

    /// @notice Mapping of LP addresses to their share balances
    mapping(address => uint256) public lpShares;
    /// @notice Tracks cumulative collateral exposure per user to enforce MAX_RISK_EXPOSURE cap
    /// @dev Incremented when a user mints complete sets; prevents any single user from over-concentrating risk
    mapping(address => uint256) public userRiskExposure;

    /* ─────────── Market State ─────────── */

    /// @notice Current market state (Open/Closed/Review/Resolved)
    State public state;

    /// @notice Current market resolution outcome
    Resolution public resolution;

    /// @notice Flag indicating if market requires manual resolution review
    bool private manualReviewNeeded;

    /// @notice Reference to the parent MarketFactory that deployed this market
    /// @dev Used to notify the factory when this market resolves (removes itself from activeMarkets list)
    MarketFactory private marketFactory;

    /// @notice Optional controller allowed to push hub state (CCIP receiver on spoke chains)
    address public crossChainController;

    /// @notice Last hub-synced canonical YES price in 1e6 precision
    /// @dev Updated via syncCanonicalPriceFromHub() when in cross-chain mode
    uint256 public canonicalYesPriceE6;

    /// @notice Last hub-synced canonical NO price in 1e6 precision
    /// @dev Updated via syncCanonicalPriceFromHub() when in cross-chain mode
    uint256 public canonicalNoPriceE6;

    /// @notice Timestamp until canonical prices should be treated as fresh
    /// @dev If block.timestamp > canonicalPriceValidUntil, prices are considered stale
    uint256 public canonicalPriceValidUntil;

    /// @notice Monotonic nonce used to guard against stale/replayed price updates
    /// @dev Incremented each time syncCanonicalPriceFromHub() is called
    uint64 public canonicalPriceNonce;

      bytes32 private constant hashed_ResolveMarket = keccak256(abi.encodePacked("ResolveMarket"));


    // ========================================
    // CONSTRUCTOR
    // ========================================

    /**
     * @notice Initializes a new prediction market
     * @param _question The prediction question
     * @param _collateral Address of the ERC20 collateral token
     * @param _closeTime Timestamp when market closes for trading
     * @param _resolutionTime Timestamp when market can be resolved
     * @param _marketfactory Address of market facory the contract
     * @dev Creates YES and NO outcome tokens and sets initial state to Open
     */
    constructor(
        string memory _question,
        address _collateral,
        uint256 _closeTime,
        uint256 _resolutionTime,
        address _marketfactory,
        address _forwarderAddress
    ) ReceiverTemplate(_forwarderAddress) {
        // Validate constructor arguments
        if (_collateral == address(0) || _closeTime == 0 || _resolutionTime == 0 || bytes(_question).length == 0) {
            revert MarketErrors.PredictionMarket__InvalidArguments_PassedInConstructor();
        }

        // Ensure closeTime comes before resolutionTime
        if (_closeTime > _resolutionTime) {
            revert MarketErrors.PredictionMarket__CloseTimeGreaterThanResolutionTime();
        }

        // Set market configuration
        s_question = _question;
        i_collateral = IERC20(_collateral);
        closeTime = _closeTime;
        resolutionTime = _resolutionTime;

        // Deploy outcome tokens for YES and NO positions
        yesToken = new OutcomeToken("YES", "YES", address(this));
        noToken = new OutcomeToken("NO", "NO", address(this));

        // Initialize market as Open
        state = State.Open;

        // Store reference to the deploying factory so we can notify it on resolution
        marketFactory = MarketFactory(_marketfactory);
    }

    // ========================================
    // MODIFIERS
    // ========================================

    error PredictionMarket__OnlyCrossChainController();
    error PredictionMarket__InvalidCanonicalPrice();
    error PredictionMarket__StaleSyncMessage();
    error PredictionMarket__CanonicalPriceStale();
    error PredictionMarket__InsufficientSpokeInventory();
    error PredictionMarket__LocalResolutionDisabled();

    /**
     * @notice Ensures market is open for trading
     * @dev Updates state based on current timestamp before checking
     */
    modifier marketOpen() {
        _updateState();
        if (state == State.Resolved) {
            revert MarketErrors.PredictionMarket__AlreadyResolved();
        }
        if (state == State.Closed) {
            revert MarketErrors.PredictionMarket__Isclosed();
        }
        if (state == State.Review) {
            revert MarketErrors.PredictionMarket__IsUnderManualReview();
        }

        if (paused()) revert MarketErrors.PredictionMarket__IsPaused();
        _;
    }

    /**
     * @notice Ensures initial liquidity has been seeded
     * @dev Many operations require liquidity to function properly
     */
    modifier seededOnly() {
        if (!seeded) {
            revert MarketErrors.PredictionMarket__InitailConstantLiquidityNotSetYet();
        }
        _;
    }

    modifier zeroAmountCheck(uint256 amount) {
        if (amount == 0) {
            revert MarketErrors.PredictionMarket__AmountCantBeZero();
        }
        _;
    }

    modifier onlyCrossChainController() {
        if (msg.sender != crossChainController) {
            revert PredictionMarket__OnlyCrossChainController();
        }
        _;
    }

    // ========================================
    // INTERNAL FUNCTIONS
    // ========================================

    /**
     * @notice Updates market state based on current timestamp
     * @dev Automatically transitions from Open to Closed when closeTime is reached
     */
    function _updateState() internal {
        if (state == State.Open && block.timestamp >= closeTime) {
            state = State.Closed;
        }
    }

    /**
     * @notice Checks if market is operating in cross-chain canonical pricing mode
     * @return true if crossChainController is set, false otherwise
     * @dev When enabled, swaps use hub-provided prices instead of AMM reserves
     */
    function _isCanonicalPricingMode() internal view returns (bool) {
        return crossChainController != address(0);
    }

    /**
     * @notice Reverts if canonical prices are stale or not set
     * @dev Checks both nonce (must be > 0) and timestamp validity
     */
    function _ensureCanonicalPriceFresh() internal view {
        if (canonicalPriceNonce == 0 || block.timestamp > canonicalPriceValidUntil) {
            revert PredictionMarket__CanonicalPriceStale();
        }
    }

    function _revertIfLocalResolutionDisabled() internal view {
        if (crossChainController != address(0) && !marketFactory.isHubFactory()) {
            revert PredictionMarket__LocalResolutionDisabled();
        }
    }

    /**
     * @notice Calculates NO output for YES input using canonical hub prices
     * @param yesIn Amount of YES tokens to swap
     * @return netOut Amount of NO tokens received (after swap fee)
     * @return fee Swap fee amount deducted
     * @dev Uses hub-provided price ratio: noOut = yesIn * yesPrice / noPrice
     */
    function _quoteCanonicalYesForNo(uint256 yesIn) internal view returns (uint256 netOut, uint256 fee) {
        if (canonicalNoPriceE6 == 0 || canonicalYesPriceE6 == 0) {
            revert PredictionMarket__InvalidCanonicalPrice();
        }

        uint256 grossOut = (yesIn * canonicalYesPriceE6) / canonicalNoPriceE6;
        fee = (grossOut * MarketConstants.SWAP_FEE_BPS) / MarketConstants.FEE_PRECISION_BPS;
        netOut = grossOut - fee;
    }

    /**
     * @notice Calculates YES output for NO input using canonical hub prices
     * @param noIn Amount of NO tokens to swap
     * @return netOut Amount of YES tokens received (after swap fee)
     * @return fee Swap fee amount deducted
     * @dev Uses hub-provided price ratio: yesOut = noIn * noPrice / yesPrice
     */
    function _quoteCanonicalNoForYes(uint256 noIn) internal view returns (uint256 netOut, uint256 fee) {
        if (canonicalNoPriceE6 == 0 || canonicalYesPriceE6 == 0) {
            revert PredictionMarket__InvalidCanonicalPrice();
        }

        uint256 grossOut = (noIn * canonicalNoPriceE6) / canonicalYesPriceE6;
        fee = (grossOut * MarketConstants.SWAP_FEE_BPS) / MarketConstants.FEE_PRECISION_BPS;
        netOut = grossOut - fee;
    }

    // ========================================
    // LIQUIDITY MANAGEMENT FUNCTIONS
    // ========================================

    /**
     * @notice Seeds initial liquidity to the pool (owner only, one-time operation)
     * @param amount Amount of collateral to seed (contract must already hold this amount)
     * @dev Creates equal reserves of YES and NO tokens, mints them to the contract
     *      This establishes the initial constant product k = yesReserve * noReserve
     */
    function seedLiquidity(uint256 amount) external onlyOwner whenNotPaused {
        // Ensure liquidity hasn't been seeded already
        if (seeded) {
            revert MarketErrors.PredictionMarket__InitailConstantLiquidityAlreadySet();
        }
        if (amount == 0) {
            revert MarketErrors.PredictionMarket__InitailConstantLiquidityFundedAmountCantBeZero();
        }

        // Verify contract has sufficient collateral balance
        uint256 contractBalance = i_collateral.balanceOf(address(this));
        if (contractBalance < amount) {
            revert MarketErrors.PredictionMarket__FundingInitailAountGreaterThanAmountSent();
        }

        // Initialize pool with equal YES and NO reserves
        yesReserve = amount;
        noReserve = amount;
        seeded = true;

        // Mint initial LP shares to owner
        totalShares = amount;
        lpShares[msg.sender] = amount;

        // Mint outcome tokens to the pool
        yesToken.mint(address(this), amount);
        noToken.mint(address(this), amount);

        emit MarketEvents.LiquiditySeeded(amount);
    }

    /**
     * @notice Adds liquidity to the pool in exchange for LP shares
     * @param yesAmount Amount of YES tokens to add
     * @param noAmount Amount of NO tokens to add
     * @param minShares Minimum shares to receive (slippage protection)
     * @dev User must have sufficient YES and NO tokens
     *      Shares are calculated proportionally to maintain pool ratios
     */
    function addLiquidity(uint256 yesAmount, uint256 noAmount, uint256 minShares)
        external
        nonReentrant
        marketOpen
        seededOnly
        whenNotPaused
    {
        // Validate inputs
        if (yesAmount == 0 && noAmount == 0) {
            revert MarketErrors.PredictionMarket__AddLiquidity_YesAndNoCantBeZero();
        }
        if (
            yesAmount < MarketConstants.MINIMUM_ADD_LIQUIDITY_SHARE
                || noAmount < MarketConstants.MINIMUM_ADD_LIQUIDITY_SHARE
        ) {
            revert MarketErrors.PredictionMarket__AddLiquidity_Yes_No_LessThanMiniMum();
        }

        // Check user has sufficient token balances
        uint256 yesTokenBalance = yesToken.balanceOf(address(msg.sender));
        uint256 noTokenBalance = noToken.balanceOf(address(msg.sender));
        if (yesTokenBalance < yesAmount || noTokenBalance < noAmount) {
            revert MarketErrors.PredictionMarket__AddLiquidity_InsuffientTokenBalance();
        }

        // Calculate proportional shares using AMMLib
        (uint256 shares, uint256 usedYes, uint256 usedNo) =
            AMMLib.calculateShares(yesAmount, noAmount, totalShares, yesReserve, noReserve);

        // Ensure slippage tolerance is met
        if (shares < minShares) {
            revert MarketErrors.PredictionMarket__AddLiquidity_ShareSendingIsLessThanMinShares();
        }

        // Update pool reserves
        yesReserve += usedYes;
        noReserve += usedNo;

        // Mint LP shares to user
        totalShares += shares;
        lpShares[msg.sender] += shares;

        // Transfer tokens from user to pool
        IERC20(address(yesToken)).safeTransferFrom(msg.sender, address(this), usedYes);
        IERC20(address(noToken)).safeTransferFrom(msg.sender, address(this), usedNo);

        emit MarketEvents.LiquidityAdded(msg.sender, usedYes, usedNo, shares);
    }

    /**
     * @notice Removes liquidity from the pool by burning LP shares
     * @param shares Number of LP shares to burn
     * @param minYesOut Minimum YES tokens to receive (slippage protection)
     * @param minNoOut Minimum NO tokens to receive (slippage protection)
     * @dev Returns proportional amounts of YES and NO tokens based on share percentage
     */
    function removeLiquidity(uint256 shares, uint256 minYesOut, uint256 minNoOut)
        external
        nonReentrant
        seededOnly
        marketOpen
        whenNotPaused
    {
        uint256 userShares = lpShares[msg.sender];

        // Validate inputs
        if (shares == 0) {
            revert MarketErrors.PredictionMarket__WithDrawLiquidity_ZeroSharesPassedIn();
        }
        if (userShares < shares) {
            revert MarketErrors.PredictionMarket__WithDrawLiquidity_InsufficientSharesBalance();
        }

        // Calculate proportional outputs using AMMLib
        uint256 yesOut = AMMLib.calculateProportionalOutput(yesReserve, shares, totalShares);
        uint256 noOut = AMMLib.calculateProportionalOutput(noReserve, shares, totalShares);

        // Check slippage protection
        if (yesOut < minYesOut || noOut < minNoOut) {
            revert MarketErrors.PredictionMarket__WithDrawLiquidity_SlippageExceeded();
        }

        // Update LP shares
        lpShares[msg.sender] = userShares - shares;
        totalShares -= shares;

        // Update reserves AFTER calculating outputs
        yesReserve -= yesOut;
        noReserve -= noOut;

        // Transfer tokens to user
        IERC20(address(yesToken)).safeTransfer(msg.sender, yesOut);
        IERC20(address(noToken)).safeTransfer(msg.sender, noOut);

        emit MarketEvents.LiquidityRemoved(msg.sender, yesOut, noOut, shares);
    }

    /**
     * @notice Removes liquidity and automatically redeems matched pairs for collateral
     * @param shares Number of LP shares to burn
     * @param minCollateralOut Minimum collateral to receive after fees (slippage protection)
     * @dev This is a convenience function that combines removeLiquidity + redeemCompleteSets
     *      It burns matching YES/NO pairs for collateral and returns any leftover unmatched tokens
     *      Applies redemption fee on the matched sets
     */
    function removeLiquidityAndRedeemCollateral(uint256 shares, uint256 minCollateralOut)
        external
        nonReentrant
        seededOnly
        marketOpen
        whenNotPaused
    {
        uint256 userShares = lpShares[msg.sender];

        // Validate inputs
        if (shares == 0) {
            revert MarketErrors.PredictionMarket__WithDrawLiquidity_ZeroSharesPassedIn();
        }
        if (userShares < shares) {
            revert MarketErrors.PredictionMarket__WithDrawLiquidity_InsufficientSharesBalance();
        }

        // Step 1: Calculate proportional outputs using AMMLib
        uint256 yesOut = AMMLib.calculateProportionalOutput(yesReserve, shares, totalShares);
        uint256 noOut = AMMLib.calculateProportionalOutput(noReserve, shares, totalShares);

        // Step 2: Update LP balances and pool reserves
        lpShares[msg.sender] = userShares - shares;
        totalShares -= shares;
        yesReserve -= yesOut;
        noReserve -= noOut;

        emit MarketEvents.LiquidityRemoved(msg.sender, yesOut, noOut, shares);

        // Step 3: Calculate complete sets (matched YES/NO pairs)
        uint256 completeSets = yesOut < noOut ? yesOut : noOut;

        // Calculate redemption fee using FeeLib
        (uint256 netCollaterals, uint256 fee) = FeeLib.deductFee(
            completeSets, MarketConstants.REDEEM_COMPLETE_SETS_FEE_BPS, MarketConstants.FEE_PRECISION_BPS
        );

        // Check slippage protection
        if (netCollaterals < minCollateralOut) {
            revert MarketErrors.PredictionMarket__WithDrawLiquidity_SlippageExceeded();
        }

        // Add fee to protocol reserves
        protocolCollateralFees += fee;

        // Burn the matched YES/NO pairs from contract balance
        yesToken.burn(address(this), completeSets);
        noToken.burn(address(this), completeSets);

        // Step 4: Return any leftover unmatched tokens to user
        uint256 leftoverYes = yesOut - completeSets;
        uint256 leftoverNo = noOut - completeSets;

        if (leftoverYes > 0) {
            IERC20(address(yesToken)).safeTransfer(msg.sender, leftoverYes);
        }

        if (leftoverNo > 0) {
            IERC20(address(noToken)).safeTransfer(msg.sender, leftoverNo);
        }

        // Step 5: Transfer net collateral to user
        i_collateral.safeTransfer(msg.sender, netCollaterals);

        emit MarketEvents.CompleteSetsRedeemed(msg.sender, netCollaterals);
    }

    /**
     * @notice Withdraws collateral for liquidity providers after market resolution
     * @param shares Number of LP shares to burn for collateral redemption
     * @dev This function can only be called after the market is resolved to YES or NO (not Inconclusive)
     *      LPs receive collateral based on the winning outcome:
     *      - If YES won: LPs receive collateral proportional to their YES reserve share
     *      - If NO won: LPs receive collateral proportional to their NO reserve share
     *      The losing outcome tokens are worthless and remain in the pool
     *      No fees are charged on this withdrawal
     * @notice This differs from removeLiquidityAndRedeemCollateral which works during Open state
     */
    function withdrawLiquidityCollateral(uint256 shares) external nonReentrant whenNotPaused {
        if (state != State.Resolved) {
            revert MarketErrors.PredictionMarket__StateNeedToResolvedToWithdrawLiquidity();
        }

        uint256 resolutionOut = uint256(resolution);

        if (resolutionOut != uint256(Resolution.Yes) && resolutionOut != uint256(Resolution.No)) {
            revert MarketErrors.PredictionMarket__InvalidFinalOutcome();
        }

        uint256 userShares = lpShares[msg.sender];

        // Validate inputs
        if (shares == 0) {
            revert MarketErrors.PredictionMarket__WithDrawLiquidity_ZeroSharesPassedIn();
        }
        if (userShares < shares) {
            revert MarketErrors.PredictionMarket__WithDrawLiquidity_InsufficientSharesBalance();
        }

        if (resolutionOut == uint256(Resolution.Yes)) {
            uint256 winningOut = AMMLib.calculateProportionalOutput(yesReserve, shares, totalShares);
            totalShares -= shares;
            lpShares[msg.sender] = userShares - shares;

            yesReserve -= winningOut;

            // Burn the matched YES pair from contract balance
            yesToken.burn(address(this), winningOut);

            // Transfer net collateral to user
            i_collateral.safeTransfer(msg.sender, winningOut);

            emit MarketEvents.WithDrawnLiquidity(msg.sender, winningOut, shares);
        }

        if (resolutionOut == uint256(Resolution.No)) {
            uint256 noOut = AMMLib.calculateProportionalOutput(noReserve, shares, totalShares);
            totalShares -= shares;
            lpShares[msg.sender] = userShares - shares;

            noReserve -= noOut;

            // Burn the matched NO pair from contract balance
            noToken.burn(address(this), noOut);

            // Transfer net collateral to user
            i_collateral.safeTransfer(msg.sender, noOut);

            emit MarketEvents.WithDrawnLiquidity(msg.sender, noOut, shares);
        }
    }

    /**
     * @notice Transfers LP shares to another address
     * @param to Recipient address
     * @param shares Number of shares to transfer
     * @dev Allows users to transfer their LP position without removing liquidity
     */
    function transferShares(address to, uint256 shares) external whenNotPaused {
        // Validate inputs
        if (to == address(0)) {
            revert MarketErrors.PredictionMarket__TransferShares_CantbeSendtoZeroAddress();
        }
        if (lpShares[msg.sender] < shares) {
            revert MarketErrors.PredictionMarket__TransferShares_InsufficientShares();
        }

        // Update balances
        lpShares[msg.sender] -= shares;
        lpShares[to] += shares;

        emit MarketEvents.SharesTransferred(msg.sender, to, shares);
    }

    // ========================================
    // COMPLETE SETS FUNCTIONS
    // ========================================

    /**
     * @notice Mints a complete set of outcome tokens (1 YES + 1 NO) by depositing collateral
     * @param amount Amount of collateral to deposit
     * @dev User receives (amount - fee) of both YES and NO tokens
     *      This allows users to take positions or provide liquidity
     *      Fee goes to protocol
     */
    function mintCompleteSets(uint256 amount) external nonReentrant marketOpen zeroAmountCheck(amount) {
        if (amount < MarketConstants.MINIMUM_AMOUNT) {
            revert MarketErrors.PredictionMarket__MintingCompleteset__AmountLessThanMinimu();
        }

        // Check user has sufficient collateral
        uint256 userCollateralBalance = i_collateral.balanceOf(msg.sender);
        if (userCollateralBalance < amount) {
            revert MarketErrors.PredictionMarket__MintCompleteSets_InsuffientTokenBalance();
        }

        // Enforce per-user risk cap: each user can only commit up to MAX_RISK_EXPOSURE (10,000 USDC)
        // across all their mintCompleteSets calls in this market, preventing excessive concentration
        uint256 exposure = userRiskExposure[msg.sender];
        if (exposure + amount > MarketConstants.MAX_RISK_EXPOSURE) {
            revert MarketErrors.PredictionMarket__RiskExposureExceeded();
        }

        // Calculate fee and net amount using FeeLib
        (uint256 netAmount, uint256 fee) =
            FeeLib.deductFee(amount, MarketConstants.MINT_COMPLETE_SETS_FEE_BPS, MarketConstants.FEE_PRECISION_BPS);

        // Add fee to protocol reserves
        protocolCollateralFees += fee;
        userRiskExposure[msg.sender] += amount;

        // Transfer collateral from user
        i_collateral.safeTransferFrom(msg.sender, address(this), amount);

        // Mint equal amounts of YES and NO tokens to user
        yesToken.mint(msg.sender, netAmount);
        noToken.mint(msg.sender, netAmount);

        emit MarketEvents.CompleteSetsMinted(msg.sender, netAmount);
    }

    /**
     * @notice Redeems a complete set of outcome tokens for collateral
     * @param amount Amount of YES and NO tokens to burn
     * @dev User must have equal amounts of YES and NO tokens
     *      Receives (amount - fee) of collateral back
     *      This allows users to exit positions and retrieve collateral
     */
    function redeemCompleteSets(uint256 amount) external nonReentrant marketOpen whenNotPaused zeroAmountCheck(amount) {
        if (amount < MarketConstants.MINIMUM_AMOUNT) {
            revert MarketErrors.PredictionMarket__RedeemCompletesetLessThanMinAllowed();
        }
        // Check user has sufficient YES and NO tokens
        uint256 userNoBalance = noToken.balanceOf(msg.sender);
        uint256 userYesBalance = yesToken.balanceOf(msg.sender);
        if (userNoBalance < amount || userYesBalance < amount) {
            revert MarketErrors.PredictionMarket__redeemCompleteSets_InsuffientTokenBalance();
        }

        // Burn both YES and NO tokens from user
        yesToken.burn(msg.sender, amount);
        noToken.burn(msg.sender, amount);

        // Calculate fee and net amount using FeeLib
        (uint256 netAmount, uint256 fee) =
            FeeLib.deductFee(amount, MarketConstants.REDEEM_COMPLETE_SETS_FEE_BPS, MarketConstants.FEE_PRECISION_BPS);

        // Add fee to protocol reserves
        protocolCollateralFees += fee;

        // Transfer net collateral to user
        i_collateral.safeTransfer(msg.sender, netAmount);

        emit MarketEvents.CompleteSetsRedeemed(msg.sender, netAmount);
    }

    // ========================================
    // SWAP FUNCTIONS (AMM TRADING)
    // ========================================

    /**
     * @notice Swaps YES tokens for NO tokens using the AMM
     * @param yesIn Amount of YES tokens to swap
     * @param minNoOut Minimum NO tokens to receive (slippage protection)
     * @dev Uses constant product formula: k = yesReserve * noReserve
     *      Charges swap fee that stays in the pool (benefits LPs)
     */
    function swapYesForNo(uint256 yesIn, uint256 minNoOut)
        external
        nonReentrant
        marketOpen
        seededOnly
        whenNotPaused
        zeroAmountCheck(yesIn)
    {
        if (yesToken.balanceOf(msg.sender) < yesIn) {
            revert MarketErrors.PredictionMarket__SwapYesFoNo_YesExeedBalannce();
        }
        if (yesIn < MarketConstants.MINIMUM_SWAP_AMOUNT) {
            revert MarketErrors.PredictionMarket__AmountLessThanMinSwapAllwed();
        }

        uint256 noOut;
        uint256 newYesReserve;
        uint256 newNoReserve;

        if (_isCanonicalPricingMode()) {
            _ensureCanonicalPriceFresh();
            (noOut,) = _quoteCanonicalYesForNo(yesIn);
            if (noOut > noReserve) {
                revert PredictionMarket__InsufficientSpokeInventory();
            }

            newYesReserve = yesReserve + yesIn;
            newNoReserve = noReserve - noOut;
        } else {
            // Calculate swap output using AMMLib
            (noOut,, newYesReserve, newNoReserve) = AMMLib.getAmountOut(
                yesReserve, noReserve, yesIn, MarketConstants.SWAP_FEE_BPS, MarketConstants.FEE_PRECISION_BPS
            );
        }

        // Validate output meets slippage requirements
        if (minNoOut > noOut) {
            revert MarketErrors.PredictionMarket__SwapingExceedSlippage();
        }

        // Update reserves
        yesReserve = newYesReserve;
        noReserve = newNoReserve;

        // Transfer tokens
        IERC20(address(yesToken)).safeTransferFrom(msg.sender, address(this), yesIn);
        IERC20(address(noToken)).safeTransfer(msg.sender, noOut);

        emit MarketEvents.Trade(msg.sender, true, yesIn, noOut);
    }

    /**
     * @notice Swaps NO tokens for YES tokens using the AMM
     * @param noIn Amount of NO tokens to swap
     * @param minYesOut Minimum YES tokens to receive (slippage protection)
     * @dev Uses constant product formula: k = yesReserve * noReserve
     *      Charges swap fee that stays in the pool (benefits LPs)
     */
    function swapNoForYes(uint256 noIn, uint256 minYesOut)
        external
        nonReentrant
        marketOpen
        seededOnly
        whenNotPaused
        zeroAmountCheck(noIn)
    {
        if (noToken.balanceOf(msg.sender) < noIn) {
            revert MarketErrors.PredictionMarket__SwapNoFoYes_NoExeedBalannce();
        }
        if (noIn < MarketConstants.MINIMUM_SWAP_AMOUNT) {
            revert MarketErrors.PredictionMarket__AmountLessThanMinSwapAllwed();
        }

        uint256 yesOut;
        uint256 newNoReserve;
        uint256 newYesReserve;

        if (_isCanonicalPricingMode()) {
            _ensureCanonicalPriceFresh();
            (yesOut,) = _quoteCanonicalNoForYes(noIn);
            if (yesOut > yesReserve) {
                revert PredictionMarket__InsufficientSpokeInventory();
            }

            newNoReserve = noReserve + noIn;
            newYesReserve = yesReserve - yesOut;
        } else {
            // Calculate swap output using AMMLib
            (yesOut,, newNoReserve, newYesReserve) = AMMLib.getAmountOut(
                noReserve, yesReserve, noIn, MarketConstants.SWAP_FEE_BPS, MarketConstants.FEE_PRECISION_BPS
            );
        }

        // Validate output meets slippage requirements
        if (minYesOut > yesOut) {
            revert MarketErrors.PredictionMarket__SwapingExceedSlippage();
        }

        // Update reserves
        noReserve = newNoReserve;
        yesReserve = newYesReserve;

        // Transfer tokens
        IERC20(address(noToken)).safeTransferFrom(msg.sender, address(this), noIn);
        IERC20(address(yesToken)).safeTransfer(msg.sender, yesOut);

        emit MarketEvents.Trade(msg.sender, false, noIn, yesOut);
    }

    // ========================================
    // RESOLUTION & REDEMPTION FUNCTIONS
    // ========================================

    /**
     * @notice Resolves the market to a final outcome (owner only)
     * @param _outcome True for YES outcome, False for NO outcome
     * @dev Can only be called after resolutionTime and when market is Closed
     *      Once resolved, winning token holders can redeem for collateral
     */
    function resolve(Resolution _outcome, string memory proofUrl) external onlyOwner {
        _resolve(_outcome, proofUrl);
    }

    function _resolve(Resolution _outcome, string memory proofUrl) internal {
        _revertIfLocalResolutionDisabled();
        _updateState();
        if (bytes(proofUrl).length == 0) {
            revert MarketErrors.PredictionMarket__ProofUrlCantBeEmpty();
        }

        if (block.timestamp < resolutionTime) {
            revert MarketErrors.PredictionMarket__ResolveTimeNotReached();
        }

        if (state != State.Closed) {
            revert MarketErrors.PredictionMarket__MarketNotClosed();
        }

        if (_outcome == Resolution.Inconclusive) {
            manualReviewNeeded = true;
            state = State.Review;
            resolution = Resolution.Inconclusive;
            marketFactory.removeResolvedMarket(address(this));

            emit MarketEvents.IsUnderManualReview(_outcome);
            return;
        }

        resolution = _outcome;
        s_Proof_Url = proofUrl;

        state = State.Resolved;
        marketFactory.removeResolvedMarket(address(this));
        if (crossChainController != address(0) && marketFactory.isHubFactory()) {
            marketFactory.onHubMarketResolved(_outcome, proofUrl);
        }

        emit MarketEvents.Resolved(resolution);
    }

    /**
     * @notice Redeems winning outcome tokens for collateral after market resolution
     * @param amount Amount of winning tokens to redeem
     * @dev Can only be called after market is resolved
     *      If resolved to YES: burns YES tokens, returns collateral 1:1
     *      If resolved to NO: burns NO tokens, returns collateral 1:1
     *      Losing tokens become worthless
     */
    function redeem(uint256 amount) external nonReentrant whenNotPaused zeroAmountCheck(amount) {
        if (state != State.Resolved) {
            revert MarketErrors.PredictionMarket__NotResolved();
        }

        // Calculate redemption fee using FeeLib
        (uint256 netAmount, uint256 fee) =
            FeeLib.deductFee(amount, MarketConstants.REDEEM_COMPLETE_SETS_FEE_BPS, MarketConstants.FEE_PRECISION_BPS);

        // Add fee to protocol reserves
        protocolCollateralFees += fee;

        // Burn winning tokens and transfer collateral
        if (resolution == Resolution.Yes) {
            yesToken.burn(msg.sender, amount);
            i_collateral.safeTransfer(msg.sender, netAmount);
        } else if (resolution == Resolution.No) {
            noToken.burn(msg.sender, amount);
            i_collateral.safeTransfer(msg.sender, netAmount);
        }

        emit MarketEvents.Redeemed(msg.sender, amount);
    }

    /**
     * @notice Resolves the market after initial resolution was inconclusive and manual review
     * @param _outcome The final outcome determination (must be Yes or No, cannot be Inconclusive)
     * @param proofUrl URL to evidence/proof supporting the resolution decision
     * @dev This function can only be called by the owner after:
     *      1. The initial resolve() call set the outcome to Inconclusive
     *      2. The market state is Review
     *      3. manualReviewNeeded flag is true
     *      This provides a two-step resolution process for disputed or unclear outcomes
     *      Once manually resolved, the market moves to Resolved state and users can redeem
     */
    function manualResolveMarket(Resolution _outcome, string calldata proofUrl) external onlyOwner {
        _revertIfLocalResolutionDisabled();
        if (bytes(proofUrl).length == 0) {
            revert MarketErrors.PredictionMarket__ProofUrlCantBeEmpty();
        }

        if (state != State.Review) {
            revert MarketErrors.PredictionMarket__MarketNotInReview();
        }

        if (!manualReviewNeeded) {
            revert MarketErrors.PredictionMarket__ManualReviewNeeded();
        }

        if (_outcome == Resolution.Inconclusive) {
            revert MarketErrors.PredictionMarket__InvalidFinalOutcome();
        }

        resolution = _outcome;
        s_Proof_Url = proofUrl;

        manualReviewNeeded = false;
        state = State.Resolved;
        if (crossChainController != address(0) && marketFactory.isHubFactory()) {
            marketFactory.onHubMarketResolved(_outcome, proofUrl);
        }

        emit MarketEvents.Resolved(resolution);
    }

    /// @notice Sets the trusted contract that may push hub updates into this market
    /// @param controller Address of the cross-chain controller (typically the MarketFactory)
    /// @dev Automatically called by MarketFactory.createMarket() during deployment
    function setCrossChainController(address controller) external onlyOwner {
        crossChainController = controller;
    }

    /// @notice Applies hub resolution on spoke markets (CCIP path)
    /// @param _outcome The final resolution outcome (Yes or No, not Inconclusive)
    /// @param proofUrl URL to proof/evidence for the resolution
    /// @dev Only callable by crossChainController. Also calls marketFactory.removeResolvedMarket()
    function resolveFromHub(Resolution _outcome, string calldata proofUrl) external onlyCrossChainController {
        if (bytes(proofUrl).length == 0) {
            revert MarketErrors.PredictionMarket__ProofUrlCantBeEmpty();
        }
        if (_outcome == Resolution.Unset || _outcome == Resolution.Inconclusive) {
            revert MarketErrors.PredictionMarket__InvalidFinalOutcome();
        }
        if (state == State.Resolved) {
            revert MarketErrors.PredictionMarket__AlreadyResolved();
        }

        resolution = _outcome;
        s_Proof_Url = proofUrl;
        manualReviewNeeded = false;
        state = State.Resolved;
        marketFactory.removeResolvedMarket(address(this));

        emit MarketEvents.Resolved(resolution);
    }

    /// @notice Applies hub canonical prices to this market (used by UIs/quoting guards on spokes)
    function syncCanonicalPriceFromHub(uint256 yesPriceE6, uint256 noPriceE6, uint256 validUntil, uint64 nonce)
        external
        onlyCrossChainController
    {
        if (yesPriceE6 + noPriceE6 != MarketConstants.PRICE_PRECISION) {
            revert PredictionMarket__InvalidCanonicalPrice();
        }
        if (nonce <= canonicalPriceNonce) {
            revert PredictionMarket__StaleSyncMessage();
        }

        canonicalYesPriceE6 = yesPriceE6;
        canonicalNoPriceE6 = noPriceE6;
        canonicalPriceValidUntil = validUntil;
        canonicalPriceNonce = nonce;
    }

    /// @notice Internal hook invoked by Chainlink CRE forwarder when a settlement report arrives
    /// @dev Currently a no-op placeholder. When Chainlink CRE integration is fully wired,
    ///      this will decode the report and call resolve() automatically.
    /// @param report ABI-encoded settlement data (currently unused)
    function _processReport(bytes calldata report) internal override {
         (string memory actionType, bytes memory payload) = abi.decode(report, (string, bytes));
      bytes32 actionTypeHash = keccak256(abi.encodePacked(actionType));


        if (actionTypeHash != hashed_ResolveMarket) revert MarketErrors.PredictionMarket__InvalidReport();
 (Resolution _outcome, string memory _proofUrl) = abi.decode(payload, ( Resolution, string));


        _resolve(_outcome, _proofUrl);
    }

    /// @notice Checks whether the market has reached its resolution time
    /// @dev Called off-chain by Chainlink CRE to determine if the market is ready to be resolved.
    ///      Returns true only when the current timestamp has passed both closeTime and resolutionTime.
    /// @return resolveReady True if the market is eligible for resolution
    function checkResolutionTime() external returns (bool resolveReady) {
        _updateState();
        resolveReady = block.timestamp > closeTime && block.timestamp >= resolutionTime;
    }

    // ========================================
    // QUOTE/PREVIEW FUNCTIONS (READ-ONLY)
    // ========================================

    /**
     * @notice Previews the output of swapping YES for NO without executing
     * @param yesIn Amount of YES tokens to swap
     * @return netOut Amount of NO tokens that would be received (after fee)
     * @return fee Swap fee amount
     * @dev Useful for UI to show expected trade output before execution
     */
    function getYesForNoQuote(uint256 yesIn)
        external
        view
        zeroAmountCheck(yesIn)
        returns (uint256 netOut, uint256 fee)
    {
        if (yesIn == 0) {
            revert MarketErrors.PredictionMarket__AmountCantBeZero();
        }
        if (yesIn < MarketConstants.MINIMUM_SWAP_AMOUNT) {
            revert MarketErrors.PredictionMarket__AmountLessThanMinAllwed();
        }

        if (_isCanonicalPricingMode()) {
            _ensureCanonicalPriceFresh();
            (netOut, fee) = _quoteCanonicalYesForNo(yesIn);
            return (netOut, fee);
        }

        (netOut, fee,,) =
            AMMLib.getAmountOut(yesReserve, noReserve, yesIn, MarketConstants.SWAP_FEE_BPS, MarketConstants.FEE_PRECISION_BPS);
    }

    /**
     * @notice Previews the output of swapping NO for YES without executing
     * @param noIn Amount of NO tokens to swap
     * @return netOut Amount of YES tokens that would be received (after fee)
     * @return fee Swap fee amount
     * @dev Useful for UI to show expected trade output before execution
     */
    function getNoForYesQuote(uint256 noIn) external view zeroAmountCheck(noIn) returns (uint256 netOut, uint256 fee) {
        if (noIn < MarketConstants.MINIMUM_SWAP_AMOUNT) {
            revert MarketErrors.PredictionMarket__AmountLessThanMinAllwed();
        }

        if (_isCanonicalPricingMode()) {
            _ensureCanonicalPriceFresh();
            (netOut, fee) = _quoteCanonicalNoForYes(noIn);
            return (netOut, fee);
        }

        (netOut, fee,,) =
            AMMLib.getAmountOut(noReserve, yesReserve, noIn, MarketConstants.SWAP_FEE_BPS, MarketConstants.FEE_PRECISION_BPS);
    }

    /**
     * @notice Calculates the implied probability for the YES outcome based on current reserves
     * @return Implied probability scaled by PRICE_PRECISION (1e6 = 100%)
     * @dev Uses the formula: P(YES) = noReserve / (yesReserve + noReserve)
     */
    function getYesPriceProbability() external view returns (uint256) {
        if (!seeded) {
            revert MarketErrors.PredictionMarket__InitailConstantLiquidityNotSetYet();
        }

        if (_isCanonicalPricingMode()) {
            _ensureCanonicalPriceFresh();
            return canonicalYesPriceE6;
        }

        return AMMLib.getYesProbability(yesReserve, noReserve, MarketConstants.PRICE_PRECISION);
    }

    /**
     * @notice Calculates the implied probability for the NO outcome based on current reserves
     * @return Implied probability scaled by PRICE_PRECISION (1e6 = 100%)
     * @dev Uses the formula: P(NO) = yesReserve / (yesReserve + noReserve)
     */
    function getNoPriceProbability() external view returns (uint256) {
        if (!seeded) {
            revert MarketErrors.PredictionMarket__InitailConstantLiquidityNotSetYet();
        }

        if (_isCanonicalPricingMode()) {
            _ensureCanonicalPriceFresh();
            return canonicalNoPriceE6;
        }

        return AMMLib.getNoProbability(yesReserve, noReserve, MarketConstants.PRICE_PRECISION);
    }

    // ========================================
    // ADMIN/EMERGENCY FUNCTIONS
    // ========================================

    /**
     * @notice Pauses the contract (owner only)
     * @dev Prevents most user actions when paused
     */
    function pause() external onlyOwner {
        _pause();
    }

    /**
     * @notice Unpauses the contract (owner only)
     * @dev Resumes normal contract operations
     */
    function unpause() external onlyOwner {
        _unpause();
    }

    /**
     * @notice Withdraws accumulated protocol fees (owner only)
     * @param amount Amount of collateral fees to withdraw
     * @dev Can only be called after market is resolved
     *      Protocol fees accumulate from:
     *      - Swap fees (portion kept in reserves)
     *      - Complete set minting fees
     *      - Complete set redemption fees
     *      - Winning token redemption fees
     *      Owner must ensure sufficient balance exists before withdrawal
     */
    function withdrawProtocolFees(uint256 amount) external zeroAmountCheck(amount) onlyOwner {
        if (state != State.Resolved) {
            revert MarketErrors.PredictionMarket__StateNeedToResolvedToWithdrawLiquidity();
        }

        uint256 contractBalance = i_collateral.balanceOf(address(this));

        if (protocolCollateralFees < amount) {
            revert MarketErrors.PredictionMarket__WithDrawLiquidity_Insufficientfee();
        }

        if (contractBalance < amount) {
            revert MarketErrors.PredictionMarket__WithDrawLiquidity_Insufficientfee();
        }

        i_collateral.safeTransfer(owner(), amount);
        protocolCollateralFees -= amount;
    }
}
