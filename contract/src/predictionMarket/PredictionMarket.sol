// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {State, MarketConstants, MarketEvents, MarketErrors} from "../libraries/MarketTypes.sol";
import {AMMLib} from "../libraries/AMMLib.sol";
import {CanonicalPricingModule} from "../modules/CanonicalPricingModule.sol";
import {PredictionMarketResolution} from "./PredictionMarketResolution.sol";

/// @title PredictionMarket
/// @notice Concrete market surface that exposes liquidity, swap, canonical pricing, and resolution APIs.
/// @dev Most logic lives in inherited modules; this contract mainly provides public entrypoints and
/// owner-controlled policy/config accessors.
contract PredictionMarket is PredictionMarketResolution {
    using SafeERC20 for IERC20;

    function addLiquidity(uint256 yesAmount, uint256 noAmount, uint256 minShares) public override {
        super.addLiquidity(yesAmount, noAmount, minShares);
    }

    function removeLiquidity(uint256 shares, uint256 minYesOut, uint256 minNoOut) public override {
        super.removeLiquidity(shares, minYesOut, minNoOut);
    }

    function removeLiquidityAndRedeemCollateral(uint256 shares, uint256 minCollateralOut) public override {
        super.removeLiquidityAndRedeemCollateral(shares, minCollateralOut);
    }

    function transferShares(address to, uint256 shares) public override {
        super.transferShares(to, shares);
    }

    function mintCompleteSets(uint256 amount) public override {
        super.mintCompleteSets(amount);
    }

    function redeemCompleteSets(uint256 amount) public override {
        super.redeemCompleteSets(amount);
    }

    function swapYesForNo(uint256 yesIn, uint256 minNoOut) public override {
        super.swapYesForNo(yesIn, minNoOut);
    }

    function swapNoForYes(uint256 noIn, uint256 minYesOut) public override {
        super.swapNoForYes(noIn, minYesOut);
    }

    /// @notice Updates deviation-policy thresholds that control canonical pricing safety rails.
    /// @dev Parameter constraints guarantee valid ordering and sane caps:
    /// `soft < stress < hard`,
    /// output caps are non-zero and <= 100%,
    /// unsafe cap is strictly tighter than stress cap.
    /// These values directly influence swap fee uplift, direction restrictions, and per-trade size caps.
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

    /// @notice Returns current deviation diagnostics used by operators/automation.
    /// @dev In local mode (non-canonical), returns permissive defaults.
    /// In canonical mode, computes:
    /// - deviation band,
    /// - effective fee,
    /// - max output cap in bps,
    /// - whether each swap direction is currently permitted.
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

    /// @notice Quotes YES->NO swap output under current policy.
    /// @dev Example: `yesIn = 2_000_000` means 2 units when tokens use 6 decimals.
    function getYesForNoQuote(uint256 yesIn)
        external
        view
        zeroAmountCheck(yesIn)
        returns (uint256 netOut, uint256 fee)
    {
        return _quoteSwap(yesIn, true);
    }

    /// @notice Quotes NO->YES swap output under current policy.
    /// @dev Example: `noIn = 2_000_000` means 2 units when tokens use 6 decimals.
    function getNoForYesQuote(uint256 noIn) external view zeroAmountCheck(noIn) returns (uint256 netOut, uint256 fee) {
        return _quoteSwap(noIn, false);
    }

    /// @notice Returns YES probability in `1e6` precision.
    /// @dev Source of truth:
    /// - canonical mode: latest hub-synced canonical price,
    /// - local mode: implied AMM price from reserves.
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

    /// @notice Returns NO probability in `1e6` precision.
    /// @dev Mirrors `getYesPriceProbability` source logic, using canonical value when active,
    /// otherwise derives as `PRICE_PRECISION - yesProbability`.
    function getNoPriceProbability() external view returns (uint256) {
        if (!seeded) {
            revert MarketErrors.PredictionMarket__InitailConstantLiquidityNotSetYet();
        }

        if (_isCanonicalPricingMode()) {
            _ensureCanonicalPriceFresh();
            return canonicalNoPriceE6;
        }

        uint256 yesProbability = AMMLib.getYesProbability(yesReserve, noReserve, MarketConstants.PRICE_PRECISION);
        return MarketConstants.PRICE_PRECISION - yesProbability;
    }

    /// @notice Pauses user actions guarded by `whenNotPaused` / `marketOpen`.
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Unpauses the market after pause event.
    function unpause() external onlyOwner {
        _unpause();
    }

    /// @notice Withdraws accumulated protocol fee collateral.
    /// @dev Guardrails:
    /// - only owner or cross-chain controller may call,
    /// - market must already be resolved,
    /// - contract collateral balance must cover tracked fee amount.
    /// On success, transfers full fee bucket and resets it to zero.
    function withdrawProtocolFees() external {
        if (msg.sender != owner() && msg.sender != crossChainController) {
            revert MarketErrors.PredictionMarket__NotOwner_Or_CrossChainController();
        }
        if (state != State.Resolved) {
            revert MarketErrors.PredictionMarket__StateNeedToResolvedToWithdrawLiquidity();
        }
        if (protocolCollateralFees == 0) return;

        uint256 contractBalance = i_collateral.balanceOf(address(this));

        if (contractBalance < protocolCollateralFees) {
            revert MarketErrors.PredictionMarket__WithDrawLiquidity_Insufficientfee();
        }

        uint256 fees = protocolCollateralFees;
        i_collateral.safeTransfer(msg.sender, fees);
        protocolCollateralFees = 0;

        emit MarketEvents.WithdrawProtocolFees(msg.sender, fees);
    }
}
