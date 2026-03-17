// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

/// @title AMMLib
/// @notice Pure math utilities for the constant-product pool used by markets.
/// @dev All functions are deterministic and storage-free.
/// The library assumes reserves and token units share the same decimals.
library AMMLib {
    /// @notice Quotes constant-product swap output and resulting reserves.
    /// @dev Math model:
    /// - Invariant before swap: `k = reserveIn * reserveOut`
    /// - After adding input: `newReserveIn = reserveIn + amountIn`
    /// - Raw output reserve: `rawNewReserveOut = k / newReserveIn`
    /// - Gross trader output: `grossOut = reserveOut - rawNewReserveOut`
    /// - Fee is taken from gross output and retained in pool:
    /// `netOut = grossOut - fee`, `newReserveOut = rawNewReserveOut + fee`
    /// This increases LP value by leaving fee inside reserves.
    /// @param reserveIn Input-side reserve before the trade.
    /// @param reserveOut Output-side reserve before the trade.
    /// @param amountIn Amount entering the pool.
    /// @param feeBps Output fee in basis points.
    /// @param feePrecision Basis-point precision, normally `10_000`.
    /// @return netOut Output sent to trader after fee.
    /// @return fee Fee retained in pool.
    /// @return newReserveIn Input reserve after trade.
    /// @return newReserveOut Output reserve after trade including retained fee.
    function getAmountOut(uint256 reserveIn, uint256 reserveOut, uint256 amountIn, uint256 feeBps, uint256 feePrecision)
        internal
        pure
        returns (uint256 netOut, uint256 fee, uint256 newReserveIn, uint256 newReserveOut)
    {
        uint256 k = reserveIn * reserveOut;

        newReserveIn = reserveIn + amountIn;
        uint256 rawNewReserveOut = k / newReserveIn;

        uint256 grossOut = reserveOut - rawNewReserveOut;

        fee = (grossOut * feeBps) / feePrecision;
        netOut = grossOut - fee;

        newReserveOut = rawNewReserveOut + fee;
    }

    /// @notice Returns implied YES probability from reserve ratio.
    /// @param yesReserve YES reserve.
    /// @param noReserve NO reserve.
    /// @param precision Scale, typically `1e6`.
    function getYesProbability(uint256 yesReserve, uint256 noReserve, uint256 precision)
        internal
        pure
        returns (uint256)
    {
        uint256 total = yesReserve + noReserve;
        return (noReserve * precision) / total;
    }

    /// @notice Returns implied NO probability from reserve ratio.
    /// @param yesReserve YES reserve.
    /// @param noReserve NO reserve.
    /// @param precision Scale, typically `1e6`.
    function getNoProbability(uint256 yesReserve, uint256 noReserve, uint256 precision)
        internal
        pure
        returns (uint256)
    {
        uint256 total = yesReserve + noReserve;
        return (yesReserve * precision) / total;
    }

    /// @notice Calculates LP shares for a dual-sided deposit that preserves pool ratio.
    /// @param yesAmount Proposed YES amount.
    /// @param noAmount Proposed NO amount.
    /// @param totalShares Current LP share supply.
    /// @param yesReserve Current YES reserve.
    /// @param noReserve Current NO reserve.
    /// @return shares Shares minted for this deposit.
    /// @return usedYes YES actually consumed.
    /// @return usedNo NO actually consumed.
    /// @dev Share minting uses limiting-side logic:
    /// `yesShare = yesAmount * totalShares / yesReserve`
    /// `noShare  = noAmount  * totalShares / noReserve`
    /// `shares = min(yesShare, noShare)`.
    /// This guarantees resulting reserve ratio stays unchanged.
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

        usedYes = (shares * yesReserve) / totalShares;
        usedNo = (shares * noReserve) / totalShares;
    }

    /// @notice Returns proportional reserve output for a share burn amount.
    /// @dev Used in liquidity removal and resolved-LP settlement paths.
    function calculateProportionalOutput(uint256 reserve, uint256 shares, uint256 totalShares)
        internal
        pure
        returns (uint256 amount)
    {
        amount = (reserve * shares) / totalShares;
    }
}
