// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

/**
 * @title AMMLib
 * @author 0xHimxa
 * @notice Pure math library for constant-product AMM calculations
 * @dev All functions are pure/internal — they operate on values only, never on storage.
 *      Used by PredictionMarket for swap output calculations, LP share math, and price queries.
 */
library AMMLib {
    // ========================================
    // SWAP CALCULATIONS
    // ========================================

    /**
     * @notice Calculates the output amount for a constant-product swap
     * @param reserveIn Current reserve of the input token
     * @param reserveOut Current reserve of the output token
     * @param amountIn Amount of input token being swapped
     * @param feeBps Fee in basis points to deduct from the gross output
     * @param feePrecision Basis points precision (typically 10_000)
     * @return netOut Output amount after fee deduction
     * @return fee Fee amount deducted
     * @return newReserveIn Updated reserve of the input token
     * @return newReserveOut Updated reserve of the output token (fee kept in pool)
     * @dev Implements the formula: k = reserveIn * reserveOut
     *      newReserveIn = reserveIn + amountIn
     *      newReserveOut = k / newReserveIn
     *      grossOut = reserveOut - newReserveOut
     *      Fee is added back to the output reserve to benefit LPs
     */
    function getAmountOut(uint256 reserveIn, uint256 reserveOut, uint256 amountIn, uint256 feeBps, uint256 feePrecision)
        internal
        pure
        returns (uint256 netOut, uint256 fee, uint256 newReserveIn, uint256 newReserveOut)
    {
        // Constant product: k = x * y
        uint256 k = reserveIn * reserveOut;

        // New reserves after adding input
        newReserveIn = reserveIn + amountIn;
        uint256 rawNewReserveOut = k / newReserveIn;

        // Gross output before fees
        uint256 grossOut = reserveOut - rawNewReserveOut;

        // Deduct fee from output
        fee = (grossOut * feeBps) / feePrecision;
        netOut = grossOut - fee;

        // Fee stays in the pool (added back to output reserve)
        newReserveOut = rawNewReserveOut + fee;
    }

    // ========================================
    // PRICE / PROBABILITY CALCULATIONS
    // ========================================

    /**
     * @notice Calculates the implied YES probability based on current reserves
     * @param yesReserve Current YES token reserve
     * @param noReserve Current NO token reserve
     * @param precision Scaling factor (e.g., 1e6 for 6-decimal precision)
     * @return Implied YES probability scaled by precision
     * @dev P(YES) = noReserve / (yesReserve + noReserve)
     *      Higher noReserve relative to yesReserve = higher YES probability
     */
    function getYesProbability(uint256 yesReserve, uint256 noReserve, uint256 precision)
        internal
        pure
        returns (uint256)
    {
        uint256 total = yesReserve + noReserve;
        return (noReserve * precision) / total;
    }

    /**
     * @notice Calculates the implied NO probability based on current reserves
     * @param yesReserve Current YES token reserve
     * @param noReserve Current NO token reserve
     * @param precision Scaling factor (e.g., 1e6 for 6-decimal precision)
     * @return Implied NO probability scaled by precision
     * @dev P(NO) = yesReserve / (yesReserve + noReserve)
     *      Higher yesReserve relative to noReserve = higher NO probability
     */
    function getNoProbability(uint256 yesReserve, uint256 noReserve, uint256 precision)
        internal
        pure
        returns (uint256)
    {
        uint256 total = yesReserve + noReserve;
        return (yesReserve * precision) / total;
    }

    // ========================================
    // LIQUIDITY CALCULATIONS
    // ========================================

    /**
     * @notice Calculates LP shares for adding liquidity
     * @param yesAmount Amount of YES tokens being added
     * @param noAmount Amount of NO tokens being added
     * @param totalShares Current total LP shares
     * @param yesReserve Current YES reserve in the pool
     * @param noReserve Current NO reserve in the pool
     * @return shares Number of LP shares to mint (minimum of proportional calculations)
     * @return usedYes Actual YES tokens consumed (may be less than yesAmount)
     * @return usedNo Actual NO tokens consumed (may be less than noAmount)
     * @dev Takes the minimum of YES-proportional and NO-proportional shares
     *      to avoid skewing pool ratios
     */
    function calculateShares(
        uint256 yesAmount,
        uint256 noAmount,
        uint256 totalShares,
        uint256 yesReserve,
        uint256 noReserve
    ) internal pure returns (uint256 shares, uint256 usedYes, uint256 usedNo) {
        uint256 yesShare = (yesAmount * totalShares) / yesReserve;
        uint256 noShare = (noAmount * totalShares) / noReserve;
        shares = yesShare < noShare ? yesShare : noShare;

        // Calculate actual tokens used to maintain pool ratios
        usedYes = (shares * yesReserve) / totalShares;
        usedNo = (shares * noReserve) / totalShares;
    }

    /**
     * @notice Calculates proportional output for removing liquidity
     * @param reserve Current reserve of the token
     * @param shares Number of LP shares being burned
     * @param totalShares Current total LP shares
     * @return amount Proportional amount of tokens to return
     */
    function calculateProportionalOutput(uint256 reserve, uint256 shares, uint256 totalShares)
        internal
        pure
        returns (uint256 amount)
    {
        amount = (reserve * shares) / totalShares;
    }
}
