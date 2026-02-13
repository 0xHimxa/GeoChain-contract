// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

/**
 * @title FeeLib
 * @author 0xHimxa
 * @notice Pure library for fee calculations used across the PredictionMarket system
 * @dev All functions are pure/internal — they operate on values only, never on storage.
 *      Provides standardized fee computation for swaps, minting, and redemption.
 */
library FeeLib {
    /**
     * @notice Calculates the fee for a given amount
     * @param amount The gross amount to calculate fee on
     * @param feeBps Fee in basis points (e.g., 400 = 4%)
     * @param feePrecision Basis points precision (typically 10_000)
     * @return fee The calculated fee amount
     */
    function calculateFee(uint256 amount, uint256 feeBps, uint256 feePrecision) internal pure returns (uint256 fee) {
        fee = (amount * feeBps) / feePrecision;
    }

    /**
     * @notice Calculates fee and returns both net amount and fee
     * @param amount The gross amount
     * @param feeBps Fee in basis points (e.g., 300 = 3%)
     * @param feePrecision Basis points precision (typically 10_000)
     * @return netAmount Amount after fee deduction
     * @return fee The fee amount deducted
     * @dev Convenience function that combines fee calculation with subtraction
     *      Used by mintCompleteSets, redeemCompleteSets, and redeem
     */
    function deductFee(uint256 amount, uint256 feeBps, uint256 feePrecision)
        internal
        pure
        returns (uint256 netAmount, uint256 fee)
    {
        fee = (amount * feeBps) / feePrecision;
        netAmount = amount - fee;
    }
}
