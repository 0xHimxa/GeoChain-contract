// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {OutcomeToken} from "../token/OutcomeToken.sol";
import {State, Resolution, MarketConstants, MarketEvents, MarketErrors} from "../libraries/MarketTypes.sol";
import {AMMLib} from "../libraries/AMMLib.sol";
import {FeeLib} from "../libraries/FeeLib.sol";
import {CanonicalPricingModule} from "../modules/CanonicalPricingModule.sol";
import {MarketFactory} from "../marketFactory/MarketFactory.sol";
import {ReceiverTemplateUpgradeable} from "../../script/interfaces/ReceiverTemplateUpgradeable.sol";

/// @title PredictionMarketBase
/// @notice Shared state, modifiers, and internal mechanics for market modules.
abstract contract PredictionMarketBase is Initializable, ReentrancyGuard, PausableUpgradeable, ReceiverTemplateUpgradeable {
    using SafeERC20 for IERC20;

    struct DisputeSubmission {
        address disputer;
        Resolution proposedOutcome;
        uint256 submittedAt;
    }

    /// @notice Human-readable market question.
    string public s_question;
    /// @notice Resolution proof URI stored when market is finalized.
    string public s_Proof_Url;
    /// @notice Collateral token accepted by this market.
    IERC20 public i_collateral;
    /// @notice ERC20 claim token for YES side.
    OutcomeToken public yesToken;
    /// @notice ERC20 claim token for NO side.
    OutcomeToken public noToken;
    /// @notice Timestamp after which trading must stop.
    uint256 public closeTime;
    /// @notice Earliest timestamp the market can be resolved.
    uint256 public resolutionTime;
    /// @notice Duration for disputing an initially proposed resolution.
    uint256 public disputeWindow;
    /// @notice End timestamp of the active dispute period for a proposed outcome.
    uint256 public disputeDeadline;
    /// @notice Factory-assigned identifier, set once.
    uint256 public marketId;

    /// @notice Accumulated protocol fees denominated in collateral.
    uint256 public protocolCollateralFees;

    /// @notice Current YES reserve held in AMM pool.
    uint256 public yesReserve;
    /// @notice Current NO reserve held in AMM pool.
    uint256 public noReserve;
    /// @notice True after one-time initial liquidity seeding.
    bool public seeded;
    /// @notice Total LP share supply.
    uint256 public totalShares;

    /// @notice LP shares owned by each account.
    mapping(address => uint256) public lpShares;
    /// @notice Running collateral exposure tracked per account.
    mapping(address => uint256) public userRiskExposure;
    /// @notice Accounts exempt from risk exposure cap.
    mapping(address => bool) public isRiskExempt;

    /// @notice Current lifecycle state.
    State public state;
    /// @notice Final or interim resolution value.
    Resolution public resolution;
    /// @notice Provisional outcome awaiting dispute-window finalization.
    Resolution public proposedResolution;
    /// @notice Proof URL submitted with the provisional outcome.
    string public proposedProofUrl;
    /// @notice True once a provisional resolution has been disputed.
    bool public resolutionDisputed;
    /// @notice True when an account already submitted one dispute for this market.
    mapping(address => bool) public hasSubmittedDispute;
    /// @notice Ordered list of all dispute submissions for the active proposal.
    DisputeSubmission[] public disputeSubmissions;
    /// @notice Unique set of disputed outcomes submitted for this market proposal (max 3).
    Resolution[3] internal uniqueDisputedOutcomes;
    /// @notice Number of populated entries in `uniqueDisputedOutcomes`.
    uint8 internal uniqueDisputedOutcomesCount;
    /// @dev Outcome-membership marker for `uniqueDisputedOutcomes`.
    mapping(uint8 => bool) internal uniqueDisputedOutcomeSeen;
    /// @notice True when inconclusive result requires manual finalize call.
    bool internal manualReviewNeeded;
    /// @notice Parent factory reference for cross-contract coordination.
    MarketFactory internal marketFactory;

    /// @notice Authorized cross-chain controller (usually factory).
    address public crossChainController;
    /// @notice Canonical YES price (1e6 precision) received from hub.
    uint256 public canonicalYesPriceE6;
    /// @notice Canonical NO price (1e6 precision) received from hub.
    uint256 public canonicalNoPriceE6;
    /// @notice Expiry timestamp for current canonical price snapshot.
    uint256 public canonicalPriceValidUntil;
    /// @notice Last accepted canonical-price nonce.
    uint64 public canonicalPriceNonce;

    /// @notice Max bps deviation still considered normal.
    uint16 public softDeviationBps;
    /// @notice Max bps deviation considered stress.
    uint16 public stressDeviationBps;
    /// @notice Max bps deviation before circuit-breaker.
    uint16 public hardDeviationBps;
    /// @notice Extra fee added in stress/unsafe bands.
    uint16 public stressExtraFeeBps;
    /// @notice Max output cap in stress band (bps of reserve out).
    uint16 public stressMaxOutBps;
    /// @notice Max output cap in unsafe band (bps of reserve out).
    uint16 public unsafeMaxOutBps;

    bytes32 internal constant HASHED_RESOLVE_MARKET = keccak256(abi.encodePacked("ResolveMarket"));
    bytes32 internal constant HASHED_FINALIZE_RESOLUTION_AFTER_DISPUTE_WINDOW =
        keccak256(abi.encodePacked("FinalizeResolutionAfterDisputeWindow"));
    bytes32 internal constant HASHED_ADJUDICATE_DISPUTED_RESOLUTION =
        keccak256(abi.encodePacked("AdjudicateDisputedResolution"));

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
    error PredictionMarket__InvalidMarketId();
    error PredictionMarket__MarketIdAlreadySet();
    error PredictionMarket__InvalidOutcomeTokenAddress();
    error PredictionMarket__OutcomeTokensAlreadySet();

    enum DeviationBand {
        Normal,
        Stress,
        Unsafe,
        CircuitBreaker
    }

    event DeviationPolicyUpdated(
        uint16 softDeviationBps,
        uint16 stressDeviationBps,
        uint16 hardDeviationBps,
        uint16 stressExtraFeeBps,
        uint16 stressMaxOutBps,
        uint16 unsafeMaxOutBps
    );

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initializes a freshly cloned market instance.
    /// @dev Initialization responsibilities:
    /// 1) wire pausable/receiver ownership state,
    /// 2) validate constructor-like arguments (non-zero addresses, non-empty question, valid timestamps),
    /// 3) store immutable-like market metadata,
    /// 4) set default state and canonical-deviation policy thresholds.
    /// Outcome tokens are wired separately by deployer after clone init.
    /// This function is called once by the deployer immediately after clone creation.
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

        if (
            _collateral == address(0) || _closeTime == 0 || _resolutionTime == 0 || bytes(_question).length == 0
                || _initialOwner == address(0)
        ) {
            revert MarketErrors.PredictionMarket__InvalidArguments_PassedInConstructor();
        }

        if (_closeTime > _resolutionTime) {
            revert MarketErrors.PredictionMarket__CloseTimeGreaterThanResolutionTime();
        }
        if (_marketfactory == address(0)) {
            revert MarketErrors.PredictionMarket__MarketFactoryAddressCantBeZero();
        }

        s_question = _question;
        i_collateral = IERC20(_collateral);
        closeTime = _closeTime;
        resolutionTime = _resolutionTime;
        disputeWindow = MarketConstants.DEFAULT_DISPUTE_WINDOW;

        state = State.Open;
        softDeviationBps = 150;
        stressDeviationBps = 300;
        hardDeviationBps = 500;
        stressExtraFeeBps = 100;
        stressMaxOutBps = 200;
        unsafeMaxOutBps = 50;

        marketFactory = MarketFactory(_marketfactory);
    }

    /// @notice Wires pre-deployed YES/NO outcome token contracts exactly once.
    /// @dev Intended to be called by owner during deployment bootstrap before market becomes active.
    function setOutcomeTokens(address yesTokenAddress, address noTokenAddress) external onlyOwner {
        if (yesTokenAddress == address(0) || noTokenAddress == address(0)) {
            revert PredictionMarket__InvalidOutcomeTokenAddress();
        }
        if (yesTokenAddress == noTokenAddress) revert PredictionMarket__InvalidOutcomeTokenAddress();
        if (address(yesToken) != address(0) || address(noToken) != address(0)) {
            revert PredictionMarket__OutcomeTokensAlreadySet();
        }

        yesToken = OutcomeToken(yesTokenAddress);
        noToken = OutcomeToken(noTokenAddress);
    }

    modifier marketOpen() {
        _marketOpen();
        _;
    }

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

    /// @notice Sets whether an account bypasses risk exposure cap in `mintCompleteSets`.
    /// @dev Intended for trusted automation (for example factory-controlled maintenance paths)
    /// that may need larger temporary exposure than regular users.
    function setRiskExempt(address account, bool exempt) external onlyOwner {
        if (account == address(0)) revert PredictionMarket__RiskExposureExemptZeroAddress();
        isRiskExempt[account] = exempt;
    }

    /// @dev Auto-transitions Open -> Closed after close time.
    function _updateState() internal {
        if (state == State.Open && block.timestamp >= closeTime) {
            state = State.Closed;
        }
    }

    /// @dev Enforces "market is tradable now" invariant used by trading/liquidity paths.
    /// It first performs time-based state rollover (`Open` -> `Closed`) and then rejects
    /// any non-open states (`Resolved`, `Closed`, `Review`) or pause condition.
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

    /// @dev Enforces that initial liquidity has been seeded before pool operations.
    function _seededOnly() internal view {
        if (!seeded) {
            revert MarketErrors.PredictionMarket__InitailConstantLiquidityNotSetYet();
        }
    }

    /// @dev Reverts when amount is zero.
    function _zeroAmountCheck(uint256 amount) internal pure {
        if (amount == 0) {
            revert MarketErrors.PredictionMarket__AmountCantBeZero();
        }
    }

    /// @dev Enforces cross-chain controller caller for hub-sync entrypoints.
    function _onlyCrossChainController() internal view {
        if (msg.sender != crossChainController) {
            revert PredictionMarket__OnlyCrossChainController();
        }
    }

    /// @notice Returns true when swaps should follow canonical-price risk controls.
    /// @dev Canonical mode is active on spokes where:
    /// 1) cross-chain controller is configured, and
    /// 2) this market's factory is not marked as hub.
    function _isCanonicalPricingMode() internal view returns (bool) {
        return crossChainController != address(0) && !marketFactory.isHubFactory();
    }

    /// @dev Rejects missing or expired canonical price snapshots.
    function _ensureCanonicalPriceFresh() internal view {
        if (canonicalPriceNonce == 0 || block.timestamp > canonicalPriceValidUntil) {
            revert PredictionMarket__CanonicalPriceStale();
        }
    }

    /// @dev Converts module band id into local enum.
    function _bandFromId(uint8 bandId) internal pure returns (DeviationBand) {
        if (bandId == 0) return DeviationBand.Normal;
        if (bandId == 1) return DeviationBand.Stress;
        if (bandId == 2) return DeviationBand.Unsafe;
        return DeviationBand.CircuitBreaker;
    }

    /// @dev Rejects canonical prices that are zero on either side.
    /// Non-zero is required because downstream ratio/deviation math assumes both sides are defined.
    function _validateCanonicalPrices() internal view {
        if (canonicalNoPriceE6 == 0 || canonicalYesPriceE6 == 0) {
            revert PredictionMarket__InvalidCanonicalPrice();
        }
    }

    /// @dev Computes swap controls (effective fee + max output) under canonical policy.
    /// The underlying module compares local AMM implied price vs canonical hub price and classifies
    /// deviation band. This function then enforces:
    /// - circuit-breaker band => revert,
    /// - disallowed direction in unsafe band => revert,
    /// and otherwise returns the adjusted fee/maxOut for actual swap execution.
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

    /// @dev Blocks local resolution where hub-governed cross-chain resolution is required.
    /// This prevents spoke operators from finalizing outcome independently from hub consensus.
    function _revertIfLocalResolutionDisabled() internal view {
        if (crossChainController != address(0) && !marketFactory.isHubFactory()) {
            revert PredictionMarket__LocalResolutionDisabled();
        }
    }

    /// @dev Returns reserves + fee model that should apply for a proposed swap direction.
    /// In local mode this is standard AMM fee/no-cap.
    /// In canonical mode this may include fee uplift and maxOut cap from deviation policy.
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

    /// @notice Quotes output and fee for a proposed swap input.
    /// @dev This performs the same policy and min-amount checks as execution path, but
    /// does not mutate reserves or transfer tokens.
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

    /// @dev Executes YES<->NO swap end-to-end.
    /// Steps:
    /// 1) resolve tokenIn/tokenOut by direction,
    /// 2) validate trader balance and minimum input,
    /// 3) derive policy-controlled fee + maxOut and quote new reserves via AMM formula,
    /// 4) enforce maxOut cap and user slippage floor,
    /// 5) commit new reserves,
    /// 6) transfer in input token and transfer out output token,
    /// 7) emit trade event.
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

    /// @dev Finalizes resolution state and executes optional side effects.
    /// Optional side effects:
    /// - `removeFromFactory`: remove this market from active factory list.
    /// - `notifyHub`: call back into hub factory so it can broadcast resolution cross-chain.
    /// This function is shared by local, manual-review, and hub-driven resolution paths.
    function _finalizeResolution(Resolution _outcome, string memory proofUrl, bool removeFromFactory, bool notifyHub)
        internal
    {
        resolution = _outcome;
        s_Proof_Url = proofUrl;
        manualReviewNeeded = false;
        proposedResolution = Resolution.Unset;
        proposedProofUrl = "";
        disputeDeadline = 0;
        resolutionDisputed = false;
        state = State.Resolved;

        if (removeFromFactory) {
            marketFactory.removeResolvedMarket(address(this));
        }
        marketFactory.removeManualReviewMarket(address(this));

        if (notifyHub && crossChainController != address(0) && marketFactory.isHubFactory()) {
            marketFactory.onHubMarketResolved(_outcome, proofUrl);
        }

        emit MarketEvents.Resolved(resolution);
    }

    /// @dev Settles LP shares after resolution using only the winning reserve side.
    /// Math:
    /// `out = reserveWinning * shares / totalShares`.
    /// Then:
    /// - burn equivalent winning outcome tokens held by the pool,
    /// - decrement winning reserve,
    /// - decrement user shares + total shares,
    /// - transfer collateral `out` to user.
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
}
