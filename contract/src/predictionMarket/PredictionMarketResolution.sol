// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Resolution, MarketConstants, MarketEvents, MarketErrors, State} from "../libraries/MarketTypes.sol";
import {FeeLib} from "../libraries/FeeLib.sol";
import {PredictionMarketLiquidity} from "./PredictionMarketLiquidity.sol";

abstract contract PredictionMarketResolution is PredictionMarketLiquidity {
    using SafeERC20 for IERC20;

    function resolve(Resolution _outcome, string memory proofUrl) external onlyOwner {
        _resolve(_outcome, proofUrl);
    }

    function _resolve(Resolution _outcome, string memory proofUrl) internal {
        _revertIfLocalResolutionDisabled();
        _updateState();

        if (block.timestamp < resolutionTime) {
            revert MarketErrors.PredictionMarket__ResolveTimeNotReached();
        }

        if (state != State.Closed) {
            revert MarketErrors.PredictionMarket__MarketNotClosed();
        }

        if (_outcome == Resolution.Inconclusive) {
            manualReviewNeeded = true;
            state = State.Review;
            resolution = Resolution.Inconclusive;
            marketFactory.removeResolvedMarket(address(this));

            emit MarketEvents.IsUnderManualReview(_outcome);
            return;
        }

        if (bytes(proofUrl).length == 0) {
            revert MarketErrors.PredictionMarket__ProofUrlCantBeEmpty();
        }

        _finalizeResolution(_outcome, proofUrl, true, true);
    }

    function redeem(uint256 amount) external nonReentrant whenNotPaused zeroAmountCheck(amount) {
        if (state != State.Resolved) {
            revert MarketErrors.PredictionMarket__NotResolved();
        }

        (uint256 netAmount, uint256 fee) =
            FeeLib.deductFee(amount, MarketConstants.REDEEM_COMPLETE_SETS_FEE_BPS, MarketConstants.FEE_PRECISION_BPS);

        protocolCollateralFees += fee;

        if (resolution == Resolution.Yes) {
            yesToken.burn(msg.sender, amount);
            i_collateral.safeTransfer(msg.sender, netAmount);
        } else if (resolution == Resolution.No) {
            noToken.burn(msg.sender, amount);
            i_collateral.safeTransfer(msg.sender, netAmount);
        }

        emit MarketEvents.Redeemed(msg.sender, amount);
    }

    function manualResolveMarket(Resolution _outcome, string calldata proofUrl) external onlyOwner {
        _revertIfLocalResolutionDisabled();
        if (bytes(proofUrl).length == 0) {
            revert MarketErrors.PredictionMarket__ProofUrlCantBeEmpty();
        }

        if (state != State.Review) {
            revert MarketErrors.PredictionMarket__MarketNotInReview();
        }

        if (!manualReviewNeeded) {
            revert MarketErrors.PredictionMarket__ManualReviewNeeded();
        }

        if (_outcome == Resolution.Inconclusive) {
            revert MarketErrors.PredictionMarket__InvalidFinalOutcome();
        }

        _finalizeResolution(_outcome, proofUrl, false, true);
    }

    function setCrossChainController(address controller) external onlyOwner {
        if (controller == address(0)) {
            revert MarketErrors.PredictionMarket__CrossChainControllerCantBeZero();
        }
        crossChainController = controller;
        emit MarketEvents.CrossChainControllerSet(controller);
    }

    function setMarketId(uint256 _marketId) external {
        if (msg.sender != owner() && msg.sender != crossChainController) {
            revert MarketErrors.PredictionMarket__NotOwner_Or_CrossChainController();
        }
        if (_marketId == 0) revert PredictionMarket__InvalidMarketId();
        if (marketId != 0) revert PredictionMarket__MarketIdAlreadySet();
        marketId = _marketId;
        emit MarketEvents.MarketIdSet(_marketId);
    }

    function resolveFromHub(Resolution _outcome, string calldata proofUrl) external onlyCrossChainController {
        if (bytes(proofUrl).length == 0) {
            revert MarketErrors.PredictionMarket__ProofUrlCantBeEmpty();
        }
        if (_outcome == Resolution.Unset || _outcome == Resolution.Inconclusive) {
            revert MarketErrors.PredictionMarket__InvalidFinalOutcome();
        }
        if (state == State.Resolved) {
            revert MarketErrors.PredictionMarket__AlreadyResolved();
        }

        _finalizeResolution(_outcome, proofUrl, true, false);
    }

    function syncCanonicalPriceFromHub(uint256 yesPriceE6, uint256 noPriceE6, uint256 validUntil, uint64 nonce)
        external
        onlyCrossChainController
    {
        if (yesPriceE6 + noPriceE6 != MarketConstants.PRICE_PRECISION) {
            revert PredictionMarket__InvalidCanonicalPrice();
        }
        if (nonce <= canonicalPriceNonce) {
            revert PredictionMarket__StaleSyncMessage();
        }

        canonicalYesPriceE6 = yesPriceE6;
        canonicalNoPriceE6 = noPriceE6;
        canonicalPriceValidUntil = validUntil;
        canonicalPriceNonce = nonce;

        emit MarketEvents.SyncCanonicalPrice(yesPriceE6, noPriceE6, validUntil, nonce);
    }

    function _processReport(bytes calldata report) internal override {
        (string memory actionType, bytes memory payload) = abi.decode(report, (string, bytes));
        bytes32 actionTypeHash = keccak256(abi.encodePacked(actionType));

        if (actionTypeHash != HASHED_RESOLVE_MARKET) revert MarketErrors.PredictionMarket__InvalidReport();
        (Resolution _outcome, string memory _proofUrl) = abi.decode(payload, (Resolution, string));

        _resolve(_outcome, _proofUrl);
    }

    function checkResolutionTime() external view returns (bool resolveReady) {
        resolveReady = block.timestamp > closeTime && block.timestamp >= resolutionTime;
    }
}
