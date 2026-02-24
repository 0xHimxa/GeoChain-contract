// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

/// @title FeeLib
/// @notice Shared pure helpers for fee math in basis points.
/// @dev The calling contract controls rounding behavior implicitly through Solidity integer division.
library FeeLib {
    /// @notice Computes fee amount from a gross amount.
    /// @dev Formula: `fee = amount * feeBps / feePrecision`.
    /// Rounds down toward zero due to integer division.
    /// @param amount Gross amount.
    /// @param feeBps Fee in basis points.
    /// @param feePrecision Basis-point precision, normally `10_000`.
    function calculateFee(uint256 amount, uint256 feeBps, uint256 feePrecision) internal pure returns (uint256 fee) {
        fee = (amount * feeBps) / feePrecision;
    }

    /// @notice Splits gross amount into net and fee components.
    /// @param amount Gross amount.
    /// @param feeBps Fee in basis points.
    /// @param feePrecision Basis-point precision, normally `10_000`.
    /// @return netAmount Amount after fee.
    /// @return fee Fee taken from `amount`.
    /// @dev Equivalent to:
    /// `fee = amount * feeBps / feePrecision`
    /// `netAmount = amount - fee`.
    function deductFee(uint256 amount, uint256 feeBps, uint256 feePrecision)
        internal
        pure
        returns (uint256 netAmount, uint256 fee)
    {
        fee = (amount * feeBps) / feePrecision;
        netAmount = amount - fee;
    }
}
