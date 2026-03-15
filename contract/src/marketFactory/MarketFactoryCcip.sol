// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {State, Resolution} from "../libraries/MarketTypes.sol";
import {Client} from "../ccip/Client.sol";
import {IRouterClient} from "../ccip/IRouterClient.sol";
import {IAny2EVMMessageReceiver} from "../ccip/IAny2EVMMessageReceiver.sol";
import {PredictionMarket} from "../predictionMarket/PredictionMarket.sol";
import {MarketFactoryBase} from "./MarketFactoryBase.sol";

/// @title MarketFactoryCcip
/// @notice CCIP coordination layer for hub/spoke market synchronization.
/// @dev This contract is responsible for:
/// 1) maintaining trusted remote configuration per chain selector,
/// 2) sending canonical price and resolution messages from hub to spokes,
/// 3) validating and consuming inbound CCIP messages on spokes/hub,
/// 4) enforcing nonce/replay guards so stale or duplicate messages cannot mutate state.
abstract contract MarketFactoryCcip is MarketFactoryBase {
    using SafeERC20 for IERC20;

    /// @notice Configures router + fee token and selects whether this factory acts as hub.
    /// @dev Hub factories are allowed to broadcast prices/resolutions.
    /// Spoke factories are expected to only receive/sync those values.
    function setCcipConfig(address _ccipRouter, address _ccipFeeToken, bool _isHubFactory) external onlyOwner {
        if (_ccipRouter == address(0) || _ccipFeeToken == address(0)) revert MarketFactory__ZeroAddress();
        ccipRouter = _ccipRouter;
        ccipFeeToken = _ccipFeeToken;
        isHubFactory = _isHubFactory;
        emit CcipConfigUpdated(_ccipRouter, _ccipFeeToken, _isHubFactory);
    }

    /// @notice Adds/removes a chain selector from the supported selector allowlist.
    /// @dev A selector must be supported before `setTrustedRemote` can bind a remote address to it.
    function setSupportedChainSelector(uint64 chainSelector, bool isSupported) external onlyOwner {
        if (chainSelector == 0) revert MarketFactory__ChainSelectorCantBeZero();
        s_supportedChainSelector[chainSelector] = isSupported;
        emit ChainSelectorSupportUpdated(chainSelector, isSupported);
    }

    /// @notice Returns whether a selector is currently allowed for remote config.
    function isSupportedChainSelector(uint64 chainSelector) external view returns (bool) {
        return s_supportedChainSelector[chainSelector];
    }

    /// @notice Binds a selector to its trusted remote factory address.
    /// @dev This is the core trust anchor used by `ccipReceive` sender verification.
    /// When first added, selector is also inserted into `s_spokeSelectors` so hub broadcasts
    /// will include that chain in fan-out loops.
    function setTrustedRemote(uint64 chainSelector, address remoteFactory) external onlyOwner {
        if (remoteFactory == address(0)) revert MarketFactory__ZeroAddress();
        if (chainSelector == 0) revert MarketFactory__ChainSelectorCantBeZero();

        if (!s_supportedChainSelector[chainSelector]) {
            revert MarketFactory__ChainSelectorNotSupported();
        }

        trustedRemoteBySelector[chainSelector] = abi.encode(remoteFactory);
        if (!s_spokeSelectorExists[chainSelector]) {
            s_spokeSelectorExists[chainSelector] = true;
            s_spokeSelectors.push(chainSelector);
        }

        emit TrustedRemoteUpdated(chainSelector, remoteFactory);
    }

    /// @notice Removes trusted remote configuration for a selector.
    /// @dev Also removes selector from `s_spokeSelectors` (swap-and-pop) so future hub broadcasts
    /// stop attempting delivery to that chain.
    function removeTrustedRemote(uint64 chainSelector) external onlyOwner {
        if (chainSelector == 0) revert MarketFactory__ChainSelectorCantBeZero();
        if (!s_supportedChainSelector[chainSelector]) {
            revert MarketFactory__ChainSelectorNotSupported();
        }

        delete trustedRemoteBySelector[chainSelector];

        if (s_spokeSelectorExists[chainSelector]) {
            s_spokeSelectorExists[chainSelector] = false;
            uint64[] memory selectors = s_spokeSelectors;
            uint256 length = selectors.length;

            for (uint256 i = 0; i < length; i++) {
                if (selectors[i] == chainSelector) {
                    s_spokeSelectors[i] = s_spokeSelectors[length - 1];
                    s_spokeSelectors.pop();
                    break;
                }
            }
        }

        emit TrustedRemoteRemoved(chainSelector);
    }

    /// @notice Returns selectors currently in broadcast fan-out set.
    /// @dev This is derived from trusted remotes, not from the broader supported-selector allowlist.
    function getSpokeSelectors() external view returns (uint64[] memory selectors) {
        return s_spokeSelectors;
    }

    /// @notice Owner-triggered canonical price broadcast from hub to all configured spokes.
    /// @dev Wraps `_broadcastCanonicalPrice`, which creates one payload with a fresh nonce and
    /// sends it to every selector in `s_spokeSelectors`.
    function broadcastCanonicalPrice(uint256 marketId, uint256 yesPriceE6, uint256 noPriceE6, uint256 validUntil)
        external
        onlyOwner
    {
        _broadcastCanonicalPrice(marketId, yesPriceE6, noPriceE6, validUntil);
    }

    /// @dev Internal hub fan-out for canonical price updates.
    /// Validates hub mode, market existence, and CCIP config before sending.
    /// Each destination receives identical payload + shared nonce so consumers can enforce ordering.
    function _broadcastCanonicalPrice(uint256 marketId, uint256 yesPriceE6, uint256 noPriceE6, uint256 validUntil)
        internal
    {
        if (!isHubFactory) revert MarketFactory__NotHubFactory();
        if (marketById[marketId] == address(0)) revert MarketFactory__MarketNotFound();
        if (ccipRouter == address(0)) revert MarketFactory__CcipRouterNotSet();
        if (ccipFeeToken == address(0)) revert MarketFactory__CcipFeeTokenNotSet();

        CanonicalPriceSync memory payload = CanonicalPriceSync({
            marketId: marketId,
            yesPriceE6: yesPriceE6,
            noPriceE6: noPriceE6,
            validUntil: validUntil,
            nonce: ++ccipNonce
        });
        bytes memory encodedPayload = abi.encode(payload);

        uint256 length = s_spokeSelectors.length;
        for (uint256 i = 0; i < length; i++) {
            bytes32 messageId = _sendCcipMessage(s_spokeSelectors[i], uint8(SyncMessageType.Price), encodedPayload);
            emit CcipMessageSent(messageId, s_spokeSelectors[i], uint8(SyncMessageType.Price));
        }
    }

    /// @notice Owner-triggered market resolution broadcast from hub to all spokes.
    /// @dev Only final outcomes (Yes/No) are allowed; non-final outcomes are rejected.
    function broadcastResolution(uint256 marketId, Resolution outcome, string memory proofUrl) external onlyOwner {
        _broadcastResolution(marketId, outcome, proofUrl);
    }

    /// @notice Callback used by a registered hub market immediately after local finalization.
    /// @dev Enqueues market for withdrawal processing and propagates final resolution cross-chain.
    function onHubMarketResolved(Resolution outcome, string calldata proofUrl) external {
        uint256 marketId = marketIdByAddress[msg.sender];
        if (marketId == 0 || marketById[marketId] != msg.sender) revert MarketFactory__OnlyRegisteredMarket();
        _enqueueWithdraw(marketId);
        _broadcastResolution(marketId, outcome, proofUrl);
    }

    /// @dev Internal hub fan-out for resolution updates.
    /// Uses monotonic `ccipNonce`, same payload for all spokes, and emits send events per chain.
    function _broadcastResolution(uint256 marketId, Resolution outcome, string memory proofUrl) internal {
        if (!isHubFactory) revert MarketFactory__NotHubFactory();
        if (marketById[marketId] == address(0)) revert MarketFactory__MarketNotFound();
        if (ccipRouter == address(0)) revert MarketFactory__CcipRouterNotSet();
        if (ccipFeeToken == address(0)) revert MarketFactory__CcipFeeTokenNotSet();
        if (outcome == Resolution.Unset || outcome == Resolution.Inconclusive) {
            revert MarketFactory__InvalidResolutionOutcome();
        }

        ResolutionSync memory payload =
            ResolutionSync({marketId: marketId, outcome: uint8(outcome), proofUrl: proofUrl, nonce: ++ccipNonce});
        bytes memory encodedPayload = abi.encode(payload);

        uint256 length = s_spokeSelectors.length;
        for (uint256 i = 0; i < length; i++) {
            bytes32 messageId = _sendCcipMessage(s_spokeSelectors[i], uint8(SyncMessageType.Resolution), encodedPayload);
            emit CcipMessageSent(messageId, s_spokeSelectors[i], uint8(SyncMessageType.Resolution));
        }
    }

    /// @notice Owner helper to register or correct market-id mapping.
    /// @dev Useful on spokes where mapping may need to be initialized out-of-band.
    function setMarketIdMapping(uint256 marketId, address market) external onlyOwner {
        if (market == address(0)) revert MarketFactory__ZeroAddress();
        marketById[marketId] = market;
        marketIdByAddress[market] = marketId;
    }

    /// @notice Sets optional bridge contract that mirrors market-id mappings.
    /// @dev New markets call into this bridge (if configured) during `_createMarket`.
    function setPredictionMarketBridge(address bridge) external onlyOwner {
        if (bridge == address(0)) revert MarketFactory__ZeroAddress();
        predictionMarketBridge = bridge;
        emit PredictionMarketBridgeUpdated(bridge);
    }

    /// @notice Sets optional router contract that receives market allowlist updates.
    /// @dev New markets call `setMarketAllowed(market, true)` on this router during `_createMarket`.
    function setPredictionMarketRouter(address router) external onlyOwner {
        if (router == address(0)) revert MarketFactory__ZeroAddress();
        predictionMarketRouter = router;
        emit PredictionMarketRouterUpdated(router);
    }

    /// @notice Removes a resolved market from active tracking.
    /// @dev Authorization is restricted to the market itself or factory owner.
    /// Uses swap-and-pop removal pattern:
    /// overwrite removed slot with array tail, update moved index, pop tail, delete old index entry.
    function removeResolvedMarket(address market) external {
        uint256 marketId = marketIdByAddress[market];
        address marketAddress = marketById[marketId];

        if (marketAddress == address(0)) revert MarketFactory__MarketNotFound();
        if (marketId == 0) revert MarketFactory__MarketNotFound();
        if (!isActiveMarket[market]) return;

        if (msg.sender != marketAddress && msg.sender != owner()) {
            revert MarketFactory__OnlyRegisteredMarket_Or_OwnerCanRemove();
        }

        uint256 index = marketToIndex[market];
        address lastMarket = activeMarkets[activeMarkets.length - 1];

        activeMarkets[index] = lastMarket;
        marketToIndex[lastMarket] = index;
        activeMarkets.pop();

        delete marketToIndex[market];
        isActiveMarket[market] = false;
        emit MarketFactoryResolvedEventRemoved(marketId);
    }

    /// @notice Marks a market as awaiting manual review.
    /// @dev Callable by registered market contract or owner. Duplicate marks are ignored.
    function markMarketForManualReview(address market) external {
        uint256 marketId = marketIdByAddress[market];
        address marketAddress = marketById[marketId];
        if (marketAddress == address(0) || marketId == 0) revert MarketFactory__MarketNotFound();
        if (msg.sender != marketAddress && msg.sender != owner()) {
            revert MarketFactory__OnlyRegisteredMarket_Or_OwnerCanRemove();
        }
        if (isManualReviewMarket[market]) return;

        isManualReviewMarket[market] = true;
        manualReviewMarketToIndex[market] = manualReviewMarkets.length;
        manualReviewMarkets.push(market);
        emit MarketMarkedForManualReview(marketId, market);
    }

    /// @notice Removes a market from manual-review tracking.
    /// @dev Callable by registered market contract or owner. Missing entry is a no-op.
    function removeManualReviewMarket(address market) external {
        uint256 marketId = marketIdByAddress[market];
        address marketAddress = marketById[marketId];
        if (marketAddress == address(0) || marketId == 0) revert MarketFactory__MarketNotFound();
        if (msg.sender != marketAddress && msg.sender != owner()) {
            revert MarketFactory__OnlyRegisteredMarket_Or_OwnerCanRemove();
        }
        if (!isManualReviewMarket[market]) return;

        uint256 index = manualReviewMarketToIndex[market];
        address lastMarket = manualReviewMarkets[manualReviewMarkets.length - 1];

        manualReviewMarkets[index] = lastMarket;
        manualReviewMarketToIndex[lastMarket] = index;
        manualReviewMarkets.pop();

        delete manualReviewMarketToIndex[market];
        delete isManualReviewMarket[market];
        emit ManualReviewMarketRemoved(marketId, market);
    }

    /// @inheritdoc IAny2EVMMessageReceiver
    /// @dev Inbound message pipeline:
    /// 1) verify caller is configured router,
    /// 2) verify source selector has trusted sender and sender bytes match exactly,
    /// 3) reject replayed messageId,
    /// 4) decode message type and payload,
    /// 5) apply price sync or resolution sync with nonce guards.
    function ccipReceive(Client.Any2EVMMessage calldata any2EvmMessage) external override {
        if (ccipRouter == address(0) || msg.sender != ccipRouter) revert MarketFactory__InvalidRemoteSender();

        bytes memory trustedSender = trustedRemoteBySelector[any2EvmMessage.sourceChainSelector];
        if (trustedSender.length == 0) revert MarketFactory__SourceChainNotAllowed();
        if (keccak256(trustedSender) != keccak256(any2EvmMessage.sender)) revert MarketFactory__InvalidRemoteSender();

        if (processedCcipMessages[any2EvmMessage.messageId]) revert MarketFactory__MessageAlreadyProcessed();
        processedCcipMessages[any2EvmMessage.messageId] = true;

        (uint8 msgType, bytes memory payload) = abi.decode(any2EvmMessage.data, (uint8, bytes));

        if (msgType == uint8(SyncMessageType.Price)) {
            CanonicalPriceSync memory p = abi.decode(payload, (CanonicalPriceSync));
            address market = marketById[p.marketId];
            if (market == address(0)) revert MarketFactory__MarketNotFound();
            PredictionMarket(market).syncCanonicalPriceFromHub(p.yesPriceE6, p.noPriceE6, p.validUntil, p.nonce);
            emit CanonicalPriceMessageReceived(p.marketId, p.yesPriceE6, p.noPriceE6, p.nonce);
            return;
        }

        if (msgType == uint8(SyncMessageType.Resolution)) {
            ResolutionSync memory r = abi.decode(payload, (ResolutionSync));
            address market = marketById[r.marketId];
            if (market == address(0)) revert MarketFactory__MarketNotFound();
            if (r.nonce <= resolutionNonceByMarketId[r.marketId]) revert MarketFactory__StaleResolutionNonce();
            if (r.outcome == uint8(Resolution.Unset) || r.outcome == uint8(Resolution.Inconclusive)) {
                revert MarketFactory__InvalidResolutionOutcome();
            }

            resolutionNonceByMarketId[r.marketId] = r.nonce;
            PredictionMarket(market).resolveFromHub(Resolution(r.outcome), r.proofUrl);
            _enqueueWithdraw(r.marketId);
            emit ResolutionMessageReceived(r.marketId, Resolution(r.outcome), r.nonce);
            return;
        }

        revert MarketFactory__UnknownSyncMessageType();
    }

    /// @notice Applies canonical price sync directly on spokes (report-driven path).
    /// @dev This bypasses CCIP transport but still preserves nonce monotonicity:
    /// next nonce is max(marketNonce + 1, trackedNonce + 1), then stored to prevent regressions.
    function _syncSpokeCanonicalPrice(uint256 marketId, uint256 yesPriceE6, uint256 noPriceE6, uint256 validUntil)
        internal
    {
        if (isHubFactory) revert MarketFactory__NotSpokeFactory();

        address marketAddress = marketById[marketId];
        if (marketAddress == address(0)) revert MarketFactory__MarketNotFound();

        PredictionMarket market = PredictionMarket(marketAddress);
        uint64 nextNonce = market.canonicalPriceNonce() + 1;
        uint64 trackedNonce = directPriceSyncNonceByMarketId[marketId];
        if (trackedNonce >= nextNonce) {
            nextNonce = trackedNonce + 1;
        }

        directPriceSyncNonceByMarketId[marketId] = nextNonce;
        market.syncCanonicalPriceFromHub(yesPriceE6, noPriceE6, validUntil, nextNonce);
        emit CanonicalPriceMessageReceived(marketId, yesPriceE6, noPriceE6, nextNonce);
    }

    /// @notice ERC165 declaration so CCIP infra can detect receiver support.
    function supportsInterface(bytes4 interfaceId) public pure override returns (bool) {
        return interfaceId == type(IAny2EVMMessageReceiver).interfaceId || super.supportsInterface(interfaceId);
    }

    /// @dev Constructs and sends a CCIP EVM2Any message.
    /// Steps:
    /// 1) resolve trusted receiver bytes for destination selector,
    /// 2) build message envelope with data + fee token + gas args,
    /// 3) query router fee quote,
    /// 4) increase fee-token allowance just enough,
    /// 5) call `ccipSend` and return message id.
    function _sendCcipMessage(uint64 destinationChainSelector, uint8 messageType, bytes memory payload)
        internal
        returns (bytes32 messageId)
    {
        bytes memory receiver = trustedRemoteBySelector[destinationChainSelector];
        if (receiver.length == 0) revert MarketFactory__SourceChainNotAllowed();

        Client.EVMTokenAmount[] memory tokenAmounts = new Client.EVMTokenAmount[](0);
        Client.EVM2AnyMessage memory message = Client.EVM2AnyMessage({
            receiver: receiver,
            data: abi.encode(messageType, payload),
            tokenAmounts: tokenAmounts,
            feeToken: ccipFeeToken,
            extraArgs: Client._argsToBytes(
                Client.EVMExtraArgsV2({gasLimit: 800_000, allowOutOfOrderExecution: true})
            )
        });

        uint256 fee = IRouterClient(ccipRouter).getFee(destinationChainSelector, message);
        IERC20(ccipFeeToken).safeIncreaseAllowance(ccipRouter, fee);
        messageId = IRouterClient(ccipRouter).ccipSend(destinationChainSelector, message);
    }

    /// @dev Enqueues market for deferred withdrawal exactly once.
    /// No-op for zero id or already-queued id; reverts if mapping does not exist.
    function _enqueueWithdraw(uint256 marketId) internal {
        if (marketId == 0) return;
        if (isPendingWithdrawQueued[marketId]) return;
        if (marketById[marketId] == address(0)) revert MarketFactory__MarketNotFound();

        isPendingWithdrawQueued[marketId] = true;
        pendingWithdrawQueue.push(marketId);
        emit WithdrawEnqueued(marketId);
    }
}
