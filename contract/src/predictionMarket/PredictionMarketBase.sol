// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {OutcomeToken} from "../OutcomeToken.sol";
import {State, Resolution, MarketConstants, MarketEvents, MarketErrors} from "../libraries/MarketTypes.sol";
import {AMMLib} from "../libraries/AMMLib.sol";
import {FeeLib} from "../libraries/FeeLib.sol";
import {CanonicalPricingModule} from "../modules/CanonicalPricingModule.sol";
import {MarketFactory} from "../upgrades/MarketFactory.sol";
import {ReceiverTemplateUpgradeable} from "script/interfaces/ReceiverTemplateUpgradeable.sol";

abstract contract PredictionMarketBase is Initializable, ReentrancyGuard, PausableUpgradeable, ReceiverTemplateUpgradeable {
    using SafeERC20 for IERC20;

    string public s_question;
    string public s_Proof_Url;
    IERC20 public i_collateral;
    OutcomeToken public yesToken;
    OutcomeToken public noToken;
    uint256 public closeTime;
    uint256 public resolutionTime;
    uint256 public marketId;

    uint256 public protocolCollateralFees;

    uint256 public yesReserve;
    uint256 public noReserve;
    bool public seeded;
    uint256 public totalShares;

    mapping(address => uint256) public lpShares;
    mapping(address => uint256) public userRiskExposure;
    mapping(address => bool) public isRiskExempt;

    State public state;
    Resolution public resolution;
    bool internal manualReviewNeeded;
    MarketFactory internal marketFactory;

    address public crossChainController;
    uint256 public canonicalYesPriceE6;
    uint256 public canonicalNoPriceE6;
    uint256 public canonicalPriceValidUntil;
    uint64 public canonicalPriceNonce;

    uint16 public softDeviationBps;
    uint16 public stressDeviationBps;
    uint16 public hardDeviationBps;
    uint16 public stressExtraFeeBps;
    uint16 public stressMaxOutBps;
    uint16 public unsafeMaxOutBps;

    bytes32 internal constant HASHED_RESOLVE_MARKET = keccak256(abi.encodePacked("ResolveMarket"));

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

        yesToken = new OutcomeToken("YES", "YES", address(this));
        noToken = new OutcomeToken("NO", "NO", address(this));

        state = State.Open;
        softDeviationBps = 150;
        stressDeviationBps = 300;
        hardDeviationBps = 500;
        stressExtraFeeBps = 100;
        stressMaxOutBps = 200;
        unsafeMaxOutBps = 50;

        marketFactory = MarketFactory(_marketfactory);
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

    function setRiskExempt(address account, bool exempt) external onlyOwner {
        if (account == address(0)) revert PredictionMarket__RiskExposureExemptZeroAddress();
        isRiskExempt[account] = exempt;
    }

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

    function _isCanonicalPricingMode() internal view returns (bool) {
        return crossChainController != address(0) && !marketFactory.isHubFactory();
    }

    function _ensureCanonicalPriceFresh() internal view {
        if (canonicalPriceNonce == 0 || block.timestamp > canonicalPriceValidUntil) {
            revert PredictionMarket__CanonicalPriceStale();
        }
    }

    function _bandFromId(uint8 bandId) internal pure returns (DeviationBand) {
        if (bandId == 0) return DeviationBand.Normal;
        if (bandId == 1) return DeviationBand.Stress;
        if (bandId == 2) return DeviationBand.Unsafe;
        return DeviationBand.CircuitBreaker;
    }

    function _validateCanonicalPrices() internal view {
        if (canonicalNoPriceE6 == 0 || canonicalYesPriceE6 == 0) {
            revert PredictionMarket__InvalidCanonicalPrice();
        }
    }

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
}
