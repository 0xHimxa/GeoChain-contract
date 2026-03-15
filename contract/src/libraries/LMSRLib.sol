// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

/// @title LMSRLib
/// @notice On-chain validation helpers for CRE-computed LMSR trades.
/// @dev The heavy LMSR math (exp/ln) is computed off-chain by the CRE HTTP handler.
///      This library provides only lightweight validation that the contract needs
///      to verify CRE-reported values are sane before executing trades.
library LMSRLib {
    /// @notice ln(2) scaled to 1e6 precision. Used to compute max subsidy loss for binary markets.
    /// @dev ln(2) ≈ 0.693147... → 693_147 at 1e6 precision.
    uint256 internal constant LN2_E6 = 693_147;

    /// @notice Price precision used throughout the system (1e6 = 100%).
    uint256 internal constant PRICE_PRECISION = 1_000_000;

    /// @notice Max acceptable deviation from perfect price sum (0.1% tolerance).
    uint256 internal constant PRICE_TOLERANCE = 1_000;

    /// @notice Validates that CRE-reported prices sum to approximately PRICE_PRECISION.
    /// @dev Allows ± PRICE_TOLERANCE to account for rounding in off-chain floating-point math.
    /// @param yesPriceE6 YES outcome price in 1e6 precision.
    /// @param noPriceE6 NO outcome price in 1e6 precision.
    /// @return valid True if prices are within acceptable range.
    function validatePriceSum(uint256 yesPriceE6, uint256 noPriceE6) internal pure returns (bool valid) {
        uint256 sum = yesPriceE6 + noPriceE6;
        valid = sum >= PRICE_PRECISION - PRICE_TOLERANCE && sum <= PRICE_PRECISION + PRICE_TOLERANCE;
    }

    /// @notice Validates trade nonce ordering.
    /// @dev Each CRE trade report must carry a nonce equal to the current on-chain nonce.
    ///      The contract increments its nonce after accepting the report.
    /// @param currentNonce The last accepted trade nonce on-chain.
    /// @param reportNonce The nonce carried by the incoming CRE report.
    /// @return valid True if reportNonce == currentNonce.
    function validateTradeNonce(uint64 currentNonce, uint64 reportNonce) internal pure returns (bool valid) {
        valid = reportNonce == currentNonce;
    }

    /// @notice Computes the maximum subsidy loss for a binary LMSR market.
    /// @dev For N=2 outcomes: maxLoss = b × ln(N) = b × ln(2).
    ///      Using integer math: maxLoss = (b * LN2_E6) / 1e6.
    ///      This is the amount of collateral that must be locked at market creation.
    /// @param liquidityParam The LMSR 'b' parameter (in collateral precision, e.g. 6 decimals).
    /// @return subsidyRequired Collateral to lock as market maker subsidy.
    function maxSubsidyLoss(uint256 liquidityParam) internal pure returns (uint256 subsidyRequired) {
        subsidyRequired = (liquidityParam * LN2_E6) / PRICE_PRECISION;
    }
}
