// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

// ========================================
// IMPORTS
// ========================================

// OpenZeppelin ERC20 utilities for safe token operations
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

// OpenZeppelin security and access control utilities
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

// Custom outcome token for YES/NO positions
import {OutcomeToken} from "./OutcomeToken.sol";

// Protocol libraries
import {State, Resolution, MarketConstants, MarketEvents, MarketErrors} from "./libraries/MarketTypes.sol";
import {AMMLib} from "./libraries/AMMLib.sol";
import {FeeLib} from "./libraries/FeeLib.sol";
import {CanonicalPricingModule} from "./modules/CanonicalPricingModule.sol";
import {MarketFactory} from "src/MarketFactory.sol";
import {ReceiverTemplateUpgradeable} from "script/interfaces/ReceiverTemplateUpgradeable.sol";

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
contract PredictionMarket is Initializable, ReentrancyGuard, PausableUpgradeable, ReceiverTemplateUpgradeable {
    using SafeERC20 for IERC20;

    // ========================================
    // STATE VARIABLES
    // ========================================

    /* ─────────── Market Configuration ─────────── */

    /// @notice The prediction question for this market
    string public  s_question;

    /// @notice URL to proof/evidence for market resolution
    string public s_Proof_Url;

    /// @notice The ERC20 token used as collateral (e.g., USDC, DAI)
    IERC20 public i_collateral;

    /// @notice YES outcome token contract
    OutcomeToken public yesToken;

    /// @notice NO outcome token contract
    OutcomeToken public noToken;

    /// @notice Timestamp when market closes for trading
    uint256 public closeTime;

    /// @notice Timestamp when market can be resolved by owner
    uint256 public resolutionTime;

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
    /// @notice Optional addresses exempt from MAX_RISK_EXPOSURE enforcement
    mapping(address => bool) public isRiskExempt;

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

    // ========================================
    // CROSS-CHAIN PRICING STATE
    // ========================================

    /// @notice Optional controller allowed to push hub state (CCIP receiver on spoke chains)
    /// @dev When set, market operates in canonical pricing mode using hub-provided prices
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

    // ========================================
    // DEVIATION BAND THRESHOLDS
    // ========================================
    // These control how the market responds when local AMM prices diverge from canonical hub prices

    /// @notice Deviation threshold in bps for normal operations (no restrictions)
    uint16 public softDeviationBps;
    /// @notice Deviation threshold in bps where stress controls become active (extra fees + output caps)
    uint16 public stressDeviationBps;
    /// @notice Deviation threshold in bps above which swaps are hard-stopped (circuit breaker)
    uint16 public hardDeviationBps;
    /// @notice Additional fee (bps) applied in stress/unsafe bands to disincentivize large trades
    uint16 public stressExtraFeeBps;
    /// @notice Max output size as bps of output reserve in stress band (2% of reserve)
    uint16 public stressMaxOutBps;
    /// @notice Max output size as bps of output reserve in unsafe band (0.5% of reserve)
    uint16 public unsafeMaxOutBps;

    bytes32 private constant hashed_ResolveMarket = keccak256(abi.encodePacked("ResolveMarket"));


    // ========================================
    // INITIALIZATION
    // ========================================

    /**
     * @notice Locks the implementation contract for direct initialization
     */
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initializes a new prediction market clone
     * @param _question The prediction question
     * @param _collateral Address of the ERC20 collateral token
     * @param _closeTime Timestamp when market closes for trading
     * @param _resolutionTime Timestamp when market can be resolved
     * @param _marketfactory Address of market facory the contract
     * @param _forwarderAddress Forwarder allowed to call onReport
     * @param _initialOwner Initial market owner
     * @dev Creates YES and NO outcome tokens and sets initial state to Open
     */
    function initialize(
        string memory _question,
        address _collateral,
        uint256 _closeTime,
        uint256 _resolutionTime,
        address _marketfactory,
        address _forwarderAddress,
        address _initialOwner
    ) external initializer {
        __Pausable_init();
        __ReceiverTemplateUpgradeable_init(_forwarderAddress, _initialOwner);

        // Validate initialization arguments
        if (
            _collateral == address(0) || _closeTime == 0 || _resolutionTime == 0 || bytes(_question).length == 0
                || _initialOwner == address(0)
        ) {
            revert MarketErrors.PredictionMarket__InvalidArguments_PassedInConstructor();
        }

        // Ensure closeTime comes before resolutionTime
        if (_closeTime > _resolutionTime) {
            revert MarketErrors.PredictionMarket__CloseTimeGreaterThanResolutionTime();
        }
        if(_marketfactory == address(0)){
            revert MarketErrors.PredictionMarket__MarketFactoryAddressCantBeZero();
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
        softDeviationBps = 150;
        stressDeviationBps = 300;
        hardDeviationBps = 500;
        stressExtraFeeBps = 100;
        stressMaxOutBps = 200;
        unsafeMaxOutBps = 50;

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
    error PredictionMarket__LocalResolutionDisabled();
    error PredictionMarket__CanonicalPriceDeviationTooHigh();
    error PredictionMarket__DeviationPolicyInvalid();
    error PredictionMarket__TradeDirectionNotAllowedInUnsafeBand();
    error PredictionMarket__TradeSizeExceedsBandLimit();
    error PredictionMarket__RiskExposureExemptZeroAddress();

    // ========================================
    // DEVIATION BAND DEFINITIONS
    // ========================================

    /// @notice Categorizes markets based on how far local AMM price deviates from canonical price
    /// @dev Used to apply different trading restrictions and fees per band
    enum DeviationBand {
        Normal,      // Price deviation <= softDeviationBps (1.5%): normal trading
        Stress,      // Price deviation between soft and stress (1.5-3%): extra fees + output cap
        Unsafe,      // Price deviation between stress and hard (3-5%): direction restrictions
        CircuitBreaker // Price deviation > hardDeviationBps (5%): all trading halted
    }

    event DeviationPolicyUpdated(
        uint16 softDeviationBps,
        uint16 stressDeviationBps,
        uint16 hardDeviationBps,
        uint16 stressExtraFeeBps,
        uint16 stressMaxOutBps,
        uint16 unsafeMaxOutBps
    );

    /**
     * @notice Ensures market is open for trading
     * @dev Updates state based on current timestamp before checking
     */
    modifier marketOpen() {
        _marketOpen();
        _;
    }

    /**
     * @notice Ensures initial liquidity has been seeded
     * @dev Many operations require liquidity to function properly
     */
    modifier seededOnly() {
        _seededOnly();
        _;
    }

    modifier zeroAmountCheck(uint256 amount) {
        _zeroAmountCheck(amount);
        _;
    }

    modifier onlyCrossChainController() {
        _onlyCrossChainController();
        _;
    }

    function setRiskExempt(address account, bool exempt) external onlyOwner {
        if (account == address(0)) revert PredictionMarket__RiskExposureExemptZeroAddress();
        isRiskExempt[account] = exempt;
    }

    // ========================================
    // RISK EXPOSURE MANAGEMENT
    // ========================================

    // Note: userRiskExposure and isRiskExempt are documented in STATE VARIABLES section above
    // These track per-user exposure to prevent excessive concentration in any single market

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

    function _marketOpen() internal {
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
    }

    function _seededOnly() internal view {
        if (!seeded) {
            revert MarketErrors.PredictionMarket__InitailConstantLiquidityNotSetYet();
        }
    }

    function _zeroAmountCheck(uint256 amount) internal pure {
        if (amount == 0) {
            revert MarketErrors.PredictionMarket__AmountCantBeZero();
        }
    }

    function _onlyCrossChainController() internal view {
        if (msg.sender != crossChainController) {
            revert PredictionMarket__OnlyCrossChainController();
        }
    }

    /**
     * @notice Checks if market is operating in cross-chain canonical pricing mode
     * @return true if crossChainController is set, false otherwise
     * @dev When enabled, swaps use hub-provided prices instead of AMM reserves
     */
    function _isCanonicalPricingMode() internal view returns (bool) {
        return crossChainController != address(0) && !marketFactory.isHubFactory();
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

    // ========================================
    // CROSS-CHAIN PRICING HELPERS
    // ========================================

    function _bandFromId(uint8 bandId) internal pure returns (DeviationBand) {
        if (bandId == 0) return DeviationBand.Normal;
        if (bandId == 1) return DeviationBand.Stress;
        if (bandId == 2) return DeviationBand.Unsafe;
        return DeviationBand.CircuitBreaker;
    }

    /// @notice Validates that canonical prices are properly set (non-zero)
    /// @dev Reverts if either price is zero (indicates uninitialized state)
    function _validateCanonicalPrices() internal view {
        if (canonicalNoPriceE6 == 0 || canonicalYesPriceE6 == 0) {
            revert PredictionMarket__InvalidCanonicalPrice();
        }
    }

    /// @notice Determines fee and output limits based on current deviation band
    /// @dev This is the core logic that enforces canonical price guardrails
    /// @param yesForNo True if swapping YES for NO, false for NO for YES
    /// @param reserveOut The output token reserve (used for maxOut calculation)
    /// @return effectiveFeeBps The fee basis points to apply (higher in stress/unsafe bands)
    /// @return maxOut Maximum output allowed (capped in stress/unsafe bands)
    function _getCanonicalSwapControls(bool yesForNo, uint256 reserveOut)
        internal
        view
        returns (uint256 effectiveFeeBps, uint256 maxOut)
    {
        _ensureCanonicalPriceFresh();
        _validateCanonicalPrices();

        CanonicalPricingModule.SwapControlsParams memory p = CanonicalPricingModule.SwapControlsParams({
            yesForNo: yesForNo,
            reserveOut: reserveOut,
            yesReserve: yesReserve,
            noReserve: noReserve,
            pricePrecision: MarketConstants.PRICE_PRECISION,
            canonicalYesPriceE6: canonicalYesPriceE6,
            softDeviationBps: softDeviationBps,
            stressDeviationBps: stressDeviationBps,
            hardDeviationBps: hardDeviationBps,
            stressExtraFeeBps: stressExtraFeeBps,
            stressMaxOutBps: stressMaxOutBps,
            unsafeMaxOutBps: unsafeMaxOutBps,
            swapFeeBps: MarketConstants.SWAP_FEE_BPS,
            feePrecisionBps: MarketConstants.FEE_PRECISION_BPS
        });
        (uint8 bandId, uint256 feeBpsOut, uint256 maxOutOut, bool allowDirection) = CanonicalPricingModule.swapControls(p);

        if (bandId == uint8(DeviationBand.CircuitBreaker)) {
            revert PredictionMarket__CanonicalPriceDeviationTooHigh();
        }
        if (!allowDirection) {
            revert PredictionMarket__TradeDirectionNotAllowedInUnsafeBand();
        }

        effectiveFeeBps = feeBpsOut;
        maxOut = maxOutOut;
    }

    function _revertIfLocalResolutionDisabled() internal view {
        if (crossChainController != address(0) && !marketFactory.isHubFactory()) {
            revert PredictionMarket__LocalResolutionDisabled();
        }
    }

    function _getSwapExecutionParams(bool yesForNo)
        internal
        view
        returns (uint256 reserveIn, uint256 reserveOut, uint256 feeBps, uint256 maxOut)
    {
        reserveIn = yesForNo ? yesReserve : noReserve;
        reserveOut = yesForNo ? noReserve : yesReserve;
        feeBps = MarketConstants.SWAP_FEE_BPS;
        maxOut = type(uint256).max;

        if (_isCanonicalPricingMode()) {
            (feeBps, maxOut) = _getCanonicalSwapControls(yesForNo, reserveOut);
        }
    }

    function _quoteSwap(uint256 amountIn, bool yesForNo) internal view returns (uint256 netOut, uint256 fee) {
        if (amountIn < MarketConstants.MINIMUM_SWAP_AMOUNT) {
            revert MarketErrors.PredictionMarket__AmountLessThanMinAllwed();
        }

        (uint256 reserveIn, uint256 reserveOut, uint256 feeBps, uint256 maxOut) = _getSwapExecutionParams(yesForNo);
        (netOut, fee,,) = AMMLib.getAmountOut(reserveIn, reserveOut, amountIn, feeBps, MarketConstants.FEE_PRECISION_BPS);

        if (netOut > maxOut) {
            revert PredictionMarket__TradeSizeExceedsBandLimit();
        }
    }

    function _swap(uint256 amountIn, uint256 minOut, bool yesForNo) internal returns (uint256 amountOut) {
        IERC20 tokenIn = yesForNo ? IERC20(address(yesToken)) : IERC20(address(noToken));
        IERC20 tokenOut = yesForNo ? IERC20(address(noToken)) : IERC20(address(yesToken));

        if (tokenIn.balanceOf(msg.sender) < amountIn) {
            if (yesForNo) {
                revert MarketErrors.PredictionMarket__SwapYesFoNo_YesExeedBalannce();
            }
            revert MarketErrors.PredictionMarket__SwapNoFoYes_NoExeedBalannce();
        }
        if (amountIn < MarketConstants.MINIMUM_SWAP_AMOUNT) {
            revert MarketErrors.PredictionMarket__AmountLessThanMinSwapAllwed();
        }

        (uint256 reserveIn, uint256 reserveOut, uint256 feeBps, uint256 maxOut) = _getSwapExecutionParams(yesForNo);
        uint256 newReserveIn;
        uint256 newReserveOut;
        (amountOut,, newReserveIn, newReserveOut) =
            AMMLib.getAmountOut(reserveIn, reserveOut, amountIn, feeBps, MarketConstants.FEE_PRECISION_BPS);

        if (amountOut > maxOut) {
            revert PredictionMarket__TradeSizeExceedsBandLimit();
        }
        if (minOut > amountOut) {
            revert MarketErrors.PredictionMarket__SwapingExceedSlippage();
        }

        if (yesForNo) {
            yesReserve = newReserveIn;
            noReserve = newReserveOut;
        } else {
            noReserve = newReserveIn;
            yesReserve = newReserveOut;
        }

        tokenIn.safeTransferFrom(msg.sender, address(this), amountIn);
        tokenOut.safeTransfer(msg.sender, amountOut);

        emit MarketEvents.Trade(msg.sender, yesForNo, amountIn, amountOut);
    }

    function _finalizeResolution(Resolution _outcome, string memory proofUrl, bool removeFromFactory, bool notifyHub)
        internal
    {
        resolution = _outcome;
        s_Proof_Url = proofUrl;
        manualReviewNeeded = false;
        state = State.Resolved;

        if (removeFromFactory) {
            marketFactory.removeResolvedMarket(address(this));
        }

        if (notifyHub && crossChainController != address(0) && marketFactory.isHubFactory()) {
            marketFactory.onHubMarketResolved(_outcome, proofUrl);
        }

        emit MarketEvents.Resolved(resolution);
    }

    function _withdrawResolvedLiquidity(uint256 shares, uint256 userShares, bool yesWon) internal {
        uint256 reserve = yesWon ? yesReserve : noReserve;
        uint256 out = AMMLib.calculateProportionalOutput(reserve, shares, totalShares);

        totalShares -= shares;
        lpShares[msg.sender] = userShares - shares;

        if (yesWon) {
            yesReserve -= out;
            yesToken.burn(address(this), out);
        } else {
            noReserve -= out;
            noToken.burn(address(this), out);
        }

        i_collateral.safeTransfer(msg.sender, out);
        emit MarketEvents.WithDrawnLiquidity(msg.sender, out, shares);
    }

    // ========================================
    // DEVIATION POLICY MANAGEMENT
    // ========================================

    /// @notice Updates the deviation band thresholds and fee parameters
    /// @dev Only callable by owner. Enforces valid ordering:
    ///      soft < stress < hard <= 10000, stressMaxOutBps > unsafeMaxOutBps > 0
    function setDeviationPolicy(
        uint16 _softDeviationBps,
        uint16 _stressDeviationBps,
        uint16 _hardDeviationBps,
        uint16 _stressExtraFeeBps,
        uint16 _stressMaxOutBps,
        uint16 _unsafeMaxOutBps
    ) external onlyOwner {
        if (
            _softDeviationBps >= _stressDeviationBps || _stressDeviationBps >= _hardDeviationBps
                || _hardDeviationBps > MarketConstants.FEE_PRECISION_BPS
                || _stressExtraFeeBps > MarketConstants.FEE_PRECISION_BPS
                || _stressMaxOutBps == 0 || _stressMaxOutBps > MarketConstants.FEE_PRECISION_BPS
                || _unsafeMaxOutBps == 0 || _unsafeMaxOutBps > MarketConstants.FEE_PRECISION_BPS
                || _unsafeMaxOutBps >= _stressMaxOutBps
        ) {
            revert PredictionMarket__DeviationPolicyInvalid();
        }

        softDeviationBps = _softDeviationBps;
        stressDeviationBps = _stressDeviationBps;
        hardDeviationBps = _hardDeviationBps;
        stressExtraFeeBps = _stressExtraFeeBps;
        stressMaxOutBps = _stressMaxOutBps;
        unsafeMaxOutBps = _unsafeMaxOutBps;

        emit DeviationPolicyUpdated(
            _softDeviationBps, _stressDeviationBps, _hardDeviationBps, _stressExtraFeeBps, _stressMaxOutBps, _unsafeMaxOutBps
        );
    }

    // ========================================
    // DEVIATION STATUS VIEW
    // ========================================

    /// @notice Returns current deviation status for UI/chainlink automation
    /// @dev Useful for off-chain systems to determine if arbitrage/correction is needed
    /// @return band Current DeviationBand classification
    /// @return deviationBps Current price deviation in bps
    /// @return effectiveFeeBps Fee that will be applied to swaps
    /// @return maxOutBps Maximum output as percentage of reserve
    /// @return allowYesForNo Whether YES->NO swaps are permitted in current band
    /// @return allowNoForYes Whether NO->YES swaps are permitted in current band
    function getDeviationStatus()
        external
        view
        returns (
            DeviationBand band,
            uint256 deviationBps,
            uint256 effectiveFeeBps,
            uint256 maxOutBps,
            bool allowYesForNo,
            bool allowNoForYes
        )
    {
        if (!_isCanonicalPricingMode()) {
            return (
                DeviationBand.Normal,
                0,
                MarketConstants.SWAP_FEE_BPS,
                MarketConstants.FEE_PRECISION_BPS,
                true,
                true
            );
        }

        _ensureCanonicalPriceFresh();
        _validateCanonicalPrices();

        uint8 bandId;
        CanonicalPricingModule.DeviationStatusParams memory p = CanonicalPricingModule.DeviationStatusParams({
            yesReserve: yesReserve,
            noReserve: noReserve,
            pricePrecision: MarketConstants.PRICE_PRECISION,
            canonicalYesPriceE6: canonicalYesPriceE6,
            softDeviationBps: softDeviationBps,
            stressDeviationBps: stressDeviationBps,
            hardDeviationBps: hardDeviationBps,
            stressExtraFeeBps: stressExtraFeeBps,
            stressMaxOutBps: stressMaxOutBps,
            unsafeMaxOutBps: unsafeMaxOutBps,
            swapFeeBps: MarketConstants.SWAP_FEE_BPS,
            feePrecisionBps: MarketConstants.FEE_PRECISION_BPS
        });
        (bandId, deviationBps, effectiveFeeBps, maxOutBps, allowYesForNo, allowNoForYes) =
            CanonicalPricingModule.deviationStatus(p);
        band = _bandFromId(bandId);
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

        _withdrawResolvedLiquidity(shares, userShares, resolutionOut == uint256(Resolution.Yes));
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
        if (msg.sender != address(marketFactory) && !isRiskExempt[msg.sender] && exposure + amount > MarketConstants.MAX_RISK_EXPOSURE) {
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
    function redeemCompleteSets(uint256 amount) external nonReentrant marketOpen zeroAmountCheck(amount) {
        if (amount < MarketConstants.MINIMUM_AMOUNT) {
            revert MarketErrors.PredictionMarket__RedeemCompletesetLessThanMinAllowed();
        }
        // Check user has sufficient YES and NO tokens
        uint256 userNoBalance = noToken.balanceOf(msg.sender);
        uint256 userYesBalance = yesToken.balanceOf(msg.sender);
        if (userNoBalance < amount || userYesBalance < amount) {
            revert MarketErrors.PredictionMarket__redeemCompleteSets_InsuffientTokenBalance();
        }

   

        // Calculate fee and net amount using FeeLib
        (uint256 netAmount, uint256 fee) =
            FeeLib.deductFee(amount, MarketConstants.REDEEM_COMPLETE_SETS_FEE_BPS, MarketConstants.FEE_PRECISION_BPS);

        // Add fee to protocol reserves
        protocolCollateralFees += fee;

     // Burn both YES and NO tokens from user
        yesToken.burn(msg.sender, amount);
        noToken.burn(msg.sender, amount);
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
        zeroAmountCheck(yesIn)
    {
        _swap(yesIn, minNoOut, true);
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
        zeroAmountCheck(noIn)
    {
        _swap(noIn, minYesOut, false);
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

         if (bytes(proofUrl).length == 0) {
            revert MarketErrors.PredictionMarket__ProofUrlCantBeEmpty();
        }

        _finalizeResolution(_outcome, proofUrl, true, true);
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

        _finalizeResolution(_outcome, proofUrl, false, true);
    }

    // ========================================
    // CROSS-CHAIN INTEGRATION
    // ========================================

    /// @notice Sets the trusted contract that may push hub updates into this market
    /// @param controller Address of the cross-chain controller (typically the MarketFactory)
    /// @dev Automatically called by MarketFactory.createMarket() during deployment
    function setCrossChainController(address controller) external onlyOwner {
        if(controller == address(0)){
            revert MarketErrors.PredictionMarket__CrossChainControllerCantBeZero();
        }
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

        _finalizeResolution(_outcome, proofUrl, true, false);
    }

    /// @notice Applies hub canonical prices to this market (used by UIs/quoting guards on spokes)
    /// @dev Validates price sum equals PRECISION (ensures valid probability pair)
    ///      Uses nonce for replay protection
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

    // ========================================
    // CHAINLINK CRE AUTOMATION
    // ========================================

    /// @notice Internal hook invoked by Chainlink CRE forwarder when a settlement report arrives
    /// @dev Decodes the report to extract action type and payload, then routes to appropriate handler
    ///      Currently supports: "ResolveMarket" action to automatically resolve markets
    /// @param report ABI-encoded settlement data containing action type and payload
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
    function checkResolutionTime() external view returns (bool resolveReady) {
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
        return _quoteSwap(yesIn, true);
    }

    /**
     * @notice Previews the output of swapping NO for YES without executing
     * @param noIn Amount of NO tokens to swap
     * @return netOut Amount of YES tokens that would be received (after fee)
     * @return fee Swap fee amount
     * @dev Useful for UI to show expected trade output before execution
     */
    function getNoForYesQuote(uint256 noIn) external view zeroAmountCheck(noIn) returns (uint256 netOut, uint256 fee) {
        return _quoteSwap(noIn, false);
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
     * @dev Can only be called after market is resolved
     *      Protocol fees accumulate from:
     *      - Swap fees (portion kept in reserves)
     *      - Complete set minting fees
     *      - Complete set redemption fees
     *      - Winning token redemption fees
     *      Owner must ensure sufficient balance exists before withdrawal
     */
    function withdrawProtocolFees() external{
        if(msg.sender != owner() || msg.sender !=  crossChainController) revert MarketErrors.PredictionMarket__NotOwner_Or_CrossChainController();
        if (state != State.Resolved) {
            revert MarketErrors.PredictionMarket__StateNeedToResolvedToWithdrawLiquidity();
        }
        if(protocolCollateralFees == 0)return; 

        uint256 contractBalance = i_collateral.balanceOf(address(this));

        
        if (contractBalance < protocolCollateralFees) {
            revert MarketErrors.PredictionMarket__WithDrawLiquidity_Insufficientfee();
        }

        i_collateral.safeTransfer(msg.sender, protocolCollateralFees);
        protocolCollateralFees = 0 ;
    }
}
