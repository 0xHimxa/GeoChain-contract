// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

/// @title  LMSRTestMath
/// @notice Lightweight, test-only LMSR math using fixed-point approximations.
///
/// @dev    Design goals
///         ─────────────────────────────────────────────────────────────────
///         • All arithmetic is in WAD (1e18) fixed-point unless stated.
///         • exp and ln use 5-term Taylor / Padé approximations whose error
///           is acceptable for fuzz/invariant tests but NOT for production.
///         • Inputs are clamped so the approximations stay within their
///           convergence radius; see individual function docs for details.
///         • No external dependencies; the library is self-contained.
///
///         Known limitations
///         ─────────────────────────────────────────────────────────────────
///         • expWad  is only accurate to ~3 ULP for |x| ≤ 0.5 WAD.
///         • lnWad   handles a ≤ 4 WAD without meaningful error but diverges
///           badly outside that range.
///         • Neither function should be used in mainnet contracts.
library LMSRTestMath {
    // ───────────────────────────── constants ──────────────────────────────

    uint256 internal constant WAD   = 1e18;
    int256  internal constant WAD_I = 1e18;

    /// @dev ln(2) · 1e18, used to reconstruct ln after range-reduction.
    int256 internal constant LN2_WAD = 693_147_180_559_945_309;

    /// @dev Clamp bounds for the normalised exponent argument.
    ///      Taylor exp(x) with 5 terms has < 0.05 % relative error on [-0.5, 0.5].
    int256 internal constant MIN_X = -5e17; // -0.5 WAD
    int256 internal constant MAX_X =  5e17; //  0.5 WAD

    // ─────────────────────────── internal helpers ─────────────────────────

    /// @dev Saturating clamp of `x` to [MIN_X, MAX_X].
    function _clamp(int256 x) internal pure returns (int256) {
        if (x < MIN_X) return MIN_X;
        if (x > MAX_X) return MAX_X;
        return x;
    }

    // ────────────────────────── public math API ───────────────────────────

    /// @notice Approximate e^x in WAD fixed-point.
    ///
    /// @dev    Uses the 5-term Maclaurin series
    ///
    ///             e^x ≈ 1 + x + x²/2! + x³/3! + x⁴/4! + x⁵/5!
    ///
    ///         The recurrence relation is
    ///
    ///             t₀ = 1
    ///             tₙ = tₙ₋₁ · x / n          (all in WAD)
    ///             S  = Σ tₙ
    ///
    ///         Each successive term is obtained by multiplying the previous
    ///         term by x/n – this keeps the factorial denominator exact
    ///         without separate division.
    ///
    ///         FIX (was): The original code applied per-step integer divisions
    ///         (/2, /6, /24, /120) to `term` AFTER it had already accumulated
    ///         the previous step's divisor, yielding compounded denominators
    ///         (2, 12, 288, …) instead of the correct factorials (2, 6, 24, 120).
    ///
    /// @param  x  Signed WAD value; clamped to [-0.5, 0.5] WAD internally.
    /// @return    e^x expressed in WAD (≥ 0).
    function expWad(int256 x) internal pure returns (uint256) {
        x = _clamp(x);

        // t₀ = 1 (WAD)
        int256 t = WAD_I;
        int256 s = WAD_I;

        // t₁ = t₀ · x / 1
        t = (t * x) / WAD_I;          // = x
        s += t;

        // t₂ = t₁ · x / 2
        t = (t * x) / WAD_I / 2;      // = x² / 2!
        s += t;

        // t₃ = t₂ · x / 3
        t = (t * x) / WAD_I / 3;      // = x³ / 3!
        s += t;

        // t₄ = t₃ · x / 4
        t = (t * x) / WAD_I / 4;      // = x⁴ / 4!
        s += t;

        // t₅ = t₄ · x / 5
        t = (t * x) / WAD_I / 5;      // = x⁵ / 5!
        s += t;

        return s <= 0 ? 0 : uint256(s);
    }

    /// @notice Approximate ln(a) in WAD fixed-point.
    ///
    /// @dev    Range-reduction: repeatedly halve or double `a` until it falls
    ///         into [0.5 WAD, 2 WAD], tracking the number of halvings `k`.
    ///         Then compute ln(1+y) for y = a/WAD − 1 via the series
    ///
    ///             ln(1+y) ≈ y − y²/2 + y³/3 − y⁴/4 + y⁵/5
    ///
    ///         and reconstruct ln(a_original) = ln(a_reduced) + k·ln(2).
    ///
    ///         FIX (was): The original code only applied one halving or
    ///         doubling step, leaving large inputs (a >> 2 WAD) or very
    ///         small inputs (a << 0.5 WAD) outside the convergence radius.
    ///         The loop below iterates until `a` is in range.
    ///
    /// @param  a  Unsigned WAD value; must be > 0.  Inputs > ~3.3 WAD
    ///            require the extended range-reduction loop; inputs ≤ 4 WAD
    ///            converge well.
    /// @return    ln(a) in WAD (may be negative for a < WAD).
    function lnWad(uint256 a) internal pure returns (int256) {
        if (a == 0) return type(int256).min;

        int256 k = 0;

        // ── range-reduction loop ──────────────────────────────────────────
        // Halve until a ≤ 2 WAD; double until a ≥ 0.5 WAD.
        // Each halving   adds ln(2); each doubling subtracts ln(2).
        while (a > 2 * WAD) {
            a /= 2;
            k += 1;
        }
        while (a < WAD / 2) {
            a *= 2;
            k -= 1;
        }
        // ─────────────────────────────────────────────────────────────────

        // y ∈ [-0.5, 1] after range-reduction
        int256 y = int256(a) - WAD_I;

        // Maclaurin series for ln(1+y):
        //   t₁ =  y
        //   t₂ = −y²/2
        //   t₃ =  y³/3
        //   t₄ = −y⁴/4
        //   t₅ =  y⁵/5
        int256 t = y;
        int256 s = t;

        t = (t * y) / WAD_I;  // y²
        s -= t / 2;

        t = (t * y) / WAD_I;  // y³
        s += t / 3;

        t = (t * y) / WAD_I;  // y⁴
        s -= t / 4;

        t = (t * y) / WAD_I;  // y⁵
        s += t / 5;

        return s + k * LN2_WAD;
    }

    /// @notice LMSR cost function C(q) for a two-outcome market.
    ///
    /// @dev    The LMSR cost is
    ///
    ///             C(qYes, qNo) = b · ln( e^(qYes/b) + e^(qNo/b) )
    ///
    ///         Numerically stabilised via the log-sum-exp trick:
    ///
    ///             m = max(xYes, xNo)
    ///             C = b · ( m + ln( e^(xYes−m) + e^(xNo−m) ) )
    ///
    ///         where x = q/b (dimensionless, in WAD).
    ///
    ///         The result is returned in the same unit as `b`
    ///         (e.g. e6 collateral if `b` is expressed in e6).
    ///
    /// @param  qYes  YES-outcome quantity (same unit as `b`).
    /// @param  qNo   NO-outcome  quantity (same unit as `b`).
    /// @param  b     Liquidity parameter (same unit as quantities).
    /// @return       Cost C(qYes, qNo) in the same unit as `b`.
    function cost(
        uint256 qYes,
        uint256 qNo,
        uint256 b
    ) internal pure returns (uint256) {
        require(b > 0, "LMSRTestMath: b must be > 0");

        // Normalise to dimensionless WAD and clamp.
        int256 xYes = _clamp(int256(qYes) * WAD_I / int256(b));
        int256 xNo  = _clamp(int256(qNo)  * WAD_I / int256(b));

        // Log-sum-exp stabilisation.
        int256 m = xYes > xNo ? xYes : xNo;

        uint256 eYes   = expWad(xYes - m);
        uint256 eNo    = expWad(xNo  - m);
        uint256 sumExp = eYes + eNo;          // WAD

        // C = b · (m + ln(sumExp))  [in WAD], then scale back to `b` units.
        int256 lnSum = int256(m) + lnWad(sumExp);
        if (lnSum <= 0) return 0;

        return uint256(lnSum) * b / WAD;
    }

    /// @notice LMSR marginal price of the YES outcome, scaled to 1e6.
    ///
    /// @dev    price(YES) = e^(xYes) / (e^(xYes) + e^(xNo))
    ///
    ///         Numerically stabilised identically to `cost`.
    ///         Falls back to 0.5 (500_000) when sumExp rounds to zero.
    ///
    /// @param  qYes  YES-outcome quantity.
    /// @param  qNo   NO-outcome  quantity.
    /// @param  b     Liquidity parameter.
    /// @return       Probability in [0, 1_000_000] (i.e. 1e6 basis points).
    function yesPriceE6(
        uint256 qYes,
        uint256 qNo,
        uint256 b
    ) internal pure returns (uint256) {
        require(b > 0, "LMSRTestMath: b must be > 0");

        int256 xYes = _clamp(int256(qYes) * WAD_I / int256(b));
        int256 xNo  = _clamp(int256(qNo)  * WAD_I / int256(b));

        int256 m = xYes > xNo ? xYes : xNo;

        uint256 eYes   = expWad(xYes - m);
        uint256 eNo    = expWad(xNo  - m);
        uint256 sumExp = eYes + eNo;

        if (sumExp == 0) return 500_000; // degenerate: return 50 %

        return (eYes * 1_000_000) / sumExp;
    }
}