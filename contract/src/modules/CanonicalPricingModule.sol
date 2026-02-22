// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

/// @notice Stateless helper module for canonical price/deviation policy calculations.
library CanonicalPricingModule {
    uint8 internal constant BAND_NORMAL = 0;
    uint8 internal constant BAND_STRESS = 1;
    uint8 internal constant BAND_UNSAFE = 2;
    uint8 internal constant BAND_CIRCUIT_BREAKER = 3;

    struct SwapControlsParams {
        bool yesForNo;
        uint256 reserveOut;
        uint256 yesReserve;
        uint256 noReserve;
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
        uint256 yesReserve;
        uint256 noReserve;
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

    function swapControls(SwapControlsParams memory p)
        public
        pure
        returns (uint8 bandId, uint256 effectiveFeeBps, uint256 maxOut, bool allowDirection)
    {
        uint256 localYesPriceE6Value = (p.noReserve * p.pricePrecision) / (p.yesReserve + p.noReserve);
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
            effectiveFeeBps += p.stressExtraFeeBps;
            maxOut = (p.reserveOut * p.unsafeMaxOutBps) / p.feePrecisionBps;

            bool allowYesForNo = localYesPriceE6Value > p.canonicalYesPriceE6;
            bool allowNoForYes = localYesPriceE6Value < p.canonicalYesPriceE6;
            allowDirection = (p.yesForNo && allowYesForNo) || (!p.yesForNo && allowNoForYes);
        } else if (bandId == BAND_CIRCUIT_BREAKER) {
            allowDirection = false;
        }
    }

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
        uint256 localYesPriceE6Value = (p.noReserve * p.pricePrecision) / (p.yesReserve + p.noReserve);
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
            effectiveFeeBps += p.stressExtraFeeBps;
            maxOutBps = p.unsafeMaxOutBps;
            allowYesForNo = localYesPriceE6Value > p.canonicalYesPriceE6;
            allowNoForYes = localYesPriceE6Value < p.canonicalYesPriceE6;
        } else if (bandId == BAND_CIRCUIT_BREAKER) {
            allowYesForNo = false;
            allowNoForYes = false;
            maxOutBps = 0;
        }
    }
}
