// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Resolution, MarketConstants, State} from "../libraries/MarketTypes.sol";
import {AMMLib} from "../libraries/AMMLib.sol";
import {PredictionMarket} from "../predictionMarket/PredictionMarket.sol";
import {MarketFactoryCcip} from "./MarketFactoryCcip.sol";

abstract contract MarketFactoryOperations is MarketFactoryCcip {
    using SafeERC20 for IERC20;

    function _processReport(bytes calldata report) internal override {
        (string memory actionType, bytes memory payload) = abi.decode(report, (string, bytes));
        bytes32 actionTypeHash = keccak256(abi.encode(actionType));
        bytes32 syncSpokeActionHash = hashed_SyncSpokeCanonicalPrice;
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

    function getMarketFactoryCollateralBalance() external view returns (uint256) {
        return collateral.balanceOf(address(this));
    }

    function arbitrateUnsafeMarket(uint256 marketId, uint256 maxSpendCollateral, uint256 minDeviationImprovementBps)
        external
        onlyOwner
    {
        return _arbitrateUnsafeMarket(marketId, maxSpendCollateral, minDeviationImprovementBps);
    }

    function _arbitrateUnsafeMarket(uint256 marketId, uint256 maxSpendCollateral, uint256 minDeviationImprovementBps)
        internal
    {
        UnsafeArbContext memory ctx;
        ctx.marketAddress = marketById[marketId];
        if (ctx.marketAddress == address(0)) revert MarketFactory__MarketNotFound();
        if (maxSpendCollateral == 0) revert MarketFactory__ArbZeroAmount();

        ctx.market = PredictionMarket(ctx.marketAddress);

        PredictionMarket.DeviationBand band;
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

    function _executeUnsafeArbSwap(PredictionMarket m, address marketAddress, bool yesForNo, uint256 swapIn) internal {
        if (yesForNo) {
            _ensureAllowance(IERC20(address(m.yesToken())), marketAddress, swapIn);
            m.swapYesForNo(swapIn, 0);
        } else {
            _ensureAllowance(IERC20(address(m.noToken())), marketAddress, swapIn);
            m.swapNoForYes(swapIn, 0);
        }
    }

    function _netOutcomeFromCollateral(uint256 collateralAmount) internal pure returns (uint256) {
        uint256 fee = (collateralAmount * MarketConstants.MINT_COMPLETE_SETS_FEE_BPS) / MarketConstants.FEE_PRECISION_BPS;
        return collateralAmount - fee;
    }

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

    function _ensureAllowance(IERC20 token, address spender, uint256 amount) internal {
        uint256 allowance = token.allowance(address(this), spender);
        if (allowance < amount) {
            token.safeIncreaseAllowance(spender, amount - allowance);
        }
    }

    function withdrawMarketFactoryCollateralAndFee(uint256 _marketId) external onlyOwner {
        _withdrawCollateralFromEvents(_marketId);
        _withdrawEventFeeWhenResolved(_marketId);
    }

    function _withdrawCollateralFromEvents(uint256 _marketId) internal {
        address marketAddress = marketById[_marketId];
        if (marketAddress == address(0)) revert MarketFactory__MarketNotFound();

        uint256 share = PredictionMarket(marketAddress).lpShares(address(this));
        PredictionMarket(marketAddress).withdrawLiquidityCollateral(share);
    }

    function _withdrawEventFeeWhenResolved(uint256 _marketId) internal {
        address marketAddress = marketById[_marketId];
        if (marketAddress == address(0)) revert MarketFactory__MarketNotFound();

        PredictionMarket(marketAddress).withdrawProtocolFees();
    }

    function enqueueWithdraw(uint256 marketId) external onlyOwner {
        _enqueueWithdraw(marketId);
    }

    function processPendingWithdrawals(uint256 maxItems)
        external
        onlyOwner
        returns (uint256 attempted, uint256 succeeded, uint256 remaining)
    {
        return _processPendingWithdrawals(maxItems);
    }

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

    function getPendingWithdrawCount() external view returns (uint256) {
        return pendingWithdrawQueue.length - pendingWithdrawHead;
    }

    function getPendingWithdrawAt(uint256 indexFromHead) external view returns (uint256) {
        uint256 idx = pendingWithdrawHead + indexFromHead;
        if (idx >= pendingWithdrawQueue.length) revert MarketFactory__MarketNotFound();
        return pendingWithdrawQueue[idx];
    }

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

    function getActiveEventList() external view returns (address[] memory) {
        return activeMarkets;
    }
}
