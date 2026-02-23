// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {Client} from "./Client.sol";
import {IRouterClient} from "./IRouterClient.sol";
import {IAny2EVMMessageReceiver} from "./IAny2EVMMessageReceiver.sol";
import {CcipWrappedClaimToken} from "./CcipWrappedClaimToken.sol";

interface IPredictionMarketClaimSource {
    function yesToken() external view returns (address);
    function noToken() external view returns (address);
    function resolution() external view returns (uint8);
}

/**
 * @title PredictionMarketBridge
 * @notice Claim bridge using lock/mint and burn/unlock over CCIP for resolved markets.
 * @dev Source chain locks winning claim token; destination mints wrapped claim.
 *      Burning wrapped claim sends CCIP unlock message back to source chain.
 */
contract PredictionMarketBridge is Ownable, IAny2EVMMessageReceiver, IERC165 {
    using SafeERC20 for IERC20;

    uint8 private constant RESOLUTION_YES = 1;
    uint8 private constant RESOLUTION_NO = 2;
    uint16 private constant BPS_DENOMINATOR = 10_000;

    enum MessageType {
        MintWrappedClaim,
        UnlockUnderlyingClaim
    }

    struct LockClaimPayload {
        uint256 marketId;
        bool useYesToken;
        uint256 amount;
        address receiver;
        uint64 nonce;
    }

    struct UnlockClaimPayload {
        uint256 marketId;
        bool useYesToken;
        uint256 amount;
        address receiver;
        uint64 nonce;
    }

    error PredictionMarketBridge__ZeroAddress();
    error PredictionMarketBridge__InvalidAmount();
    error PredictionMarketBridge__UnsupportedChainSelector();
    error PredictionMarketBridge__UnknownMarket();
    error PredictionMarketBridge__InvalidRouterSender();
    error PredictionMarketBridge__InvalidRemoteSender();
    error PredictionMarketBridge__MessageAlreadyProcessed();
    error PredictionMarketBridge__UnknownMessageType();
    error PredictionMarketBridge__MarketNotResolved();
    error PredictionMarketBridge__TokenNotWinningClaim();
    error PredictionMarketBridge__UnknownWrappedClaimToken();
    error PredictionMarketBridge__InsufficientLockedClaims();
    error PredictionMarketBridge__InvalidBps();
    error PredictionMarketBridge__InsufficientCollateralLiquidity();
    error PredictionMarketBridge__SlippageExceeded();

    event CcipConfigUpdated(address indexed router, address indexed feeToken);
    event ChainSelectorSupportUpdated(uint64 indexed chainSelector, bool indexed isSupported);
    event TrustedRemoteUpdated(uint64 indexed chainSelector, address indexed remoteBridge);
    event TrustedRemoteRemoved(uint64 indexed chainSelector);
    event MarketMapped(uint256 indexed marketId, address indexed market);
    event WrappedClaimTokenCreated(bytes32 indexed claimKey, address indexed wrappedToken);
    event ClaimLockedForBridge(
        bytes32 indexed messageId,
        uint64 indexed destinationChainSelector,
        uint256 indexed marketId,
        bool useYesToken,
        address sender,
        address receiver,
        uint256 amount,
        uint64 nonce
    );
    event WrappedClaimMinted(
        bytes32 indexed messageId,
        uint64 indexed sourceChainSelector,
        bytes32 indexed claimKey,
        address wrappedToken,
        address receiver,
        uint256 amount
    );
    event WrappedClaimBurnedForUnlock(
        bytes32 indexed messageId,
        uint64 indexed sourceChainSelector,
        uint256 indexed marketId,
        bool useYesToken,
        address sender,
        address receiver,
        uint256 amount,
        uint64 nonce
    );
    event UnderlyingClaimUnlocked(
        bytes32 indexed messageId,
        uint64 indexed sourceChainSelector,
        uint256 indexed marketId,
        bool useYesToken,
        address receiver,
        uint256 amount
    );
    event WrappedClaimSold(
        bytes32 indexed claimKey, address indexed seller, uint256 wrappedAmount, uint256 collateralPaid, uint16 buybackBps
    );
    event BuybackUnlockReceiverUpdated(address indexed receiver);
    event BuybackUnlockRequested(
        bytes32 indexed messageId,
        uint64 indexed sourceChainSelector,
        uint256 indexed marketId,
        bool useYesToken,
        address unlockReceiver,
        uint256 amount,
        uint64 nonce
    );
    event CollateralLiquidityDeposited(address indexed from, uint256 amount);
    event CollateralLiquidityWithdrawn(address indexed to, uint256 amount);
    event BuybackBpsUpdated(uint16 buybackBps);

    IERC20 public immutable collateral;
    address public ccipRouter;
    address public ccipFeeToken;
    uint64 public outboundNonce;
    uint16 public wrappedClaimBuybackBps;
    address public buybackUnlockReceiver;

    mapping(uint64 => bool) public supportedChainSelector;
    mapping(uint64 => bytes) public trustedRemoteBySelector;
    mapping(bytes32 => bool) public processedCcipMessages;
    mapping(uint256 => address) public marketById;
    mapping(bytes32 => address) public wrappedClaimTokenByKey;

    constructor(address initialOwner, address collateralToken) Ownable(initialOwner) {
        if (initialOwner == address(0) || collateralToken == address(0)) revert PredictionMarketBridge__ZeroAddress();
        collateral = IERC20(collateralToken);
        wrappedClaimBuybackBps = BPS_DENOMINATOR;
        buybackUnlockReceiver = initialOwner;
    }

    function setCcipConfig(address router, address feeToken) external onlyOwner {
        if (router == address(0) || feeToken == address(0)) revert PredictionMarketBridge__ZeroAddress();
        ccipRouter = router;
        ccipFeeToken = feeToken;
        emit CcipConfigUpdated(router, feeToken);
    }

    function setSupportedChainSelector(uint64 chainSelector, bool isSupported) external onlyOwner {
        if (chainSelector == 0) revert PredictionMarketBridge__UnsupportedChainSelector();
        supportedChainSelector[chainSelector] = isSupported;
        emit ChainSelectorSupportUpdated(chainSelector, isSupported);
    }

    function setTrustedRemote(uint64 chainSelector, address remoteBridge) external onlyOwner {
        if (chainSelector == 0 || !supportedChainSelector[chainSelector]) {
            revert PredictionMarketBridge__UnsupportedChainSelector();
        }
        if (remoteBridge == address(0)) revert PredictionMarketBridge__ZeroAddress();
        trustedRemoteBySelector[chainSelector] = abi.encode(remoteBridge);
        emit TrustedRemoteUpdated(chainSelector, remoteBridge);
    }

    function removeTrustedRemote(uint64 chainSelector) external onlyOwner {
        if (chainSelector == 0 || !supportedChainSelector[chainSelector]) {
            revert PredictionMarketBridge__UnsupportedChainSelector();
        }
        delete trustedRemoteBySelector[chainSelector];
        emit TrustedRemoteRemoved(chainSelector);
    }
// Cre to be able to call this function when a new market is created and set it id
    function setMarketIdMapping(uint256 marketId, address market) external onlyOwner {
        if (market == address(0)) revert PredictionMarketBridge__ZeroAddress();
        marketById[marketId] = market;
        emit MarketMapped(marketId, market);
    }

    /// @notice Sets buyback rate when users sell wrapped claims for collateral on destination chains.
    /// @dev 10_000 = 100%, 9_800 = 98%.
    function setWrappedClaimBuybackBps(uint16 buybackBps) external onlyOwner {
        if (buybackBps > BPS_DENOMINATOR) revert PredictionMarketBridge__InvalidBps();
        wrappedClaimBuybackBps = buybackBps;
        emit BuybackBpsUpdated(buybackBps);
    }

    /// @notice Destination-side receiver that gets unlocked source claims when users sell wrapped claims.
    function setBuybackUnlockReceiver(address receiver) external onlyOwner {
        if (receiver == address(0)) revert PredictionMarketBridge__ZeroAddress();
        buybackUnlockReceiver = receiver;
        emit BuybackUnlockReceiverUpdated(receiver);
    }

    /// @notice Owner funds collateral pool used for wrapped-claim buybacks.
    function depositCollateralLiquidity(uint256 amount) external onlyOwner {
        if (amount == 0) revert PredictionMarketBridge__InvalidAmount();
        collateral.safeTransferFrom(msg.sender, address(this), amount);
        emit CollateralLiquidityDeposited(msg.sender, amount);
    }

    /// @notice Owner withdraws collateral pool.
    function withdrawCollateralLiquidity(address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert PredictionMarketBridge__ZeroAddress();
        if (amount == 0) revert PredictionMarketBridge__InvalidAmount();
        collateral.safeTransfer(to, amount);
        emit CollateralLiquidityWithdrawn(to, amount);
    }

    /**
     * @notice Locks winning claims on this chain and mints wrapped claims on destination chain.
     */
    function lockAndBridgeClaim(
        uint256 marketId,
        bool useYesToken,
        uint256 amount,
        uint64 destinationChainSelector,
        address receiver
    ) external returns (bytes32 messageId) {
        if (amount == 0) revert PredictionMarketBridge__InvalidAmount();
        if (receiver == address(0)) revert PredictionMarketBridge__ZeroAddress();

        bytes memory remote = trustedRemoteBySelector[destinationChainSelector];
        if (remote.length == 0 || !supportedChainSelector[destinationChainSelector]) {
            revert PredictionMarketBridge__UnsupportedChainSelector();
        }

        address marketAddress = marketById[marketId];
        if (marketAddress == address(0)) revert PredictionMarketBridge__UnknownMarket();

        IPredictionMarketClaimSource market = IPredictionMarketClaimSource(marketAddress);
        address winningToken = _getWinningClaimToken(market, useYesToken);
        IERC20(winningToken).safeTransferFrom(msg.sender, address(this), amount);

        LockClaimPayload memory payload = LockClaimPayload({
            marketId: marketId,
            useYesToken: useYesToken,
            amount: amount,
            receiver: receiver,
            nonce: ++outboundNonce
        });

        messageId = _sendCcipMessage(
            destinationChainSelector, uint8(MessageType.MintWrappedClaim), abi.encode(payload)
        );

        emit ClaimLockedForBridge(
            messageId,
            destinationChainSelector,
            marketId,
            useYesToken,
            msg.sender,
            receiver,
            amount,
            outboundNonce
        );
    }

    /**
     * @notice Burns wrapped claims on this chain and unlocks underlying claims on source chain.
     * @param sourceChainSelector Chain selector where underlying claims are locked.
     */
    function burnWrappedAndUnlockClaim(
        uint64 sourceChainSelector,
        uint256 marketId,
        bool useYesToken,
        uint256 amount,
        address receiverOnSource
    ) external returns (bytes32 messageId) {
        if (amount == 0) revert PredictionMarketBridge__InvalidAmount();
        if (receiverOnSource == address(0)) revert PredictionMarketBridge__ZeroAddress();
        if (!supportedChainSelector[sourceChainSelector]) revert PredictionMarketBridge__UnsupportedChainSelector();

        bytes32 claimKey = _claimKey(sourceChainSelector, marketId, useYesToken);
        address wrappedTokenAddress = wrappedClaimTokenByKey[claimKey];
        if (wrappedTokenAddress == address(0)) revert PredictionMarketBridge__UnknownWrappedClaimToken();

        IERC20 wrappedToken = IERC20(wrappedTokenAddress);
        wrappedToken.safeTransferFrom(msg.sender, address(this), amount);
        CcipWrappedClaimToken(wrappedTokenAddress).burn(amount);

        UnlockClaimPayload memory payload = UnlockClaimPayload({
            marketId: marketId,
            useYesToken: useYesToken,
            amount: amount,
            receiver: receiverOnSource,
            nonce: ++outboundNonce
        });

        messageId = _sendCcipMessage(sourceChainSelector, uint8(MessageType.UnlockUnderlyingClaim), abi.encode(payload));

        emit WrappedClaimBurnedForUnlock(
            messageId,
            sourceChainSelector,
            marketId,
            useYesToken,
            msg.sender,
            receiverOnSource,
            amount,
            outboundNonce
        );
    }

    /**
     * @notice Sells wrapped claim token back to this bridge for collateral on destination chain.
     * @dev Requires owner-funded collateral liquidity. Wrapped token is burned.
     */
    function sellWrappedClaimForCollateral(
        uint64 sourceChainSelector,
        uint256 marketId,
        bool useYesToken,
        uint256 wrappedAmount,
        uint256 minCollateralOut
    ) external returns (uint256 collateralOut, bytes32 messageId) {
        if (wrappedAmount == 0) revert PredictionMarketBridge__InvalidAmount();
        if (buybackUnlockReceiver == address(0)) revert PredictionMarketBridge__ZeroAddress();
        if (!supportedChainSelector[sourceChainSelector]) revert PredictionMarketBridge__UnsupportedChainSelector();

        bytes32 claimKey = _claimKey(sourceChainSelector, marketId, useYesToken);
        address wrappedTokenAddress = wrappedClaimTokenByKey[claimKey];
        if (wrappedTokenAddress == address(0)) revert PredictionMarketBridge__UnknownWrappedClaimToken();

        collateralOut = (wrappedAmount * wrappedClaimBuybackBps) / BPS_DENOMINATOR;
        if (collateralOut < minCollateralOut) revert PredictionMarketBridge__SlippageExceeded();
        if (collateral.balanceOf(address(this)) < collateralOut) {
            revert PredictionMarketBridge__InsufficientCollateralLiquidity();
        }

        IERC20 wrappedToken = IERC20(wrappedTokenAddress);
        wrappedToken.safeTransferFrom(msg.sender, address(this), wrappedAmount);
        CcipWrappedClaimToken(wrappedTokenAddress).burn(wrappedAmount);

        collateral.safeTransfer(msg.sender, collateralOut);

        UnlockClaimPayload memory payload = UnlockClaimPayload({
            marketId: marketId,
            useYesToken: useYesToken,
            amount: wrappedAmount,
            receiver: buybackUnlockReceiver,
            nonce: ++outboundNonce
        });
        messageId = _sendCcipMessage(sourceChainSelector, uint8(MessageType.UnlockUnderlyingClaim), abi.encode(payload));

        emit WrappedClaimSold(claimKey, msg.sender, wrappedAmount, collateralOut, wrappedClaimBuybackBps);
        emit BuybackUnlockRequested(
            messageId,
            sourceChainSelector,
            marketId,
            useYesToken,
            buybackUnlockReceiver,
            wrappedAmount,
            outboundNonce
        );
    }

    function quoteBridgeFee(uint64 destinationChainSelector, uint8 messageType, bytes calldata payload)
        external
        view
        returns (uint256 fee)
    {
        if (ccipRouter == address(0) || ccipFeeToken == address(0)) revert PredictionMarketBridge__ZeroAddress();
        bytes memory receiver = trustedRemoteBySelector[destinationChainSelector];
        if (receiver.length == 0) revert PredictionMarketBridge__UnsupportedChainSelector();

        Client.EVMTokenAmount[] memory tokenAmounts = new Client.EVMTokenAmount[](0);
        Client.EVM2AnyMessage memory message = Client.EVM2AnyMessage({
            receiver: receiver,
            data: abi.encode(messageType, payload),
            tokenAmounts: tokenAmounts,
            feeToken: ccipFeeToken,
            extraArgs: Client._argsToBytes(
                Client.EVMExtraArgsV2({gasLimit: 700_000, allowOutOfOrderExecution: true})
            )
        });
        fee = IRouterClient(ccipRouter).getFee(destinationChainSelector, message);
    }

    /// @inheritdoc IAny2EVMMessageReceiver
    function ccipReceive(Client.Any2EVMMessage calldata any2EvmMessage) external override {
        if (ccipRouter == address(0) || msg.sender != ccipRouter) revert PredictionMarketBridge__InvalidRouterSender();

        bytes memory trustedSender = trustedRemoteBySelector[any2EvmMessage.sourceChainSelector];
        if (trustedSender.length == 0) revert PredictionMarketBridge__UnsupportedChainSelector();
        if (keccak256(trustedSender) != keccak256(any2EvmMessage.sender)) revert PredictionMarketBridge__InvalidRemoteSender();

        if (processedCcipMessages[any2EvmMessage.messageId]) revert PredictionMarketBridge__MessageAlreadyProcessed();
        processedCcipMessages[any2EvmMessage.messageId] = true;

        (uint8 messageType, bytes memory payload) = abi.decode(any2EvmMessage.data, (uint8, bytes));

        if (messageType == uint8(MessageType.MintWrappedClaim)) {
            _handleMintWrappedClaim(any2EvmMessage.messageId, any2EvmMessage.sourceChainSelector, payload);
            return;
        }

        if (messageType == uint8(MessageType.UnlockUnderlyingClaim)) {
            _handleUnlockUnderlyingClaim(any2EvmMessage.messageId, any2EvmMessage.sourceChainSelector, payload);
            return;
        }

        revert PredictionMarketBridge__UnknownMessageType();
    }

    /// @notice ERC165 support declaration used by CCIP OffRamp to detect receivers
    function supportsInterface(bytes4 interfaceId) public pure override returns (bool) {
        return interfaceId == type(IAny2EVMMessageReceiver).interfaceId || interfaceId == type(IERC165).interfaceId;
    }

    function _handleMintWrappedClaim(bytes32 messageId, uint64 sourceChainSelector, bytes memory payload) internal {
        LockClaimPayload memory transfer = abi.decode(payload, (LockClaimPayload));
        bytes32 claimKey = _claimKey(sourceChainSelector, transfer.marketId, transfer.useYesToken);
        address wrappedTokenAddress = wrappedClaimTokenByKey[claimKey];

        if (wrappedTokenAddress == address(0)) {
            wrappedTokenAddress = _createWrappedClaimToken(sourceChainSelector, transfer.marketId, transfer.useYesToken);
            wrappedClaimTokenByKey[claimKey] = wrappedTokenAddress;
            emit WrappedClaimTokenCreated(claimKey, wrappedTokenAddress);
        }

        CcipWrappedClaimToken(wrappedTokenAddress).mint(transfer.receiver, transfer.amount);

        emit WrappedClaimMinted(
            messageId,
            sourceChainSelector,
            claimKey,
            wrappedTokenAddress,
            transfer.receiver,
            transfer.amount
        );
    }

    function _handleUnlockUnderlyingClaim(bytes32 messageId, uint64 sourceChainSelector, bytes memory payload) internal {
        UnlockClaimPayload memory transfer = abi.decode(payload, (UnlockClaimPayload));
        address marketAddress = marketById[transfer.marketId];
        if (marketAddress == address(0)) revert PredictionMarketBridge__UnknownMarket();

        IPredictionMarketClaimSource market = IPredictionMarketClaimSource(marketAddress);
        address winningToken = _getWinningClaimToken(market, transfer.useYesToken);

        if (IERC20(winningToken).balanceOf(address(this)) < transfer.amount) {
            revert PredictionMarketBridge__InsufficientLockedClaims();
        }

        IERC20(winningToken).safeTransfer(transfer.receiver, transfer.amount);

        emit UnderlyingClaimUnlocked(
            messageId,
            sourceChainSelector,
            transfer.marketId,
            transfer.useYesToken,
            transfer.receiver,
            transfer.amount
        );
    }

    function _getWinningClaimToken(IPredictionMarketClaimSource market, bool useYesToken)
        internal
        view
        returns (address)
    {
        uint8 marketResolution = market.resolution();
        if (marketResolution != RESOLUTION_YES && marketResolution != RESOLUTION_NO) {
            revert PredictionMarketBridge__MarketNotResolved();
        }
        if ((useYesToken && marketResolution != RESOLUTION_YES) || (!useYesToken && marketResolution != RESOLUTION_NO))
        {
            revert PredictionMarketBridge__TokenNotWinningClaim();
        }
        return useYesToken ? market.yesToken() : market.noToken();
    }

    function _sendCcipMessage(uint64 destinationChainSelector, uint8 messageType, bytes memory payload)
        internal
        returns (bytes32 messageId)
    {
        if (ccipRouter == address(0) || ccipFeeToken == address(0)) revert PredictionMarketBridge__ZeroAddress();
        bytes memory receiver = trustedRemoteBySelector[destinationChainSelector];
        if (receiver.length == 0) revert PredictionMarketBridge__UnsupportedChainSelector();

        Client.EVMTokenAmount[] memory tokenAmounts = new Client.EVMTokenAmount[](0);
        Client.EVM2AnyMessage memory message = Client.EVM2AnyMessage({
            receiver: receiver,
            data: abi.encode(messageType, payload),
            tokenAmounts: tokenAmounts,
            feeToken: ccipFeeToken,
            extraArgs: Client._argsToBytes(
                Client.EVMExtraArgsV2({gasLimit: 700_000, allowOutOfOrderExecution: true})
            )
        });

        uint256 fee = IRouterClient(ccipRouter).getFee(destinationChainSelector, message);
        IERC20(ccipFeeToken).safeIncreaseAllowance(ccipRouter, fee);
        messageId = IRouterClient(ccipRouter).ccipSend(destinationChainSelector, message);
    }

    function _createWrappedClaimToken(uint64 sourceChainSelector, uint256 marketId, bool useYesToken)
        internal
        returns (address)
    {
        string memory outcomeLabel = useYesToken ? "YES" : "NO";
        string memory name = string(
            abi.encodePacked("Wrapped Claim ", outcomeLabel, " M", Strings.toString(marketId), " S", Strings.toString(sourceChainSelector))
        );
        string memory symbol = string(
            abi.encodePacked("wC", outcomeLabel, Strings.toString(marketId))
        );

        CcipWrappedClaimToken token = new CcipWrappedClaimToken(name, symbol, address(this));
        return address(token);
    }

    function _claimKey(uint64 sourceChainSelector, uint256 marketId, bool useYesToken) internal pure returns (bytes32) {
        return keccak256(abi.encode(sourceChainSelector, marketId, useYesToken));
    }
}
