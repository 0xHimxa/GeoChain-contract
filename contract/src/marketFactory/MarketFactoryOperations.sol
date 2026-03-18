// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {
    SafeERC20
} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Resolution, MarketConstants, State} from "../libraries/MarketTypes.sol";
import {PredictionMarket} from "../predictionMarket/PredictionMarket.sol";
import {
    PredictionMarketBase
} from "../predictionMarket/PredictionMarketBase.sol";

import {MarketFactoryCcip} from "./MarketFactoryCcip.sol";

/// @title MarketFactoryOperations
/// @notice Report-driven and owner-driven operational actions on registered markets.
abstract contract MarketFactoryOperations is MarketFactoryCcip {
    using SafeERC20 for IERC20;
    bytes32 internal constant HASHED_PRE_CLOSE_LMSR_SELL = keccak256(abi.encode("preCloseLmsrSell"));
    uint256 internal constant PRE_CLOSE_SELL_WINDOW = 2 minutes;

    /// @dev Central dispatcher for workflow reports delivered through the receiver path.
    /// The payload is expected to be `(string actionType, bytes payload)`.
    /// This function hashes the action string and routes to one internal operation:
    /// price broadcast, spoke sync, resolution broadcast, market creation, unsafe arbitrage,
    /// factory funding, direct withdrawals, or queued-withdraw processing.
    /// Reverts if the action string is not recognized so bad/unknown reports cannot execute.
    function _processReport(bytes calldata report) internal override {
        (string memory actionType, bytes memory payload) = abi.decode(
            report,
            (string, bytes)
        );
        bytes32 actionTypeHash = keccak256(abi.encode(actionType));
        bytes32 syncSpokeActionHash = hashed_SyncSpokeCanonicalPrice;
        bytes32 mintCollateralToActionHash = keccak256(
            abi.encode("mintCollateralTo")
        );
        if (syncSpokeActionHash == bytes32(0)) {
            syncSpokeActionHash = keccak256(
                abi.encode("syncSpokeCanonicalPrice")
            );
        }

        if (actionTypeHash == hashed_BroadCastPrice) {
            (
                uint256 marketId,
                uint256 yesPriceE6,
                uint256 noPriceE6,
                uint256 validUntil
            ) = abi.decode(payload, (uint256, uint256, uint256, uint256));
            _broadcastCanonicalPrice(
                marketId,
                yesPriceE6,
                noPriceE6,
                validUntil
            );
        } else if (actionTypeHash == syncSpokeActionHash) {
            (
                uint256 marketId,
                uint256 yesPriceE6,
                uint256 noPriceE6,
                uint256 validUntil
            ) = abi.decode(payload, (uint256, uint256, uint256, uint256));
            _syncSpokeCanonicalPrice(
                marketId,
                yesPriceE6,
                noPriceE6,
                validUntil
            );
        } else if (actionTypeHash == hashed_BroadCastResolution) {
            (uint256 marketId, Resolution outcome, string memory proofUrl) = abi
                .decode(payload, (uint256, Resolution, string));

            _broadcastResolution(marketId, outcome, proofUrl);
        } else if (actionTypeHash == hashed_CreateMarket) {
            (
                string memory question,
                uint256 closeTime,
                uint256 resolutionTime
            ) = abi.decode(payload, (string, uint256, uint256));

            _createMarket(
                question,
                closeTime,
                resolutionTime,
                initailEventLiquidity
            );
        } else if (actionTypeHash == hashed_PriceCorrection) {
            (
                uint256 marketId,
                uint8 outcomeIndex,
                uint256 sharesDelta,
                uint256 costDelta,
                uint256 newYesPriceE6,
                uint256 newNoPriceE6,
                uint64 nonce,
                uint256 maxSpendCollateral,
                uint256 minDeviationImprovementBps
            ) = abi.decode(
                    payload,
                    (
                        uint256,
                        uint8,
                        uint256,
                        uint256,
                        uint256,
                        uint256,
                        uint64,
                        uint256,
                        uint256
                    )
                );
            _arbitrateUnsafeMarket(
                marketId,
                outcomeIndex,
                sharesDelta,
                costDelta,
                newYesPriceE6,
                newNoPriceE6,
                nonce,
                maxSpendCollateral,
                minDeviationImprovementBps
            );
        } else if (actionTypeHash == HASHED_PRE_CLOSE_LMSR_SELL) {
            (
                uint256 marketId,
                uint8 outcomeIndex,
                uint256 sharesDelta,
                uint256 refundDelta,
                uint256 newYesPriceE6,
                uint256 newNoPriceE6,
                uint64 nonce
            ) = abi.decode(
                    payload,
                    (uint256, uint8, uint256, uint256, uint256, uint256, uint64)
                );
            _preCloseLmsrSell(
                marketId,
                outcomeIndex,
                sharesDelta,
                refundDelta,
                newYesPriceE6,
                newNoPriceE6,
                nonce
            );
        } else if (actionTypeHash == hashed_AddLiquidityToFactory) {
            _addLiquidityToFactory();
        } else if (actionTypeHash == mintCollateralToActionHash) {
            (address receiver, uint256 amount) = abi.decode(
                payload,
                (address, uint256)
            );
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
    function getMarketFactoryCollateralBalance()
        external
        view
        returns (uint256)
    {
        return collateral.balanceOf(address(this));
    }
    /// @dev Executes a factory-routed LMSR arbitrage buy using CRE-provided trade quote data.
    /// The factory is the trade account and is intentionally exempt from maxOutBps limits in market checks.
    function _arbitrateUnsafeMarket(
        uint256 marketId,
        uint8 outcomeIndex,
        uint256 sharesDelta,
        uint256 costDelta,
        uint256 newYesPriceE6,
        uint256 newNoPriceE6,
        uint64 nonce,
        uint256 maxSpendCollateral,
        uint256 minDeviationImprovementBps
    ) internal {
        if (maxSpendCollateral == 0 || sharesDelta == 0 || costDelta == 0)
            revert MarketFactory__ArbZeroAmount();
        if (costDelta > maxSpendCollateral)
            revert MarketFactory__ArbCostExceedsMax();

        UnsafeArbContext memory ctx;
        ctx.marketAddress = marketById[marketId];
        if (ctx.marketAddress == address(0))
            revert MarketFactory__MarketNotFound();
        ctx.market = PredictionMarket(ctx.marketAddress);

        PredictionMarketBase.DeviationBand band;
        bool allowYesForNo;
        bool allowNoForYes;
        (
            band,
            ctx.deviationBefore,
            ctx.effectiveFeeBps,
            ctx.maxOutBps,
            allowYesForNo,
            allowNoForYes
        ) = ctx.market.getDeviationStatus();

        if (uint8(band) != 2 && uint8(band) != 3)
            revert MarketFactory__ArbNotUnsafe();
        if (!allowYesForNo && !allowNoForYes)
            revert MarketFactory__ArbNoDirection();

        // Buy NO (outcomeIndex=1) means YES->NO corrective direction.
        // Buy YES (outcomeIndex=0) means NO->YES corrective direction.
        bool yesForNo = outcomeIndex == 1;
        if ((yesForNo && !allowYesForNo) || (!yesForNo && !allowNoForYes))
            revert MarketFactory__ArbNoDirection();

        _ensureAllowance(collateral, ctx.marketAddress, costDelta);
        ctx.market.executeBuy(
            address(this),
            outcomeIndex,
            sharesDelta,
            costDelta,
            newYesPriceE6,
            newNoPriceE6,
            nonce
        );

        uint256 deviationAfter;
        (, deviationAfter, , , , ) = ctx.market.getDeviationStatus();
        if (
            deviationAfter >= ctx.deviationBefore ||
            ctx.deviationBefore - deviationAfter < minDeviationImprovementBps
        ) {
            revert MarketFactory__ArbImprovementTooLow();
        }

        emit UnsafeArbitrageExecuted(
            ctx.marketAddress,
            yesForNo,
            costDelta,
            ctx.deviationBefore,
            deviationAfter
        );
    }

    /// @dev Executes a factory-routed LMSR sell close to market close to unwind factory-held outcome shares.
    /// Expects a CRE-computed quote payload using the same schema/semantics as market `LMSRSell`.
    function _preCloseLmsrSell(
        uint256 marketId,
        uint8 outcomeIndex,
        uint256 sharesDelta,
        uint256 refundDelta,
        uint256 newYesPriceE6,
        uint256 newNoPriceE6,
        uint64 nonce
    ) internal {
        if (sharesDelta == 0 || refundDelta == 0) {
            revert MarketFactory__PreCloseSellInvalidAmount();
        }

        address marketAddress = marketById[marketId];
        if (marketAddress == address(0)) {
            revert MarketFactory__MarketNotFound();
        }

        PredictionMarket market = PredictionMarket(marketAddress);
        uint256 marketCloseTime = market.closeTime();
        if (
            block.timestamp >= marketCloseTime ||
            block.timestamp + PRE_CLOSE_SELL_WINDOW < marketCloseTime
        ) {
            revert MarketFactory__PreCloseSellWindowNotOpen();
        }

        address token = outcomeIndex == 0
            ? address(market.yesToken())
            : address(market.noToken());
        if (IERC20(token).balanceOf(address(this)) < sharesDelta) {
            revert MarketFactory__PreCloseSellInsufficientShares();
        }

        market.executeSell(
            address(this),
            outcomeIndex,
            sharesDelta,
            refundDelta,
            newYesPriceE6,
            newNoPriceE6,
            nonce
        );
    }



    /// @dev Makes sure allowance is sufficient without resetting every call.
    function _ensureAllowance(
        IERC20 token,
        address spender,
        uint256 amount
    ) internal {
        uint256 allowance = token.allowance(address(this), spender);
        if (allowance < amount) {
            token.safeIncreaseAllowance(spender, amount - allowance);
        }
    }

    /// @notice Withdraws both subsidy collateral and protocol fees from one market.
    /// @dev In LMSR mode, there are no LP shares. The subsidy remains locked until resolution.
    /// After resolution, any remaining collateral can be withdrawn.
    function withdrawMarketFactoryCollateralAndFee(
        uint256 _marketId
    ) external onlyOwner {
        _withdrawEventFeeWhenResolved(_marketId);
    }

    /// @dev In LMSR mode, there are no LP shares to withdraw.
    /// Subsidy collateral is managed by the market directly.
    function _withdrawCollateralFromEvents(uint256 _marketId) internal {
        // No-op in LMSR mode — no LP shares exist.
        // Factory subsidy remains in market until resolved.
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
    function processPendingWithdrawals(
        uint256 maxItems
    )
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
    function _processPendingWithdrawals(
        uint256 maxItems
    )
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

            if (
                uint256(PredictionMarket(marketAddress).state()) !=
                uint256(State.Resolved)
            ) {
                _enqueueWithdraw(marketId);
                emit WithdrawRequeued(marketId);
                emit WithdrawSkippedNotResolved(marketId);
                continue;
            }

            // In LMSR mode, there are no LP shares. Skip the check.
            // Factory should only withdraw protocol fees.
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
    function getPendingWithdrawAt(
        uint256 indexFromHead
    ) external view returns (uint256) {
        uint256 idx = pendingWithdrawHead + indexFromHead;
        if (idx >= pendingWithdrawQueue.length)
            revert MarketFactory__MarketNotFound();
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
    /// @dev These are markets removed from the normal active list because a human or off-chain
    /// adjudication step is still required before final settlement.
    function getManualReviewEventList()
        external
        view
        returns (address[] memory)
    {
        return manualReviewMarkets;
    }
}
