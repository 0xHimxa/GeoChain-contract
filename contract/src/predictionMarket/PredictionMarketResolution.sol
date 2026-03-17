// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {
    SafeERC20
} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {
    Resolution,
    MarketConstants,
    MarketEvents,
    MarketErrors,
    State
} from "../libraries/MarketTypes.sol";
import {FeeLib} from "../libraries/FeeLib.sol";
import {PredictionMarketLiquidity} from "./PredictionMarketLiquidity.sol";

/// @title PredictionMarketResolution
/// @notice Resolution and post-resolution redemption flows.
abstract contract PredictionMarketResolution is PredictionMarketLiquidity {
    using SafeERC20 for IERC20;

    /// @notice Owner-triggered local resolution entrypoint.
    /// @dev Uses `_resolve`, which enforces timestamp/state checks and handles review/final paths.
    function resolve(
        Resolution _outcome,
        string memory proofUrl
    ) external onlyOwner {
        _resolve(_outcome, proofUrl);
    }

    /// @dev Core local resolution logic shared by direct owner calls and report-driven calls.
    /// Behavior:
    /// - rejects local resolution on spoke markets controlled by hub,
    /// - requires `resolutionTime` reached and state already `Closed`,
    /// - if outcome is `Inconclusive`, moves market to manual `Review` state,
    /// - otherwise stores a provisional outcome and opens the dispute window.
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
            marketFactory.markMarketForManualReview(address(this));

            emit MarketEvents.IsUnderManualReview(_outcome);
            return;
        }
        if (_outcome == Resolution.Unset) {
            revert MarketErrors.PredictionMarket__InvalidFinalOutcome();
        }

        if (bytes(proofUrl).length == 0) {
            revert MarketErrors.PredictionMarket__ProofUrlCannotBeEmpty();
        }

        proposedResolution = _outcome;
        proposedProofUrl = proofUrl;
        disputeDeadline = block.timestamp + disputeWindow;
        resolutionDisputed = false;
        state = State.Review;

        emit MarketEvents.ResolutionProposed(
            _outcome,
            disputeDeadline,
            proofUrl
        );
    }

    /// @notice Updates dispute-window duration used for new resolution proposals.
    function setDisputeWindow(uint256 newDisputeWindow) external onlyOwner {
        if (newDisputeWindow == 0) {
            revert MarketErrors.PredictionMarket__DisputeWindowMustBeGreaterThanZero();
        }
        disputeWindow = newDisputeWindow;
    }

    /// @notice Disputes an active provisional resolution while challenge period is open.
    /// @dev Each account can submit at most one dispute for the market.
    function disputeProposedResolution(address _disputer,Resolution proposedOutcome) external onlyRouterVault {
        if (state != State.Review || proposedResolution == Resolution.Unset) {
            revert MarketErrors.PredictionMarket__NoPendingResolution();
        }
        if (hasSubmittedDispute[_disputer]) {
            revert MarketErrors.PredictionMarket__DisputeAlreadySubmittedByUser();
        }
        if (block.timestamp > disputeDeadline) {
            revert MarketErrors.PredictionMarket__DisputeWindowClosed();
        }
        uint256 outcomeValue = uint256(proposedOutcome);
        if (
            outcomeValue == uint256(Resolution.Unset) ||
            outcomeValue > uint256(Resolution.Inconclusive)
        ) {
            revert MarketErrors.PredictionMarket__InvalidFinalOutcome();
        }

        hasSubmittedDispute[_disputer] = true;
        disputeSubmissions.push(
            DisputeSubmission({
                disputer: _disputer,
                proposedOutcome: proposedOutcome,
                submittedAt: block.timestamp
            })
        );
        if (!uniqueDisputedOutcomeSeen[uint8(proposedOutcome)]) {
            uniqueDisputedOutcomeSeen[uint8(proposedOutcome)] = true;
            uniqueDisputedOutcomes[
                uniqueDisputedOutcomesCount
            ] = proposedOutcome;
            uniqueDisputedOutcomesCount++;
        }
        resolutionDisputed = true;
        emit MarketEvents.ResolutionDisputed(_disputer, proposedOutcome);
    }

    /// @notice Finalizes a provisional resolution after dispute window if no dispute was raised.
    /// @dev Direct call is owner-only. CRE handler path is allowed through `_processReport`.
    function finalizeResolutionAfterDisputeWindow() external onlyOwner {
        _finalizeResolutionAfterDisputeWindow();
    }

    /// @dev Completes the happy-path resolution flow after the challenge window expires.
    /// This only succeeds when:
    /// - the market is in `Review`,
    /// - a proposal exists,
    /// - nobody disputed it, and
    /// - manual review was not requested.
    function _finalizeResolutionAfterDisputeWindow() internal {
        if (state != State.Review || proposedResolution == Resolution.Unset) {
            revert MarketErrors.PredictionMarket__NoPendingResolution();
        }
        if (manualReviewNeeded || resolutionDisputed) {
            revert MarketErrors.PredictionMarket__ManualReviewNeeded();
        }
        if (block.timestamp <= disputeDeadline) {
            revert MarketErrors.PredictionMarket__DisputeWindowNotPassed();
        }

        _finalizeResolution(proposedResolution, proposedProofUrl, true, true);
    }

    /// @notice Owner adjudicates disputed provisional resolution.
    /// @dev If adjudicated outcome is Yes/No, market finalizes immediately.
    /// If adjudicated outcome is Inconclusive, market remains in review with manual review enabled.
    function adjudicateDisputedResolution(
        Resolution adjudicatedOutcome,
        string calldata proofUrl
    ) external onlyOwner {
        _adjudicateDisputedResolution(adjudicatedOutcome, proofUrl);
    }

    /// @dev Resolves a disputed proposal after off-chain review.
    /// A Yes/No adjudication finalizes immediately; an inconclusive adjudication keeps the market
    /// in manual review so it cannot be forced into a binary outcome without sufficient evidence.
    function _adjudicateDisputedResolution(
        Resolution adjudicatedOutcome,
        string memory proofUrl
    ) internal {
        _revertIfLocalResolutionDisabled();

        if (
            state != State.Review ||
            proposedResolution == Resolution.Unset ||
            !resolutionDisputed
        ) {
            revert MarketErrors.PredictionMarket__NoPendingResolution();
        }

        if (adjudicatedOutcome == Resolution.Unset) {
            revert MarketErrors.PredictionMarket__InvalidFinalOutcome();
        }

        if (adjudicatedOutcome == Resolution.Inconclusive) {
            manualReviewNeeded = true;
            resolution = Resolution.Inconclusive;
            marketFactory.removeResolvedMarket(address(this));
            marketFactory.markMarketForManualReview(address(this));

            emit MarketEvents.IsUnderManualReview(adjudicatedOutcome);
            return;
        }

        if (bytes(proofUrl).length == 0) {
            revert MarketErrors.PredictionMarket__ProofUrlCannotBeEmpty();
        }

        _finalizeResolution(adjudicatedOutcome, proofUrl, true, true);
    }

    /// @notice Redeems winning outcome token after market resolution.
    /// @dev Applies redeem fee, burns only the winning side token, and transfers net collateral.
    /// If market is not resolved, redemption is blocked.
    function redeem(
        uint256 amount
    ) external nonReentrant whenNotPaused zeroAmountCheck(amount) {
        if (state != State.Resolved) {
            revert MarketErrors.PredictionMarket__NotResolved();
        }

        (uint256 netAmount, uint256 fee) = FeeLib.deductFee(
            amount,
            MarketConstants.REDEEM_COMPLETE_SETS_FEE_BPS,
            MarketConstants.FEE_PRECISION_BPS
        );

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

    /// @notice Manual finalization path for markets currently in review.
    /// @dev Used after off-chain/manual adjudication when initial resolution was inconclusive.
    /// Requires non-empty proof URL and a final Yes/No outcome.
    function manualResolveMarket(
        Resolution _outcome,
        string calldata proofUrl
    ) external onlyOwner {
        _revertIfLocalResolutionDisabled();
        if (bytes(proofUrl).length == 0) {
            revert MarketErrors.PredictionMarket__ProofUrlCannotBeEmpty();
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

        bool removeFromFactory = proposedResolution != Resolution.Unset;
        _finalizeResolution(_outcome, proofUrl, removeFromFactory, true);
    }

    /// @notice Sets cross-chain controller authorized for hub sync actions.
    /// @dev Controller can call `resolveFromHub` and `syncCanonicalPriceFromHub`.
    function setCrossChainController(address controller) external onlyOwner {
        if (controller == address(0)) {
            revert MarketErrors.PredictionMarket__CrossChainControllerCantBeZero();
        }
        crossChainController = controller;
        emit MarketEvents.CrossChainControllerSet(controller);
    }

    /// @notice Sets market id exactly once.
    /// @dev Callable by owner or cross-chain controller; rejects zero id and re-assignment.
    function setMarketId(uint256 _marketId) external {
        if (msg.sender != owner() && msg.sender != crossChainController) {
            revert MarketErrors.PredictionMarket__NotOwner_Or_CrossChainController();
        }
        if (_marketId == 0) revert PredictionMarket__InvalidMarketId();
        if (marketId != 0) revert PredictionMarket__MarketIdAlreadySet();
        marketId = _marketId;
        emit MarketEvents.MarketIdSet(_marketId);
    }

    /// @notice Cross-chain resolution callback used by spoke markets.
    /// @dev Skips local timing/state checks because hub has already finalized the outcome.
    /// Still validates proof URL, outcome finality, and non-resolved precondition.
    function resolveFromHub(
        Resolution _outcome,
        string calldata proofUrl
    ) external onlyCrossChainController {
        if (bytes(proofUrl).length == 0) {
            revert MarketErrors.PredictionMarket__ProofUrlCannotBeEmpty();
        }
        if (
            _outcome == Resolution.Unset || _outcome == Resolution.Inconclusive
        ) {
            revert MarketErrors.PredictionMarket__InvalidFinalOutcome();
        }
        if (
            state == State.Resolved ||
            (state == State.Review && proposedResolution != Resolution.Unset)
        ) {
            revert MarketErrors.PredictionMarket__AlreadyResolved();
        }

        _finalizeResolution(_outcome, proofUrl, true, false);
    }

    /// @notice Applies canonical price update from hub with strict nonce ordering.
    /// @dev Also enforces normalization invariant:
    /// `yesPriceE6 + noPriceE6 == PRICE_PRECISION`.
    function syncCanonicalPriceFromHub(
        uint256 yesPriceE6,
        uint256 noPriceE6,
        uint256 validUntil,
        uint64 nonce
    ) external onlyCrossChainController {
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

        emit MarketEvents.SyncCanonicalPrice(
            yesPriceE6,
            noPriceE6,
            validUntil,
            nonce
        );
    }

    /// @dev Receiver-side report dispatcher for resolution and LMSR trade automation.
    /// Supported report actions are:
    /// - `ResolveMarket`
    /// - `FinalizeResolutionAfterDisputeWindow`
    /// - `AdjudicateDisputedResolution`
    /// - `LMSRBuy`  — CRE-computed buy trade
    /// - `LMSRSell` — CRE-computed sell trade
    /// Any other action string is rejected so only explicit flows can execute.
    function _processReport(bytes calldata report) internal override {
        (string memory actionType, bytes memory payload) = abi.decode(
            report,
            (string, bytes)
        );
        bytes32 actionTypeHash = keccak256(abi.encodePacked(actionType));

        if (actionTypeHash == HASHED_RESOLVE_MARKET) {
            (Resolution _outcome, string memory _proofUrl) = abi.decode(
                payload,
                (Resolution, string)
            );
            _resolve(_outcome, _proofUrl);
            return;
        }

        if (actionTypeHash == HASHED_FINALIZE_RESOLUTION_AFTER_DISPUTE_WINDOW) {
            _finalizeResolutionAfterDisputeWindow();
            return;
        }

        if (actionTypeHash == HASHED_ADJUDICATE_DISPUTED_RESOLUTION) {
            (Resolution adjudicatedOutcome, string memory proofUrl) = abi
                .decode(payload, (Resolution, string));
            _adjudicateDisputedResolution(adjudicatedOutcome, proofUrl);
            return;
        }

        // ── LMSR Trade Reports (CRE-computed) ────────────────────────
        if (actionTypeHash == HASHED_LMSR_BUY) {
            (
                address trader,
                uint8 outcomeIndex,
                uint256 sharesDelta,
                uint256 costDelta,
                uint256 newYesPriceE6,
                uint256 newNoPriceE6,
                uint64 nonce
            ) = abi.decode(
                    payload,
                    (address, uint8, uint256, uint256, uint256, uint256, uint64)
                );
            _executeLMSRBuy(
                trader,
                outcomeIndex,
                sharesDelta,
                costDelta,
                newYesPriceE6,
                newNoPriceE6,
                nonce
            );
            return;
        }

        if (actionTypeHash == HASHED_LMSR_SELL) {
            (
                address trader,
                uint8 outcomeIndex,
                uint256 sharesDelta,
                uint256 refundDelta,
                uint256 newYesPriceE6,
                uint256 newNoPriceE6,
                uint64 nonce
            ) = abi.decode(
                    payload,
                    (address, uint8, uint256, uint256, uint256, uint256, uint64)
                );
            _executeLMSRSell(
                trader,
                outcomeIndex,
                sharesDelta,
                refundDelta,
                newYesPriceE6,
                newNoPriceE6,
                nonce
            );
            return;
        }

        revert MarketErrors.PredictionMarket__InvalidReport();
    }

    /// @notice Convenience helper indicating whether this market is time-eligible for resolution.
    /// @dev Returns true only when close-time and resolution-time windows have both passed.
    function checkResolutionTime() external view returns (bool resolveReady) {
        resolveReady =
            block.timestamp > closeTime &&
            block.timestamp >= resolutionTime;
    }

    /// @notice Returns total number of stored dispute submissions.
    function getDisputeSubmissionsCount() external view returns (uint256) {
        return disputeSubmissions.length;
    }
    /// @notice Returns dispute-resolution snapshot used by automation in one call.
    /// @dev Materializes the compact internal fixed-size outcome set into a dynamic array so
    /// CRE handlers can consume all dispute metadata without making multiple contract calls.
    function getDisputeResolutionSnapshot()
        external
        view
        returns (
            State marketState,
            Resolution currentProposedResolution,
            bool isResolutionDisputed,
            uint256 currentDisputeDeadline,
            uint256 currentResolutionTime,
            string memory question,
            Resolution[] memory disputedUniqueOutcomes
        )
    {
        Resolution[] memory outcomes = new Resolution[](
            uniqueDisputedOutcomesCount
        );
        for (uint256 i = 0; i < uniqueDisputedOutcomesCount; i++) {
            outcomes[i] = uniqueDisputedOutcomes[i];
        }

        marketState = state;
        currentProposedResolution = proposedResolution;
        isResolutionDisputed = resolutionDisputed;
        currentDisputeDeadline = disputeDeadline;
        currentResolutionTime = resolutionTime;
        question = s_question;
        disputedUniqueOutcomes = outcomes;
    }
}
