// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

/// @title CanonicalPricingModule
/// @notice Pure policy engine for classifying deviation bands and swap controls.
/// @dev The module compares local LMSR YES price with canonical YES price.
/// Deviation in bps is mapped into one of four bands:
/// Normal -> Stress -> Unsafe -> CircuitBreaker.
/// Band then determines fee uplift, max output cap, and direction permissions.
library CanonicalPricingModule {
    uint8 internal constant BAND_NORMAL = 0;
    uint8 internal constant BAND_STRESS = 1;
    uint8 internal constant BAND_UNSAFE = 2;
    uint8 internal constant BAND_CIRCUIT_BREAKER = 3;
    uint256 internal constant UNSAFE_FEE_MULTIPLIER = 2;
    uint256 internal constant CIRCUIT_BREAKER_FEE_MULTIPLIER = 5;
    uint256 internal constant UNSAFE_MAX_OUT_DIVISOR = 1;
    uint256 internal constant CIRCUIT_BREAKER_MAX_OUT_DIVISOR = 2;

    struct SwapControlsParams {
        bool yesForNo;
        uint256 reserveOut;
        uint256 localYesPriceE6;
        uint256 pricePrecision;
        uint256 canonicalYesPriceE6;
        uint16 softDeviationBps;
        uint16 stressDeviationBps;
        uint16 hardDeviationBps;
        uint16 stressExtraFeeBps;
        uint16 stressMaxOutBps;
        uint16 unsafeMaxOutBps;
        uint256 swapFeeBps;
        uint256 feePrecisionBps;
    }

    struct DeviationStatusParams {
        uint256 localYesPriceE6;
        uint256 pricePrecision;
        uint256 canonicalYesPriceE6;
        uint16 softDeviationBps;
        uint16 stressDeviationBps;
        uint16 hardDeviationBps;
        uint16 stressExtraFeeBps;
        uint16 stressMaxOutBps;
        uint16 unsafeMaxOutBps;
        uint256 swapFeeBps;
        uint256 feePrecisionBps;
    }

    /// @notice Computes execution guardrails for a concrete swap direction.
    /// @param p Parameters containing local price, canonical price, and policy thresholds.
    /// @return bandId Current deviation band enum id.
    /// @return effectiveFeeBps Swap fee after band adjustment.
    /// @return maxOut Max output token amount allowed for this trade.
    /// @return allowDirection Whether this direction is allowed in current band.
    /// @dev Key calculations:
    /// `deviationBps = abs(localYes - canonicalYes) * feePrecisionBps / pricePrecision`.
    /// Band policy:
    /// - Normal: base fee, unlimited output, both directions allowed.
    /// - Stress: extra fee + capped output.
    /// - Unsafe: extra fee + tighter cap + only price-corrective direction allowed.
    /// - CircuitBreaker: no trading direction allowed.
    function swapControls(SwapControlsParams memory p)
        public
        pure
        returns (uint8 bandId, uint256 effectiveFeeBps, uint256 maxOut, bool allowDirection)
    {
        uint256 localYesPriceE6Value = p.localYesPriceE6;
        uint256 diff = localYesPriceE6Value > p.canonicalYesPriceE6
            ? localYesPriceE6Value - p.canonicalYesPriceE6
            : p.canonicalYesPriceE6 - localYesPriceE6Value;
        uint256 deviationBpsValue = (diff * p.feePrecisionBps) / p.pricePrecision;

        if (deviationBpsValue <= p.softDeviationBps) {
            bandId = BAND_NORMAL;
        } else if (deviationBpsValue <= p.stressDeviationBps) {
            bandId = BAND_STRESS;
        } else if (deviationBpsValue <= p.hardDeviationBps) {
            bandId = BAND_UNSAFE;
        } else {
            bandId = BAND_CIRCUIT_BREAKER;
        }

        effectiveFeeBps = p.swapFeeBps;
        maxOut = type(uint256).max;
        allowDirection = true;

        if (bandId == BAND_STRESS) {
            effectiveFeeBps += p.stressExtraFeeBps;
            maxOut = (p.reserveOut * p.stressMaxOutBps) / p.feePrecisionBps;
        } else if (bandId == BAND_UNSAFE) {
            effectiveFeeBps += uint256(p.stressExtraFeeBps) * UNSAFE_FEE_MULTIPLIER;
            uint256 reducedUnsafeMaxOutBps = _reducedMaxOutBps(
                p.unsafeMaxOutBps,
                UNSAFE_MAX_OUT_DIVISOR
            );
            maxOut = (p.reserveOut * reducedUnsafeMaxOutBps) / p.feePrecisionBps;

            bool allowYesForNo = localYesPriceE6Value > p.canonicalYesPriceE6;
            bool allowNoForYes = localYesPriceE6Value < p.canonicalYesPriceE6;
            allowDirection = (p.yesForNo && allowYesForNo) || (!p.yesForNo && allowNoForYes);
        } else if (bandId == BAND_CIRCUIT_BREAKER) {
            effectiveFeeBps +=
                uint256(p.stressExtraFeeBps) * CIRCUIT_BREAKER_FEE_MULTIPLIER;
            uint256 reducedCircuitMaxOutBps = _reducedMaxOutBps(
                p.unsafeMaxOutBps,
                CIRCUIT_BREAKER_MAX_OUT_DIVISOR
            );
            maxOut = (p.reserveOut * reducedCircuitMaxOutBps) / p.feePrecisionBps;
            allowDirection = false;
        }
    }

    /// @notice Returns full current deviation status independent of a chosen direction.
    /// @param p Parameters containing local price, canonical price, and policy thresholds.
    /// @return bandId Current deviation band enum id.
    /// @return deviationBpsValue Absolute canonical/local deviation in bps.
    /// @return effectiveFeeBps Swap fee after band adjustment.
    /// @return maxOutBps Output cap expressed in bps of output reserve.
    /// @return allowYesForNo Whether YES->NO is currently allowed.
    /// @return allowNoForYes Whether NO->YES is currently allowed.
    /// @dev Uses same deviation/band computation as `swapControls`, but outputs both direction flags.
    /// This is primarily used by automation to decide if/which corrective trade is allowed.
    function deviationStatus(DeviationStatusParams memory p)
        public
        pure
        returns (
            uint8 bandId,
            uint256 deviationBpsValue,
            uint256 effectiveFeeBps,
            uint256 maxOutBps,
            bool allowYesForNo,
            bool allowNoForYes
        )
    {
        uint256 localYesPriceE6Value = p.localYesPriceE6;
        uint256 diff = localYesPriceE6Value > p.canonicalYesPriceE6
            ? localYesPriceE6Value - p.canonicalYesPriceE6
            : p.canonicalYesPriceE6 - localYesPriceE6Value;
        deviationBpsValue = (diff * p.feePrecisionBps) / p.pricePrecision;

        if (deviationBpsValue <= p.softDeviationBps) {
            bandId = BAND_NORMAL;
        } else if (deviationBpsValue <= p.stressDeviationBps) {
            bandId = BAND_STRESS;
        } else if (deviationBpsValue <= p.hardDeviationBps) {
            bandId = BAND_UNSAFE;
        } else {
            bandId = BAND_CIRCUIT_BREAKER;
        }

        effectiveFeeBps = p.swapFeeBps;
        maxOutBps = p.feePrecisionBps;
        allowYesForNo = true;
        allowNoForYes = true;

        if (bandId == BAND_STRESS) {
            effectiveFeeBps += p.stressExtraFeeBps;
            maxOutBps = p.stressMaxOutBps;
        } else if (bandId == BAND_UNSAFE) {
            effectiveFeeBps += uint256(p.stressExtraFeeBps) * UNSAFE_FEE_MULTIPLIER;
            maxOutBps = _reducedMaxOutBps(
                p.unsafeMaxOutBps,
                UNSAFE_MAX_OUT_DIVISOR
            );
            allowYesForNo = localYesPriceE6Value > p.canonicalYesPriceE6;
            allowNoForYes = localYesPriceE6Value < p.canonicalYesPriceE6;
        } else if (bandId == BAND_CIRCUIT_BREAKER) {
            effectiveFeeBps +=
                uint256(p.stressExtraFeeBps) * CIRCUIT_BREAKER_FEE_MULTIPLIER;
            allowYesForNo = false;
            allowNoForYes = false;
            maxOutBps = _reducedMaxOutBps(
                p.unsafeMaxOutBps,
                CIRCUIT_BREAKER_MAX_OUT_DIVISOR
            );
        }
    }

    function _reducedMaxOutBps(
        uint256 maxOutBps,
        uint256 divisor
    ) private pure returns (uint256 reducedMaxOutBps) {
        reducedMaxOutBps = maxOutBps / divisor;
        if (reducedMaxOutBps == 0) {
            reducedMaxOutBps = 1;
        }
    }
}
