// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {
    SafeERC20
} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {
    State,
    MarketConstants,
    MarketEvents,
    MarketErrors
} from "../libraries/MarketTypes.sol";
import {CanonicalPricingModule} from "../modules/CanonicalPricingModule.sol";
import {PredictionMarketResolution} from "./PredictionMarketResolution.sol";

/// @title PredictionMarket
/// @notice Concrete market surface using LMSR (Logarithmic Market Scoring Rule) AMM.
/// @dev LMSR buy/sell trades are CRE-report-driven (off-chain compute, on-chain execute).
///      Complete-set operations and resolution remain direct user calls.
///      Most logic lives in inherited modules; this contract provides public entrypoints.
contract PredictionMarket is PredictionMarketResolution {
    using SafeERC20 for IERC20;

    function mintCompleteSets(uint256 amount) public override {
        super.mintCompleteSets(amount);
    }

    function redeemCompleteSets(uint256 amount) public override {
        super.redeemCompleteSets(amount);
    }

    /// @notice Updates deviation-policy thresholds that control canonical pricing safety rails.
    /// @dev Parameter constraints guarantee valid ordering and sane caps:
    /// `soft < stress < hard`,
    /// output caps are non-zero and <= 100%,
    /// unsafe cap is strictly tighter than stress cap.
    function setDeviationPolicy(
        uint16 _softDeviationBps,
        uint16 _stressDeviationBps,
        uint16 _hardDeviationBps,
        uint16 _stressExtraFeeBps,
        uint16 _stressMaxOutBps,
        uint16 _unsafeMaxOutBps
    ) external onlyOwner {
        if (
            _softDeviationBps >= _stressDeviationBps ||
            _stressDeviationBps >= _hardDeviationBps ||
            _hardDeviationBps > MarketConstants.FEE_PRECISION_BPS ||
            _stressExtraFeeBps > MarketConstants.FEE_PRECISION_BPS ||
            _stressMaxOutBps == 0 ||
            _stressMaxOutBps > MarketConstants.FEE_PRECISION_BPS ||
            _unsafeMaxOutBps == 0 ||
            _unsafeMaxOutBps > MarketConstants.FEE_PRECISION_BPS ||
            _unsafeMaxOutBps >= _stressMaxOutBps
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
            _softDeviationBps,
            _stressDeviationBps,
            _hardDeviationBps,
            _stressExtraFeeBps,
            _stressMaxOutBps,
            _unsafeMaxOutBps
        );
    }

    /// @notice Returns current deviation diagnostics for cross-chain monitoring.
    /// @dev In local mode (non-canonical), returns permissive defaults.
    ///      In canonical mode, compares LMSR-stored prices against the hub canonical prices.
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
        // Use LMSR-stored prices instead of reserve-derived prices
        // For LMSR, we derive synthetic "reserves" from prices for the canonical module
        // price_yes = noReserve / (yesReserve + noReserve)
        // So: yesReserve ∝ noPrice, noReserve ∝ yesPrice
        uint256 syntheticYesReserve = lastNoPriceE6;
        uint256 syntheticNoReserve = lastYesPriceE6;

        CanonicalPricingModule.DeviationStatusParams
            memory p = CanonicalPricingModule.DeviationStatusParams({
                yesReserve: syntheticYesReserve,
                noReserve: syntheticNoReserve,
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
        (
            bandId,
            deviationBps,
            effectiveFeeBps,
            maxOutBps,
            allowYesForNo,
            allowNoForYes
        ) = CanonicalPricingModule.deviationStatus(p);
        band = _bandFromId(bandId);
    }

    /// @notice Returns YES probability in `1e6` precision.
    /// @dev LMSR stores prices directly (updated by CRE on each trade).
    ///      In canonical mode, returns the hub-synced value if fresh.
    function getYesPriceProbability() external view returns (uint256) {
        if (!initialized) {
            revert MarketErrors.LMSR__NotInitialized();
        }

        if (_isCanonicalPricingMode()) {
            _ensureCanonicalPriceFresh();
            return canonicalYesPriceE6;
        }

        return lastYesPriceE6;
    }

    /// @notice Returns NO probability in `1e6` precision.
    function getNoPriceProbability() external view returns (uint256) {
        if (!initialized) {
            revert MarketErrors.LMSR__NotInitialized();
        }

        if (_isCanonicalPricingMode()) {
            _ensureCanonicalPriceFresh();
            return canonicalNoPriceE6;
        }

        return lastNoPriceE6;
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
    /// @dev Only owner or cross-chain controller may call after market resolution.
    function withdrawProtocolFees() external {
        if (msg.sender != owner() && msg.sender != crossChainController) {
            revert MarketErrors.PredictionMarket__NotOwner_Or_CrossChainController();
        }
        if (state != State.Resolved) {
            revert MarketErrors.PredictionMarket__StateNeedsToBeResolvedToWithdrawLiquidity();
        }
        if (protocolCollateralFees == 0) return;

        uint256 contractBalance = i_collateral.balanceOf(address(this));

        if (contractBalance < protocolCollateralFees) {
            revert MarketErrors.PredictionMarket__WithdrawLiquidity_InsufficientFee();
        }

        uint256 fees = protocolCollateralFees;
        i_collateral.safeTransfer(msg.sender, fees);
        protocolCollateralFees = 0;

        emit MarketEvents.WithdrawProtocolFees(msg.sender, fees);
    }
}
