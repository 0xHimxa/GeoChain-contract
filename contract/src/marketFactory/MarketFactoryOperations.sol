// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Resolution, MarketConstants, State} from "../libraries/MarketTypes.sol";
import {AMMLib} from "../libraries/AMMLib.sol";
import {PredictionMarket} from "../predictionMarket/PredictionMarket.sol";
import {PredictionMarketBase} from "../predictionMarket/PredictionMarketBase.sol";

import {MarketFactoryCcip} from "./MarketFactoryCcip.sol";

/// @title MarketFactoryOperations
/// @notice Report-driven and owner-driven operational actions on registered markets.
abstract contract MarketFactoryOperations is MarketFactoryCcip {
    using SafeERC20 for IERC20;

    /// @dev Central dispatcher for workflow reports delivered through the receiver path.
    /// The payload is expected to be `(string actionType, bytes payload)`.
    /// This function hashes the action string and routes to one internal operation:
    /// price broadcast, spoke sync, resolution broadcast, market creation, unsafe arbitrage,
    /// factory funding, direct withdrawals, or queued-withdraw processing.
    /// Reverts if the action string is not recognized so bad/unknown reports cannot execute.
    function _processReport(bytes calldata report) internal override {
        (string memory actionType, bytes memory payload) = abi.decode(report, (string, bytes));
        bytes32 actionTypeHash = keccak256(abi.encode(actionType));
        bytes32 syncSpokeActionHash = hashed_SyncSpokeCanonicalPrice;
        bytes32 mintCollateralToActionHash = keccak256(abi.encode("mintCollateralTo"));
        if (syncSpokeActionHash == bytes32(0)) {
            syncSpokeActionHash = keccak256(abi.encode("syncSpokeCanonicalPrice"));
        }

        if (actionTypeHash == hashed_BroadCastPrice) {
            (uint256 marketId, uint256 yesPriceE6, uint256 noPriceE6, uint256 validUntil) =
                abi.decode(payload, (uint256, uint256, uint256, uint256));
            _broadcastCanonicalPrice(marketId, yesPriceE6, noPriceE6, validUntil);
        } else if (actionTypeHash == syncSpokeActionHash) {
            (uint256 marketId, uint256 yesPriceE6, uint256 noPriceE6, uint256 validUntil) =
                abi.decode(payload, (uint256, uint256, uint256, uint256));
            _syncSpokeCanonicalPrice(marketId, yesPriceE6, noPriceE6, validUntil);
        } else if (actionTypeHash == hashed_BroadCastResolution) {
            (uint256 marketId, Resolution outcome, string memory proofUrl) =
                abi.decode(payload, (uint256, Resolution, string));

            _broadcastResolution(marketId, outcome, proofUrl);
        } else if (actionTypeHash == hashed_CreateMarket) {
            (string memory question, uint256 closeTime, uint256 resolutionTime) =
                abi.decode(payload, (string, uint256, uint256));

            _createMarket(question, closeTime, resolutionTime, initailEventLiquidity);
        } else if (actionTypeHash == hashed_PriceCorrection) {
            (uint256 marketId, uint256 maxSpendCollateral, uint256 minDeviationImprovementBps) =
                abi.decode(payload, (uint256, uint256, uint256));
            _arbitrateUnsafeMarket(marketId, maxSpendCollateral, minDeviationImprovementBps);
        } else if (actionTypeHash == hashed_AddLiquidityToFactory) {
            _addLiquidityToFactory();
        } else if (actionTypeHash == mintCollateralToActionHash) {
            (address receiver, uint256 amount) = abi.decode(payload, (address, uint256));
            _mintCollateralTo(receiver, amount);
        } else if (actionTypeHash == hashed_WithCollatralAndFee) {
            uint256 marketId = abi.decode(payload, (uint256));
            _withdrawCollateralFromEvents(marketId);
            _withdrawEventFeeWhenResolved(marketId);
        } else if (actionTypeHash == hashed_ProcessPendingWithdrawals) {
            uint256 maxItems = abi.decode(payload, (uint256));
            _processPendingWithdrawals(maxItems);
        } else {
            revert MarketFactory__ActionNotRecognized();
        }
    }

    /// @notice Returns the current collateral token balance held by the factory.
    /// @dev Useful for monitoring whether the factory still has enough collateral
    /// for market operations that depend on this contract acting as a participant.
    function getMarketFactoryCollateralBalance() external view returns (uint256) {
        return collateral.balanceOf(address(this));
    }

    /// @notice Owner entrypoint for corrective arbitrage when a market is in unsafe deviation.
    /// @dev Delegates to `_arbitrateUnsafeMarket`, which enforces that:
    /// 1) market exists,
    /// 2) market is currently in unsafe band,
    /// 3) there is at least one allowed correction direction,
    /// 4) deviation strictly improves by at least `minDeviationImprovementBps`.
    function arbitrateUnsafeMarket(uint256 marketId, uint256 maxSpendCollateral, uint256 minDeviationImprovementBps)
        external
        onlyOwner
    {
        return _arbitrateUnsafeMarket(marketId, maxSpendCollateral, minDeviationImprovementBps);
    }

    /// @dev Performs one bounded arbitrage cycle designed to pull AMM price toward canonical price.
    /// Logic flow:
    /// 1) Load market + current deviation controls from `getDeviationStatus`.
    /// 2) Require `Unsafe` band (band id 2); otherwise no correction is needed/allowed.
    /// 3) Pick the allowed swap direction (`yesForNo` or `noForYes`) from market policy.
    /// 4) Compute max output allowed by policy:
    /// `maxOut = reserveOut * maxOutBps / 10_000`.
    /// 5) Find the largest collateral spend <= `maxSpendCollateral` whose predicted swap output
    /// stays under `maxOut` (via binary search in `_capSpendForMaxOut`).
    /// 6) Mint complete sets with that spend, then swap net outcome amount in chosen direction.
    /// 7) Re-read deviation and require strict improvement by at least caller threshold.
    /// If any step fails constraints, the transaction reverts and no partial correction remains.
    function _arbitrateUnsafeMarket(uint256 marketId, uint256 maxSpendCollateral, uint256 minDeviationImprovementBps)
        internal
    {
        UnsafeArbContext memory ctx;
        ctx.marketAddress = marketById[marketId];
        if (ctx.marketAddress == address(0)) revert MarketFactory__MarketNotFound();
        if (maxSpendCollateral == 0) revert MarketFactory__ArbZeroAmount();

        ctx.market = PredictionMarket(ctx.marketAddress);
    PredictionMarketBase.DeviationBand band;
        bool allowYesForNo;
        bool allowNoForYes;
        (band, ctx.deviationBefore, ctx.effectiveFeeBps, ctx.maxOutBps, allowYesForNo, allowNoForYes) =
            ctx.market.getDeviationStatus();

        if (uint8(band) != 2) revert MarketFactory__ArbNotUnsafe();
        if (!allowYesForNo && !allowNoForYes) revert MarketFactory__ArbNoDirection();

        ctx.yesForNo = allowYesForNo;
        ctx.reserveIn = ctx.yesForNo ? ctx.market.yesReserve() : ctx.market.noReserve();
        ctx.reserveOut = ctx.yesForNo ? ctx.market.noReserve() : ctx.market.yesReserve();
        ctx.maxOut = (ctx.reserveOut * ctx.maxOutBps) / MarketConstants.FEE_PRECISION_BPS;
        if (ctx.maxOut == 0) revert MarketFactory__ArbZeroAmount();

        ctx.bestSpend =
            _capSpendForMaxOut(maxSpendCollateral, ctx.reserveIn, ctx.reserveOut, ctx.effectiveFeeBps, ctx.maxOut);
        if (ctx.bestSpend == 0) revert MarketFactory__ArbZeroAmount();

        _ensureAllowance(collateral, ctx.marketAddress, ctx.bestSpend);
        ctx.market.mintCompleteSets(ctx.bestSpend);

        ctx.swapIn = _netOutcomeFromCollateral(ctx.bestSpend);
        _executeUnsafeArbSwap(ctx.market, ctx.marketAddress, ctx.yesForNo, ctx.swapIn);

        (, ctx.deviationAfter,,,,) = ctx.market.getDeviationStatus();
        if (ctx.deviationBefore <= ctx.deviationAfter) revert MarketFactory__ArbInsufficientImprovement();
        if (ctx.deviationBefore - ctx.deviationAfter < minDeviationImprovementBps) {
            revert MarketFactory__ArbInsufficientImprovement();
        }

        emit UnsafeArbitrageExecuted(
            ctx.marketAddress, ctx.yesForNo, ctx.bestSpend, ctx.deviationBefore, ctx.deviationAfter
        );
    }

    /// @dev Executes the swap leg of the correction after complete-set minting.
    /// `swapIn` is already net of mint fee, so this function only approves the proper token
    /// (YES or NO) and calls the matching market swap entrypoint.
    /// Using `minOut = 0` is intentional because the policy cap/deviation checks are done
    /// by the market + caller-side sizing logic, not by user slippage preference here.
    function _executeUnsafeArbSwap(PredictionMarket m, address marketAddress, bool yesForNo, uint256 swapIn) internal {
        if (yesForNo) {
            _ensureAllowance(IERC20(address(m.yesToken())), marketAddress, swapIn);
            m.swapYesForNo(swapIn, 0);
        } else {
            _ensureAllowance(IERC20(address(m.noToken())), marketAddress, swapIn);
            m.swapNoForYes(swapIn, 0);
        }
    }

    /// @dev Converts collateral spend into actual tradable outcome tokens after mint fee.
    /// Formula:
    /// `fee = collateralAmount * MINT_COMPLETE_SETS_FEE_BPS / FEE_PRECISION_BPS`
    /// `net = collateralAmount - fee`
    /// The returned value is what can be used as swap input right after `mintCompleteSets`.
    function _netOutcomeFromCollateral(uint256 collateralAmount) internal pure returns (uint256) {
        uint256 fee = (collateralAmount * MarketConstants.MINT_COMPLETE_SETS_FEE_BPS) / MarketConstants.FEE_PRECISION_BPS;
        return collateralAmount - fee;
    }

    /// @dev Finds the largest collateral spend whose predicted swap output does not exceed `maxOut`.
    /// This is a monotonic search problem:
    /// larger spend -> larger swap output, so binary search is efficient and safe.
    /// Each iteration:
    /// 1) pick midpoint spend,
    /// 2) convert to net outcome via `_netOutcomeFromCollateral`,
    /// 3) simulate AMM output with `AMMLib.getAmountOut`,
    /// 4) keep or shrink bounds depending on whether `out <= maxOut`.
    /// 16 iterations gives a tight bound for uint-sized values with low gas overhead.
    function _capSpendForMaxOut(
        uint256 maxSpend,
        uint256 reserveIn,
        uint256 reserveOut,
        uint256 feeBps,
        uint256 maxOut
    ) internal pure returns (uint256) {
        uint256 low = 0;
        uint256 high = maxSpend;
        for (uint256 i = 0; i < 16; i++) {
            uint256 mid = (low + high + 1) / 2;
            uint256 swapIn = _netOutcomeFromCollateral(mid);
            (uint256 out,,,) = AMMLib.getAmountOut(reserveIn, reserveOut, swapIn, feeBps, MarketConstants.FEE_PRECISION_BPS);
            if (out <= maxOut) {
                low = mid;
            } else {
                high = mid - 1;
            }
        }
        return low;
    }

    /// @dev Makes sure allowance is sufficient without resetting every call.
    /// If current allowance already covers `amount`, no state write is performed.
    /// Otherwise increases by the exact deficit to avoid unnecessary large approvals.
    function _ensureAllowance(IERC20 token, address spender, uint256 amount) internal {
        uint256 allowance = token.allowance(address(this), spender);
        if (allowance < amount) {
            token.safeIncreaseAllowance(spender, amount - allowance);
        }
    }

    /// @notice Withdraws both LP collateral and protocol fees from one market.
    /// @dev This is a convenience wrapper to execute both withdrawal paths together
    /// once a market is resolved and factory wants to collect everything in one call.
    function withdrawMarketFactoryCollateralAndFee(uint256 _marketId) external onlyOwner {
        _withdrawCollateralFromEvents(_marketId);
        _withdrawEventFeeWhenResolved(_marketId);
    }

    /// @dev Withdraws factory-owned LP share value as collateral from a market.
    /// Reads factory share balance from the market, then calls market withdrawal.
    /// Market state checks are enforced by the market contract itself.
    function _withdrawCollateralFromEvents(uint256 _marketId) internal {
        address marketAddress = marketById[_marketId];
        if (marketAddress == address(0)) revert MarketFactory__MarketNotFound();

        uint256 share = PredictionMarket(marketAddress).lpShares(address(this));
        PredictionMarket(marketAddress).withdrawLiquidityCollateral(share);
    }

    /// @dev Pulls protocol fee balance accumulated in one resolved market.
    /// The market enforces that only owner/cross-chain controller can withdraw and that
    /// resolution requirements are met.
    function _withdrawEventFeeWhenResolved(uint256 _marketId) internal {
        address marketAddress = marketById[_marketId];
        if (marketAddress == address(0)) revert MarketFactory__MarketNotFound();

        PredictionMarket(marketAddress).withdrawProtocolFees();
    }

    /// @notice Queues a market for deferred withdrawal processing.
    /// @dev Useful when resolution and withdrawal are decoupled; processing can then run in batches.
    function enqueueWithdraw(uint256 marketId) external onlyOwner {
        _enqueueWithdraw(marketId);
    }

    /// @notice Processes pending withdrawals in bounded batches.
    /// @dev Returns:
    /// `attempted` = queue items consumed this call,
    /// `succeeded` = items that completed both collateral + fee withdrawal,
    /// `remaining` = items still pending after optional queue compaction.
    function processPendingWithdrawals(uint256 maxItems)
        external
        onlyOwner
        returns (uint256 attempted, uint256 succeeded, uint256 remaining)
    {
        return _processPendingWithdrawals(maxItems);
    }

    /// @dev Batch processor for deferred market withdrawals.
    /// Per queue item:
    /// 1) dequeue and clear queued-flag,
    /// 2) skip if market mapping no longer exists,
    /// 3) if market not resolved yet, requeue it for a future attempt,
    /// 4) if factory has zero LP shares there, skip as no collateral is claimable,
    /// 5) otherwise withdraw LP collateral and protocol fees, mark as succeeded.
    /// The queue head is advanced regardless of outcome; unresolved markets are explicitly requeued.
    function _processPendingWithdrawals(uint256 maxItems)
        internal
        returns (uint256 attempted, uint256 succeeded, uint256 remaining)
    {
        if (maxItems == 0) revert MarketFactory__InvalidMaxBatch();

        uint256 head = pendingWithdrawHead;
        uint256 len = pendingWithdrawQueue.length;

        while (attempted < maxItems && head < len) {
            uint256 marketId = pendingWithdrawQueue[head];
            head++;
            attempted++;

            isPendingWithdrawQueued[marketId] = false;
            emit WithdrawDequeued(marketId);

            address marketAddress = marketById[marketId];
            if (marketAddress == address(0)) {
                continue;
            }

            if (uint256(PredictionMarket(marketAddress).state()) != uint256(State.Resolved)) {
                _enqueueWithdraw(marketId);
                emit WithdrawRequeued(marketId);
                emit WithdrawSkippedNotResolved(marketId);
                continue;
            }

            if (PredictionMarket(marketAddress).lpShares(address(this)) == 0) {
                emit WithdrawSkippedNoShares(marketId);
                continue;
            }

            _withdrawCollateralFromEvents(marketId);
            _withdrawEventFeeWhenResolved(marketId);
            succeeded++;
            emit WithdrawProcessed(marketId);
        }

        pendingWithdrawHead = head;
        _compactPendingWithdrawQueue();
        remaining = pendingWithdrawQueue.length - pendingWithdrawHead;
    }

    /// @notice Number of markets still pending in withdraw queue.
    /// @dev Computed as `queue length - head`, so consumed historical entries are not counted.
    function getPendingWithdrawCount() external view returns (uint256) {
        return pendingWithdrawQueue.length - pendingWithdrawHead;
    }

    /// @notice Reads one queued market id by logical index from current queue head.
    /// @dev `indexFromHead = 0` returns the next market that would be processed.
    function getPendingWithdrawAt(uint256 indexFromHead) external view returns (uint256) {
        uint256 idx = pendingWithdrawHead + indexFromHead;
        if (idx >= pendingWithdrawQueue.length) revert MarketFactory__MarketNotFound();
        return pendingWithdrawQueue[idx];
    }

    /// @dev Compacts queue storage when a large consumed prefix has accumulated.
    /// Without this, `pendingWithdrawQueue` can grow forever while `pendingWithdrawHead` moves forward.
    /// Compaction is triggered only when enough items were consumed (`head >= 50` and at least half).
    /// Remaining active entries are copied to a fresh array and head resets to zero.
    function _compactPendingWithdrawQueue() internal {
        uint256 head = pendingWithdrawHead;
        uint256 len = pendingWithdrawQueue.length;
        if (head < 50 || head * 2 < len) {
            return;
        }

        uint256 remaining = len - head;
        uint256[] memory tmp = new uint256[](remaining);
        for (uint256 i = 0; i < remaining; i++) {
            tmp[i] = pendingWithdrawQueue[head + i];
        }

        delete pendingWithdrawQueue;
        for (uint256 j = 0; j < remaining; j++) {
            pendingWithdrawQueue.push(tmp[j]);
        }
        pendingWithdrawHead = 0;
    }

    /// @notice Returns all currently active market addresses.
    /// @dev Active list excludes markets removed after resolution cleanup.
    function getActiveEventList() external view returns (address[] memory) {
        return activeMarkets;
    }

    /// @notice Returns all markets currently awaiting manual review.
    function getManualReviewEventList() external view returns (address[] memory) {
        return manualReviewMarkets;
    }
}
