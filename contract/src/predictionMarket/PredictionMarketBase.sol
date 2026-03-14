// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {
    SafeERC20
} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {
    ReentrancyGuard
} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {
    Initializable
} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {
    PausableUpgradeable
} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {OutcomeToken} from "../token/OutcomeToken.sol";
import {
    State,
    Resolution,
    MarketConstants,
    MarketEvents,
    MarketErrors
} from "../libraries/MarketTypes.sol";
import {LMSRLib} from "../libraries/LMSRLib.sol";
import {FeeLib} from "../libraries/FeeLib.sol";
import {CanonicalPricingModule} from "../modules/CanonicalPricingModule.sol";
import {MarketFactory} from "../marketFactory/MarketFactory.sol";
import {
    ReceiverTemplateUpgradeable
} from "../../script/interfaces/ReceiverTemplateUpgradeable.sol";

/// @title PredictionMarketBase
/// @notice Shared state, modifiers, and internal mechanics for LMSR-based market modules.
/// @dev Heavy LMSR math (exp/ln) is computed off-chain by the CRE HTTP handler.
///      On-chain, the contract only validates CRE-reported values and executes transfers.
abstract contract PredictionMarketBase is
    Initializable,
    ReentrancyGuard,
    PausableUpgradeable,
    ReceiverTemplateUpgradeable
{
    using SafeERC20 for IERC20;

    /// @notice Single dispute submission captured during a review window.
    /// @dev Stored so off-chain adjudication can inspect who objected, which outcome they proposed,
    /// and when that objection was recorded.
    struct DisputeSubmission {
        address disputer;
        Resolution proposedOutcome;
        uint256 submittedAt;
    }

    // ── Market metadata ──────────────────────────────────────────────
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

    // ── LMSR AMM state (replaces CPMM yesReserve/noReserve/lpShares) ─
    /// @notice Outstanding YES shares issued through LMSR trading.
    uint256 public yesSharesOutstanding;
    /// @notice Outstanding NO shares issued through LMSR trading.
    uint256 public noSharesOutstanding;
    /// @notice LMSR liquidity parameter 'b'. Controls market depth.
    /// @dev Higher b = deeper liquidity + higher max market-maker loss (b×ln(2) for binary).
    uint256 public liquidityParam;
    /// @notice Collateral locked as market-maker subsidy at initialization.
    uint256 public subsidyDeposit;
    /// @notice True after LMSR initialization is complete.
    bool public initialized;
    /// @notice Monotonic nonce for CRE trade reports. Prevents replays.
    uint64 public tradeNonce;
    /// @notice Last CRE-reported YES price (1e6 precision).
    uint256 public lastYesPriceE6;
    /// @notice Last CRE-reported NO price (1e6 precision).
    uint256 public lastNoPriceE6;

    // ── Legacy CPMM state kept for storage layout compatibility ──────
    // NOTE: These are intentionally kept but unused to prevent storage slot collisions
    // in any existing proxy deployments. New deployments will simply ignore these slots.
    uint256 internal _deprecated_yesReserve;
    uint256 internal _deprecated_noReserve;
    bool internal _deprecated_seeded;
    uint256 internal _deprecated_totalShares;
    mapping(address => uint256) internal _deprecated_lpShares;

    /// @notice Running collateral exposure tracked per account.
    mapping(address => uint256) public userRiskExposure;

    ///@notice Per-account exposure cap for regular users (exempt accounts can bypass this).
   
    /// @notice Accounts exempt from risk exposure cap.
    mapping(address => bool) public isRiskExempt;

/// @notice User-level tracking of shares bought on each side.
///@dev Used to enforce that users can't sell more shares than they bought from the AMM.
// this is beacuse mintCompleteSets produced  same amount of no and yes shares which can be sold to the AMM for collateral twice,
//  to avoid this, we track the number of shares bought in AMM by each user.
mapping(address => uint256) public userBoughtYesShares;
mapping(address => uint256) public userBoughtNoShares;


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

    bytes32 internal constant HASHED_RESOLVE_MARKET =
        keccak256(abi.encodePacked("ResolveMarket"));
    bytes32 internal constant HASHED_FINALIZE_RESOLUTION_AFTER_DISPUTE_WINDOW =
        keccak256(abi.encodePacked("FinalizeResolutionAfterDisputeWindow"));
    bytes32 internal constant HASHED_ADJUDICATE_DISPUTED_RESOLUTION =
        keccak256(abi.encodePacked("AdjudicateDisputedResolution"));
    bytes32 internal constant HASHED_LMSR_BUY =
        keccak256(abi.encodePacked("LMSRBuy"));
    bytes32 internal constant HASHED_LMSR_SELL =
        keccak256(abi.encodePacked("LMSRSell"));

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
    /// LMSR parameters (liquidityParam) are set via initializeMarket() after deployment.
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
            _collateral == address(0) ||
            _closeTime == 0 ||
            _resolutionTime == 0 ||
            bytes(_question).length == 0 ||
            _initialOwner == address(0)
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

        // LMSR initial prices: 50/50 (set during initializeMarket)
        lastYesPriceE6 = 500_000;
        lastNoPriceE6 = 500_000;

        marketFactory = MarketFactory(_marketfactory);
    }

    /// @notice Wires pre-deployed YES/NO outcome token contracts exactly once.
    /// @dev Intended to be called by owner during deployment bootstrap before market becomes active.
    function setOutcomeTokens(
        address yesTokenAddress,
        address noTokenAddress
    ) external onlyOwner {
        if (yesTokenAddress == address(0) || noTokenAddress == address(0)) {
            revert PredictionMarket__InvalidOutcomeTokenAddress();
        }
        if (yesTokenAddress == noTokenAddress)
            revert PredictionMarket__InvalidOutcomeTokenAddress();
        if (address(yesToken) != address(0) || address(noToken) != address(0)) {
            revert PredictionMarket__OutcomeTokensAlreadySet();
        }

        yesToken = OutcomeToken(yesTokenAddress);
        noToken = OutcomeToken(noTokenAddress);
    }

    /// @dev Ensures the market is still tradable and not paused/reviewing/resolved.
    modifier marketOpen() {
        _marketOpen();
        _;
    }

    /// @dev Ensures LMSR initialization has been completed.
    modifier initializedOnly() {
        _initializedOnly();
        _;
    }

    /// @dev Rejects zero-valued user inputs before executing stateful logic.
    modifier zeroAmountCheck(uint256 amount) {
        _zeroAmountCheck(amount);
        _;
    }

    /// @dev Restricts access to the hub/factory controller that owns spoke sync authority.
    modifier onlyCrossChainController() {
        _onlyCrossChainController();
        _;
    }

    /// @notice Sets whether an account bypasses risk exposure cap in `mintCompleteSets`.
    /// @dev Intended for trusted automation (for example factory-controlled maintenance paths)
    /// that may need larger temporary exposure than regular users.
    function setRiskExempt(address account, bool exempt) external onlyOwner {
        if (account == address(0))
            revert PredictionMarket__RiskExposureExemptZeroAddress();
        isRiskExempt[account] = exempt;
    }

    /// @dev Auto-transitions Open -> Closed after close time.
    function _updateState() internal {
        if (state == State.Open && block.timestamp >= closeTime) {
            state = State.Closed;
        }
    }

    /// @dev Enforces "market is tradable now" invariant used by trading paths.
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

    /// @dev Enforces that LMSR has been initialized before pool operations.
    function _initializedOnly() internal view {
        if (!initialized) {
            revert MarketErrors.LMSR__NotInitialized();
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

    /// @notice Returns true when trades should follow canonical-price risk controls.
    /// @dev Canonical mode is active on spokes where:
    /// 1) cross-chain controller is configured, and
    /// 2) this market's factory is not marked as hub.
    function _isCanonicalPricingMode() internal view returns (bool) {
        return
            crossChainController != address(0) && !marketFactory.isHubFactory();
    }

    /// @dev Rejects missing or expired canonical price snapshots.
    function _ensureCanonicalPriceFresh() internal view {
        if (
            canonicalPriceNonce == 0 ||
            block.timestamp > canonicalPriceValidUntil
        ) {
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
    function _validateCanonicalPrices() internal view {
        if (canonicalNoPriceE6 == 0 || canonicalYesPriceE6 == 0) {
            revert PredictionMarket__InvalidCanonicalPrice();
        }
    }

    /// @dev Blocks local resolution where hub-governed cross-chain resolution is required.
    function _revertIfLocalResolutionDisabled() internal view {
        if (
            crossChainController != address(0) && !marketFactory.isHubFactory()
        ) {
            revert PredictionMarket__LocalResolutionDisabled();
        }
    }

    /// @dev Finalizes resolution state and executes optional side effects.
    function _finalizeResolution(
        Resolution _outcome,
        string memory proofUrl,
        bool removeFromFactory,
        bool notifyHub
    ) internal {
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

        if (
            notifyHub &&
            crossChainController != address(0) &&
            marketFactory.isHubFactory()
        ) {
            marketFactory.onHubMarketResolved(_outcome, proofUrl);
        }

        emit MarketEvents.Resolved(resolution);
    }

    /// @notice Returns the current LMSR state in a single call for CRE and frontend consumption.
    /// @return yesShares Outstanding YES shares.
    /// @return noShares Outstanding NO shares.
    /// @return b Liquidity parameter.
    /// @return yesPriceE6 Last-reported YES price (1e6 precision).
    /// @return noPriceE6 Last-reported NO price (1e6 precision).
    /// @return currentNonce Current trade nonce.
    function getLMSRState()
        external
        view
        returns (
            uint256 yesShares,
            uint256 noShares,
            uint256 b,
            uint256 yesPriceE6,
            uint256 noPriceE6,
            uint64 currentNonce
        )
    {
        yesShares = yesSharesOutstanding;
        noShares = noSharesOutstanding;
        b = liquidityParam;
        yesPriceE6 = lastYesPriceE6;
        noPriceE6 = lastNoPriceE6;
        currentNonce = tradeNonce;
    }

    /// @notice Returns the current LMSR snapshot for the CRE price-sync handler.
    /// @dev Used by syncCanonicalPrice workflow to read hub prices and push to spokes.
    function getSyncSnapshot()
        external
        view
        returns (uint256 marketState, uint256 yesPriceE6, uint256 noPriceE6)
    {
        marketState = uint256(state);
        yesPriceE6 = lastYesPriceE6;
        noPriceE6 = lastNoPriceE6;
    }
}
