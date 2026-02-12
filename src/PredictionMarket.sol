// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

// ========================================
// IMPORTS
// ========================================

// OpenZeppelin ERC20 utilities for safe token operations
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {
    SafeERC20
} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

// OpenZeppelin security and access control utilities
import {
    ReentrancyGuard
} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

// Custom outcome token for YES/NO positions
import {OutcomeToken} from "./OutcomeToken.sol";

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
contract PredictionMarket is Ownable, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    // ========================================
    // TYPE DECLARATIONS
    // ========================================

    /// @notice Market state lifecycle
    enum State {
        Open, // Market is active for trading
        Closed, // Market closed for trading, awaiting resolution
        Resolved // Outcome determined, users can redeem winning tokens
    }

    /// @notice Possible market resolution outcomes
    enum Resolution {
        Unset, // Not yet resolved
        Yes, // YES outcome won
        No, // NO outcome won
        Invalid // Market invalidated (currently commented out in redeem logic)
    }

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

    /* ─────────── Fee Configuration (in Basis Points) ─────────── */

    /// @notice Swap fee in basis points (400 = 4%)
    uint256 private constant SWAP_FEE_BPS = 400;

    /// @notice Fee for minting complete sets in basis points (300 = 3%)
    uint256 private constant MINT_COMPLETE_SETS_FEE_BPS = 300;

    /// @notice Fee for redeeming complete sets in basis points (200 = 2%)
    uint256 private constant REDEEM_COMPLETE_SETS_FEE_BPS = 200;

    /// @notice Basis points precision (10,000 = 100%)
    uint256 private constant FEE_PRECISION_BPS = 10_000;

    /// @notice Minimum amount required to add liquidity (prevents dust)
    uint256 private constant MINIMUM_ADD_LIQUIDITY_SHARE = 50;

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

    /* ─────────── Market State ─────────── */

    /// @notice Current market state (Open/Closed/Resolved)
    State public state;

    /// @notice Current market resolution outcome
    Resolution public resolution;

    /* ─────────── Minimum Amounts ─────────── */

    /// @notice Minimum amount for minting/redeeming complete sets (1 USDC with 6 decimals)
    uint256 private constant MINIMUM_AMOUNT = 1e6;

    /// @notice Minimum amount for swaps (0.97 USDC with 6 decimals)
    uint256 private constant MINIMUM_SWAP_AMOUNT = 970_000;

    // ========================================
    // EVENTS
    // ========================================

    /// @notice Emitted when a user swaps YES for NO or NO for YES
    event Trade(
        address indexed user,
        bool yesForNo,
        uint256 amountIn,
        uint256 amountOut
    );

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
    event LiquidityAdded(
        address indexed user,
        uint256 yesAmount,
        uint256 noAmount,
        uint256 shares
    );

    /// @notice Emitted when liquidity is removed from the pool
    event LiquidityRemoved(
        address indexed user,
        uint256 yesAmount,
        uint256 noAmount,
        uint256 shares
    );

    /// @notice Emitted when LP shares are transferred between addresses
    event SharesTransferred(
        address indexed from,
        address indexed to,
        uint256 shares
    );

    // ========================================
    // ERRORS
    // ========================================

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
    error PredictionMarket__AmountLessThanMinAllwed();

    // ========================================
    // CONSTRUCTOR
    // ========================================

    /**
     * @notice Initializes a new prediction market
     * @param _question The prediction question
     * @param _collateral Address of the ERC20 collateral token
     * @param _closeTime Timestamp when market closes for trading
     * @param _resolutionTime Timestamp when market can be resolved
     * @param owner_ Address that will own the contract
     * @dev Creates YES and NO outcome tokens and sets initial state to Open
     */
    constructor(
        string memory _question,
        address _collateral,
        uint256 _closeTime,
        uint256 _resolutionTime,
        address owner_
    ) Ownable(msg.sender) {
        // Validate constructor arguments
        if (
            _collateral == address(0) ||
            _closeTime == 0 ||
            _resolutionTime == 0 ||
            bytes(_question).length == 0
        ) {
            revert PredictionMarket__InvalidArguments_PassedInConstructor();
        }

        // Ensure closeTime comes before resolutionTime
        if (_closeTime > _resolutionTime) {
            revert PredictionMarket__CloseTimeGreaterThanResolutionTime();
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

        // Transfer ownership to designated owner
        _transferOwnership(owner_);
    }

    // ========================================
    // MODIFIERS
    // ========================================

    /**
     * @notice Ensures market is open for trading
     * @dev Updates state based on current timestamp before checking
     */
    modifier marketOpen() {
        _updateState();
        require(state == State.Open, "Market closed");
        if (state == State.Closed) revert PredictionMarket__Isclosed();
        if (paused()) revert PredictionMarket__IsPaused();
        _;
    }

    /**
     * @notice Ensures initial liquidity has been seeded
     * @dev Many operations require liquidity to function properly
     */
    modifier seededOnly() {
        if (!seeded)
            revert PredictionMarket__InitailConstantLiquidityNotSetYet();
        _;
    }

    modifier zeroAmountCheck(uint256 amount) {
        if (amount == 0) revert PredictionMarket__AmountCantBeZero();

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
        if (seeded)
            revert PredictionMarket__InitailConstantLiquidityAlreadySet();
        if (amount == 0)
            revert PredictionMarket__InitailConstantLiquidityFundedAmountCantBeZero();

        // Verify contract has sufficient collateral balance
        uint256 contractBalance = i_collateral.balanceOf(address(this));
        if (contractBalance < amount)
            revert PredictionMarket__FundingInitailAountGreaterThanAmountSent();

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

        emit LiquiditySeeded(amount);
    }

    /**
     * @notice Adds liquidity to the pool in exchange for LP shares
     * @param yesAmount Amount of YES tokens to add
     * @param noAmount Amount of NO tokens to add
     * @param minShares Minimum shares to receive (slippage protection)
     * @dev User must have sufficient YES and NO tokens
     *      Shares are calculated proportionally to maintain pool ratios
     *      Contract is paused during operation to prevent state changes
     */
    function addLiquidity(
        uint256 yesAmount,
        uint256 noAmount,
        uint256 minShares
    ) external nonReentrant marketOpen seededOnly {
        // Validate inputs
        if (yesAmount == 0 && noAmount == 0)
            revert PredictionMarket__AddLiquidity_YesAndNoCantBeZero();
        if (
            yesAmount < MINIMUM_ADD_LIQUIDITY_SHARE ||
            noAmount < MINIMUM_ADD_LIQUIDITY_SHARE
        ) {
            revert PredictionMarket__AddLiquidity_Yes_No_LessThanMiniMum();
        }

        // Check user has sufficient token balances
        uint256 yesTokenBalance = yesToken.balanceOf(address(msg.sender));
        uint256 noTokenBalance = noToken.balanceOf(address(msg.sender));
        if (yesTokenBalance < yesAmount || noTokenBalance < noAmount) {
            revert PredictionMarket__AddLiquidity_InsuffientTokenBalance();
        }

        // Pause contract to prevent reentrancy/state changes
        _pause();

        // Calculate proportional shares based on current pool ratios
        // Take the minimum to ensure both reserves increase proportionally
        uint256 yesShare = (yesAmount * totalShares) / yesReserve;
        uint256 noShare = (noAmount * totalShares) / noReserve;
        uint256 shares = yesShare < noShare ? yesShare : noShare;

        // Ensure slippage tolerance is met

        if (shares < minShares)
            revert PredictionMarket__AddLiquidity_ShareSendingIsLessThanMinShares();

        // Calculate actual tokens used (may be less than requested to maintain ratios)
        uint256 usedYes = (shares * yesReserve) / totalShares;
        uint256 usedNo = (shares * noReserve) / totalShares;

        // Update pool reserves
        yesReserve += usedYes;
        noReserve += usedNo;

        // Mint LP shares to user
        totalShares += shares;
        lpShares[msg.sender] += shares;

        // Transfer tokens from user to pool
        IERC20(address(yesToken)).safeTransferFrom(
            msg.sender,
            address(this),
            usedYes
        );
        IERC20(address(noToken)).safeTransferFrom(
            msg.sender,
            address(this),
            usedNo
        );

        // Unpause contract
        _unpause();

        emit LiquidityAdded(msg.sender, usedYes, usedNo, shares);
    }

    /**
     * @notice Removes liquidity from the pool by burning LP shares
     * @param shares Number of LP shares to burn
     * @param minYesOut Minimum YES tokens to receive (slippage protection)
     * @param minNoOut Minimum NO tokens to receive (slippage protection)
     * @dev Returns proportional amounts of YES and NO tokens based on share percentage
     */
    function removeLiquidity(
        uint256 shares,
        uint256 minYesOut,
        uint256 minNoOut
    ) external nonReentrant seededOnly marketOpen whenNotPaused {
        uint256 userShares = lpShares[msg.sender];

        // Validate inputs
        if (shares == 0)
            revert PredictionMarket__WithDrawLiquidity_ZeroSharesPassedIn();
        if (userShares < shares)
            revert PredictionMarket__WithDrawLiquidity_InsufficientSharesBalance();

        // Calculate proportional outputs BEFORE updating state
        uint256 yesOut = (yesReserve * shares) / totalShares;
        uint256 noOut = (noReserve * shares) / totalShares;

        // Check slippage protection
        if (yesOut < minYesOut || noOut < minNoOut)
            revert PredictionMarket__WithDrawLiquidity_SlippageExceeded();

        // Update LP shares
        lpShares[msg.sender] = userShares - shares;
        totalShares -= shares;

        // Update reserves AFTER calculating outputs
        yesReserve -= yesOut;
        noReserve -= noOut;

        // Transfer tokens to user
        IERC20(address(yesToken)).safeTransfer(msg.sender, yesOut);
        IERC20(address(noToken)).safeTransfer(msg.sender, noOut);

        emit LiquidityRemoved(msg.sender, yesOut, noOut, shares);
    }

    /**
     * @notice Removes liquidity and automatically redeems matched pairs for collateral
     * @param shares Number of LP shares to burn
     * @param minCollateralOut Minimum collateral to receive after fees (slippage protection)
     * @dev This is a convenience function that combines removeLiquidity + redeemCompleteSets
     *      It burns matching YES/NO pairs for collateral and returns any leftover unmatched tokens
     *      Applies redemption fee on the matched sets
     */
    function removeLiquidityAndRedeemCollateral(
        uint256 shares,
        uint256 minCollateralOut
    ) external nonReentrant seededOnly marketOpen whenNotPaused {
        uint256 userShares = lpShares[msg.sender];

        // Validate inputs
        if (shares == 0)
            revert PredictionMarket__WithDrawLiquidity_ZeroSharesPassedIn();
        if (userShares < shares)
            revert PredictionMarket__WithDrawLiquidity_InsufficientSharesBalance();

        // Step 1: Calculate proportional outputs
        uint256 yesOut = (yesReserve * shares) / totalShares;
        uint256 noOut = (noReserve * shares) / totalShares;

        // Step 2: Update LP balances and pool reserves
        lpShares[msg.sender] = userShares - shares;
        totalShares -= shares;
        yesReserve -= yesOut;
        noReserve -= noOut;

        emit LiquidityRemoved(msg.sender, yesOut, noOut, shares);

        // Step 3: Calculate complete sets (matched YES/NO pairs)
        // A complete set is 1 YES + 1 NO token, which equals 1 collateral
        uint256 completeSets = yesOut < noOut ? yesOut : noOut;

        // Calculate redemption fee
        uint256 fee = (completeSets * REDEEM_COMPLETE_SETS_FEE_BPS) /
            FEE_PRECISION_BPS;
        uint256 netCollaterals = completeSets - fee;

        // Check slippage protection
        if (netCollaterals < minCollateralOut)
            revert PredictionMarket__WithDrawLiquidity_SlippageExceeded();

        // Add fee to protocol reserves
        protocolCollateralFees += fee;

        // Burn the matched YES/NO pairs from contract balance
        yesToken.burn(address(this), completeSets);
        noToken.burn(address(this), completeSets);

        // Step 4: Return any leftover unmatched tokens to user
        // This happens when yesOut != noOut
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

        emit CompleteSetsRedeemed(msg.sender, netCollaterals);
    }

    /**
     * @notice Transfers LP shares to another address
     * @param to Recipient address
     * @param shares Number of shares to transfer
     * @dev Allows users to transfer their LP position without removing liquidity
     */
    function transferShares(address to, uint256 shares) external whenNotPaused {
        // Validate inputs
        if (to == address(0))
            revert PredictionMarket__TransferShares_CantbeSendtoZeroAddress();
        if (lpShares[msg.sender] < shares)
            revert PredictionMarket__TransferShares_InsufficientShares();

        // Update balances
        lpShares[msg.sender] -= shares;
        lpShares[to] += shares;

        emit SharesTransferred(msg.sender, to, shares);
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
    function mintCompleteSets(
        uint256 amount
    ) external nonReentrant marketOpen zeroAmountCheck(amount) {
        // Validate input

        if (amount < MINIMUM_AMOUNT)
            revert PredictionMarket__MintingCompleteset__AmountLessThanMinimu();

        // Check user has sufficient collateral
        uint256 userCollateralBalance = i_collateral.balanceOf(msg.sender);
        if (userCollateralBalance < amount)
            revert PredictionMarket__MintCompleteSets_InsuffientTokenBalance();

        // Calculate fee and net amount
        uint256 fee = (amount * MINT_COMPLETE_SETS_FEE_BPS) / FEE_PRECISION_BPS;
        uint256 netAmount = amount - fee;

        // Add fee to protocol reserves
        protocolCollateralFees += fee;

        // Transfer collateral from user
        i_collateral.safeTransferFrom(msg.sender, address(this), amount);

        // Mint equal amounts of YES and NO tokens to user
        yesToken.mint(msg.sender, netAmount);
        noToken.mint(msg.sender, netAmount);

        emit CompleteSetsMinted(msg.sender, netAmount);
    }

    /**
     * @notice Redeems a complete set of outcome tokens for collateral
     * @param amount Amount of YES and NO tokens to burn
     * @dev User must have equal amounts of YES and NO tokens
     *      Receives (amount - fee) of collateral back
     *      This allows users to exit positions and retrieve collateral
     */
    function redeemCompleteSets(
        uint256 amount
    ) external nonReentrant marketOpen whenNotPaused zeroAmountCheck(amount) {
        if (amount < MINIMUM_AMOUNT)
            revert PredictionMarket__RedeemCompletesetLessThanMinAllowed();
        // Check user has sufficient YES and NO tokens
        uint256 userNoBalance = noToken.balanceOf(msg.sender);
        uint256 userYesBalance = yesToken.balanceOf(msg.sender);
        if (userNoBalance < amount || userYesBalance < amount) {
            revert PredictionMarket__redeemCompleteSets_InsuffientTokenBalance();
        }

        // Burn both YES and NO tokens from user
        yesToken.burn(msg.sender, amount);
        noToken.burn(msg.sender, amount);

        // Calculate fee and net amount
        uint256 fee = (amount * REDEEM_COMPLETE_SETS_FEE_BPS) /
            FEE_PRECISION_BPS;
        uint256 netAmount = amount - fee;

        // Add fee to protocol reserves
        protocolCollateralFees += fee;

        // Transfer net collateral to user
        i_collateral.safeTransfer(msg.sender, netAmount);

        emit CompleteSetsRedeemed(msg.sender, netAmount);
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
    function swapYesForNo(
        uint256 yesIn,
        uint256 minNoOut
    )
        external
        nonReentrant
        marketOpen
        seededOnly
        whenNotPaused
        zeroAmountCheck(yesIn)
    {
        if (yesToken.balanceOf(msg.sender) < yesIn)
            revert PredictionMarket__SwapYesFoNo_YesExeedBalannce();
        if (yesIn < MINIMUM_SWAP_AMOUNT)
            revert PredictionMarket__AmountLessThanMinSwapAllwed();

        // Execute swap and transfer tokens
        uint256 noOut = _swapYesForNoFromPool(yesIn, minNoOut, msg.sender);
        IERC20(address(yesToken)).safeTransferFrom(
            msg.sender,
            address(this),
            yesIn
        );

        emit Trade(msg.sender, true, yesIn, noOut);
    }

    /**
     * @notice Swaps NO tokens for YES tokens using the AMM
     * @param noIn Amount of NO tokens to swap
     * @param minYesOut Minimum YES tokens to receive (slippage protection)
     * @dev Uses constant product formula: k = yesReserve * noReserve
     *      Charges swap fee that stays in the pool (benefits LPs)
     */
    function swapNoForYes(
        uint256 noIn,
        uint256 minYesOut
    )
        external
        nonReentrant
        marketOpen
        seededOnly
        whenNotPaused
        zeroAmountCheck(noIn)
    {
        if (noToken.balanceOf(msg.sender) < noIn)
            revert PredictionMarket__SwapNoFoYes_NoExeedBalannce();
        if (noIn < MINIMUM_SWAP_AMOUNT)
            revert PredictionMarket__AmountLessThanMinSwapAllwed();

        // Execute swap and transfer tokens
        uint256 yesOut = _swapNoForYesFromPool(noIn, minYesOut, msg.sender);
        IERC20(address(noToken)).safeTransferFrom(
            msg.sender,
            address(this),
            noIn
        );

        emit Trade(msg.sender, false, noIn, yesOut);
    }

    /**
     * @notice Internal function to execute YES -> NO swap
     * @param yesIn Amount of YES tokens input
     * @param minNoOut Minimum NO tokens output
     * @param recipient Address to receive NO tokens
     * @return netOut Actual NO tokens output after fee
     * @dev Implements constant product market maker formula
     *      Fee is added to the NO reserve rather than output (benefits LPs)
     */
    function _swapYesForNoFromPool(
        uint256 yesIn,
        uint256 minNoOut,
        address recipient
    ) internal returns (uint256 netOut) {
        // Calculate constant product k
        uint256 k = yesReserve * noReserve;

        // Calculate new reserves after input
        uint256 newYes = yesReserve + yesIn;
        uint256 newNo = k / newYes; // Maintain k = x * y

        // Calculate gross output
        uint256 grossOut = noReserve - newNo;

        // Deduct swap fee from output
        uint256 fee = (grossOut * SWAP_FEE_BPS) / FEE_PRECISION_BPS;
        netOut = grossOut - fee;

        // Validate output meets slippage requirements

        if (minNoOut > netOut) revert PredictionMarket__SwapingExceedSlippage();

        // Update reserves (fee stays in pool)
        yesReserve = newYes;
        noReserve = newNo + fee; // Fee is added back to reserve

        // Transfer NO tokens to recipient
        IERC20(address(noToken)).safeTransfer(recipient, netOut);
    }

    /**
     * @notice Internal function to execute NO -> YES swap
     * @param noIn Amount of NO tokens input
     * @param minYesOut Minimum YES tokens output
     * @param recipient Address to receive YES tokens
     * @return netOut Actual YES tokens output after fee
     * @dev Implements constant product market maker formula
     *      Fee is added to the YES reserve rather than output (benefits LPs)
     */
    function _swapNoForYesFromPool(
        uint256 noIn,
        uint256 minYesOut,
        address recipient
    ) internal returns (uint256 netOut) {
        // Calculate constant product k
        uint256 k = yesReserve * noReserve;

        // Calculate new reserves after input
        uint256 newNo = noReserve + noIn;
        uint256 newYes = k / newNo; // Maintain k = x * y

        // Calculate gross output
        uint256 grossOut = yesReserve - newYes;

        // Deduct swap fee from output
        uint256 fee = (grossOut * SWAP_FEE_BPS) / FEE_PRECISION_BPS;
        netOut = grossOut - fee;

        // Validate output meets slippage requirements

        if (minYesOut > netOut)
            revert PredictionMarket__SwapingExceedSlippage();

        // Update reserves (fee stays in pool)
        noReserve = newNo;
        yesReserve = newYes + fee; // Fee is added back to reserve

        // Transfer YES tokens to recipient
        IERC20(address(yesToken)).safeTransfer(recipient, netOut);
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
    function resolve(bool _outcome) external onlyOwner {
        _updateState();

        // Validate resolution timing and state
        require(block.timestamp >= resolutionTime, "Too early");
        require(state != State.Resolved, "Already resolved");
        require(state == State.Closed, "Market still open");

        // Set resolution outcome
        resolution = _outcome ? Resolution.Yes : Resolution.No;
        state = State.Resolved;

        emit Resolved(resolution);
    }

    /**
     * @notice Redeems winning outcome tokens for collateral after market resolution
     * @param amount Amount of winning tokens to redeem
     * @dev Can only be called after market is resolved
     *      If resolved to YES: burns YES tokens, returns collateral 1:1
     *      If resolved to NO: burns NO tokens, returns collateral 1:1
     *      Losing tokens become worthless
     */
    function redeem(uint256 amount) external nonReentrant whenNotPaused {
        // Validate market is resolved
        require(state == State.Resolved, "Not resolved");
        require(amount > 0, "Zero amount");

        // Redeem based on resolution outcome
        if (resolution == Resolution.Yes) {
            // YES won: burn YES tokens, return collateral
            yesToken.burn(msg.sender, amount);
            i_collateral.safeTransfer(msg.sender, amount);
        } else if (resolution == Resolution.No) {
            // NO won: burn NO tokens, return collateral
            noToken.burn(msg.sender, amount);
            i_collateral.safeTransfer(msg.sender, amount);
        } else if (resolution == Resolution.Invalid) {
            // Invalid outcome: use separate function (currently disabled)
            revert("Use redeemInvalid");
        } else {
            revert("Invalid resolution");
        }

        emit Redeemed(msg.sender, amount);
    }

    // NOTE: Invalid market resolution currently disabled
    // If enabled, would allow 50% redemption for both YES and NO holders
    // function redeemInvalid(bool redeemYes, uint256 amount) external nonReentrant whenNotPaused {
    //     require(state == State.Resolved, "Not resolved");
    //     require(resolution == Resolution.Invalid, "Not invalid");
    //     require(amount > 0, "Zero amount");
    //
    //     if (redeemYes) {
    //         yesToken.burn(msg.sender, amount);
    //     } else {
    //         noToken.burn(msg.sender, amount);
    //     }
    //
    //     i_collateral.safeTransfer(msg.sender, amount / 2);
    //
    //     emit Redeemed(msg.sender, amount / 2);
    // }

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
    function getYesForNoQuote(
        uint256 yesIn
    )
        external
        view
        zeroAmountCheck(yesIn)
        returns (uint256 netOut, uint256 fee)
    {
        if (yesIn == 0) revert PredictionMarket__AmountCantBeZero();
        if (yesIn < MINIMUM_SWAP_AMOUNT)
            revert PredictionMarket__AmountLessThanMinAllwed();

        uint256 noReserved = noReserve;

        // Calculate using constant product formula
        uint256 k = yesReserve * noReserved;
        uint256 newYes = yesReserve + yesIn;
        uint256 newNo = k / newYes;
        uint256 grossOut = noReserved - newNo;

        // Calculate fee
        fee = (grossOut * SWAP_FEE_BPS) / FEE_PRECISION_BPS;
        netOut = grossOut - fee;
    }

    /**
     * @notice Previews the output of swapping NO for YES without executing
     * @param noIn Amount of NO tokens to swap
     * @return netOut Amount of YES tokens that would be received (after fee)
     * @return fee Swap fee amount
     * @dev Useful for UI to show expected trade output before execution
     */
    function getNoForYesQuote(
        uint256 noIn
    )
        external
        view
        zeroAmountCheck(noIn)
        returns (uint256 netOut, uint256 fee)
    {
        if (noIn < MINIMUM_SWAP_AMOUNT)
            revert PredictionMarket__AmountLessThanMinAllwed();

        uint256 yesReserved = yesReserve;

        // Calculate using constant product formula
        uint256 k = yesReserved * noReserve;
        uint256 newNo = noReserve + noIn;
        uint256 newYes = k / newNo;
        uint256 grossOut = yesReserved - newYes;

        // Calculate fee
        fee = (grossOut * SWAP_FEE_BPS) / FEE_PRECISION_BPS;
        netOut = grossOut - fee;
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
}
