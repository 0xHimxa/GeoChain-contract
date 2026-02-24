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

abstract contract MarketFactoryCcip is MarketFactoryBase {
    using SafeERC20 for IERC20;

    function setCcipConfig(address _ccipRouter, address _ccipFeeToken, bool _isHubFactory) external onlyOwner {
        if (_ccipRouter == address(0) || _ccipFeeToken == address(0)) revert MarketFactory__ZeroAddress();
        ccipRouter = _ccipRouter;
        ccipFeeToken = _ccipFeeToken;
        isHubFactory = _isHubFactory;
        emit CcipConfigUpdated(_ccipRouter, _ccipFeeToken, _isHubFactory);
    }

    function setSupportedChainSelector(uint64 chainSelector, bool isSupported) external onlyOwner {
        if (chainSelector == 0) revert MarketFactory__ChainSelectorCantbezero();
        s_supportedChainSelector[chainSelector] = isSupported;
        emit ChainSelectorSupportUpdated(chainSelector, isSupported);
    }

    function isSupportedChainSelector(uint64 chainSelector) external view returns (bool) {
        return s_supportedChainSelector[chainSelector];
    }

    function setTrustedRemote(uint64 chainSelector, address remoteFactory) external onlyOwner {
        if (remoteFactory == address(0)) revert MarketFactory__ZeroAddress();
        if (chainSelector == 0) revert MarketFactory__ChainSelectorCantbezero();

        if (!s_supportedChainSelector[chainSelector]) {
            revert MarketFactory__ChainSelectornNotSupported();
        }

        trustedRemoteBySelector[chainSelector] = abi.encode(remoteFactory);
        if (!s_spokeSelectorExists[chainSelector]) {
            s_spokeSelectorExists[chainSelector] = true;
            s_spokeSelectors.push(chainSelector);
        }

        emit TrustedRemoteUpdated(chainSelector, remoteFactory);
    }

    function removeTrustedRemote(uint64 chainSelector) external onlyOwner {
        if (chainSelector == 0) revert MarketFactory__ChainSelectorCantbezero();
        if (!s_supportedChainSelector[chainSelector]) {
            revert MarketFactory__ChainSelectornNotSupported();
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

    function getSpokeSelectors() external view returns (uint64[] memory selectors) {
        return s_spokeSelectors;
    }

    function broadcastCanonicalPrice(uint256 marketId, uint256 yesPriceE6, uint256 noPriceE6, uint256 validUntil)
        external
        onlyOwner
    {
        _broadcastCanonicalPrice(marketId, yesPriceE6, noPriceE6, validUntil);
    }

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

    function broadcastResolution(uint256 marketId, Resolution outcome, string memory proofUrl) external onlyOwner {
        _broadcastResolution(marketId, outcome, proofUrl);
    }

    function onHubMarketResolved(Resolution outcome, string calldata proofUrl) external {
        uint256 marketId = marketIdByAddress[msg.sender];
        if (marketId == 0 || marketById[marketId] != msg.sender) revert MarketFactory__OnlyRegisteredMarket();
        _enqueueWithdraw(marketId);
        _broadcastResolution(marketId, outcome, proofUrl);
    }

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

    function setMarketIdMapping(uint256 marketId, address market) external onlyOwner {
        if (market == address(0)) revert MarketFactory__ZeroAddress();
        marketById[marketId] = market;
        marketIdByAddress[market] = marketId;
    }

    function setPredictionMarketBridge(address bridge) external onlyOwner {
        if (bridge == address(0)) revert MarketFactory__ZeroAddress();
        predictionMarketBridge = bridge;
        emit PredictionMarketBridgeUpdated(bridge);
    }

    function removeResolvedMarket(address market) external {
        uint256 marketId = marketIdByAddress[market];
        address marketAddress = marketById[marketId];

        if (marketAddress == address(0)) revert MarketFactory__MarketNotFound();
        if (marketId == 0) revert MarketFactory__MarketNotFound();

        if (msg.sender != marketAddress && msg.sender != owner()) {
            revert MarketFactory__OnlyRegisteredMarket_Or_OwnerCanRemove();
        }

        uint256 index = marketToIndex[market];
        address lastMarket = activeMarkets[activeMarkets.length - 1];

        activeMarkets[index] = lastMarket;
        marketToIndex[lastMarket] = index;
        activeMarkets.pop();

        delete marketToIndex[market];
        emit MarkertFactor_ReslovedEventReomved(marketId);
    }

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

    function supportsInterface(bytes4 interfaceId) public pure override returns (bool) {
        return interfaceId == type(IAny2EVMMessageReceiver).interfaceId || super.supportsInterface(interfaceId);
    }

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

    function _enqueueWithdraw(uint256 marketId) internal {
        if (marketId == 0) return;
        if (isPendingWithdrawQueued[marketId]) return;
        if (marketById[marketId] == address(0)) revert MarketFactory__MarketNotFound();

        isPendingWithdrawQueued[marketId] = true;
        pendingWithdrawQueue.push(marketId);
        emit WithdrawEnqueued(marketId);
    }
}
