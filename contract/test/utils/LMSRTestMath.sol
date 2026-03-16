// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

/// @title LMSRTestMath
/// @notice Lightweight, test-only LMSR math using fixed-point approximations.
/// @dev This is intentionally bounded and approximate to keep invariant tests stable.
///      It clamps inputs to a small range to avoid overflow and large approximation error.
library LMSRTestMath {
    uint256 internal constant WAD = 1e18;
    int256 internal constant WAD_I = 1e18;
    int256 internal constant LN2_WAD = 693147180559945309; // ln(2) * 1e18

    // Clamp exponent inputs to [-0.5, 0.5] to keep Taylor approximation stable.
    int256 internal constant MIN_X = -5e17;
    int256 internal constant MAX_X = 5e17;

    function _clamp(int256 x) internal pure returns (int256) {
        if (x < MIN_X) return MIN_X;
        if (x > MAX_X) return MAX_X;
        return x;
    }

    /// @notice exp(x) in WAD, using 5-term Taylor approximation around 0.
    function expWad(int256 x) internal pure returns (uint256) {
        x = _clamp(x);
        // sum = 1 + x + x^2/2! + x^3/3! + x^4/4! + x^5/5!
        int256 term = WAD_I;
        int256 sum = term;

        term = (term * x) / WAD_I;
        sum += term;

        term = (term * x) / WAD_I;
        sum += term / 2;

        term = (term * x) / WAD_I;
        sum += term / 6;

        term = (term * x) / WAD_I;
        sum += term / 24;

        term = (term * x) / WAD_I;
        sum += term / 120;

        if (sum <= 0) return 0;
        return uint256(sum);
    }

    /// @notice ln(a) in WAD for a in (0, ~3.3] WAD.
    /// @dev Scales `a` into [0.5, 2] WAD then uses a 5-term series on ln(1+y).
    function lnWad(uint256 a) internal pure returns (int256) {
        if (a == 0) return type(int256).min;
        int256 k = 0;

        if (a > 2 * WAD) {
            a = a / 2;
            k = 1;
        } else if (a < WAD / 2) {
            a = a * 2;
            k = -1;
        }

        int256 y = int256(a) - WAD_I; // y in [-0.5, 1] WAD

        // ln(1+y) ≈ y - y^2/2 + y^3/3 - y^4/4 + y^5/5
        int256 term = y;
        int256 sum = term;

        term = (term * y) / WAD_I;
        sum -= term / 2;

        term = (term * y) / WAD_I;
        sum += term / 3;

        term = (term * y) / WAD_I;
        sum -= term / 4;

        term = (term * y) / WAD_I;
        sum += term / 5;

        return sum + (k * LN2_WAD);
    }

    /// @notice LMSR cost function C(q) for binary market in collateral precision (e6).
    function cost(uint256 qYes, uint256 qNo, uint256 b) internal pure returns (uint256) {
        // Convert to dimensionless WAD: x = q / b
        int256 xYes = _clamp(int256(qYes) * WAD_I / int256(b));
        int256 xNo = _clamp(int256(qNo) * WAD_I / int256(b));

        int256 m = xYes > xNo ? xYes : xNo;
        uint256 expYes = expWad(xYes - m);
        uint256 expNo = expWad(xNo - m);
        uint256 sumExp = expYes + expNo; // WAD

        int256 lnSum = int256(m) + lnWad(sumExp); // WAD
        if (lnSum <= 0) return 0;
        return uint256(lnSum) * b / WAD;
    }

    /// @notice LMSR price for YES outcome in 1e6 precision.
    function yesPriceE6(uint256 qYes, uint256 qNo, uint256 b) internal pure returns (uint256) {
        int256 xYes = _clamp(int256(qYes) * WAD_I / int256(b));
        int256 xNo = _clamp(int256(qNo) * WAD_I / int256(b));

        int256 m = xYes > xNo ? xYes : xNo;
        uint256 expYes = expWad(xYes - m);
        uint256 expNo = expWad(xNo - m);
        uint256 sumExp = expYes + expNo;
        if (sumExp == 0) return 500_000;

        return (expYes * 1_000_000) / sumExp;
    }
}
