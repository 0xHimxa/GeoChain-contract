// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {Client} from "../ccip/Client.sol";
import {IRouterClient} from "../ccip/IRouterClient.sol";
import {IAny2EVMMessageReceiver} from "../ccip/IAny2EVMMessageReceiver.sol";
import {CcipWrappedClaimToken} from "./BridgeWrappedClaimToken.sol";

interface IPredictionMarketClaimSource {
    function yesToken() external view returns (address);
    function noToken() external view returns (address);
    function resolution() external view returns (uint8);
}

/// @title PredictionMarketBridge
/// @notice Bridges resolved winning-claim tokens across chains using CCIP.
/// @dev Core model:
/// - Source chain: lock underlying winning claim token in this bridge.
/// - Destination chain: mint synthetic wrapped claim token representing that locked claim.
/// - Reverse path: burn wrapped claims and unlock underlying claims on source chain.
/// Replay protection, trusted-remote checks, and winning-side validation are enforced on both directions.
contract PredictionMarketBridge is Ownable, IAny2EVMMessageReceiver, IERC165 {
    using SafeERC20 for IERC20;

    /// @dev Encoded `Resolution.Yes` value expected from market contracts.
    uint8 private constant RESOLUTION_YES = 1;
    /// @dev Encoded `Resolution.No` value expected from market contracts.
    uint8 private constant RESOLUTION_NO = 2;
    /// @dev Basis points denominator (100%).
    uint16 private constant BPS_DENOMINATOR = 10_000;

    /// @dev Message discriminant used in CCIP payload encoding.
    enum MessageType {
        MintWrappedClaim,
        UnlockUnderlyingClaim
    }

    /// @dev Payload sent when source chain locks underlying claim and destination should mint wrapped claim.
    struct LockClaimPayload {
        uint256 marketId;
        bool useYesToken;
        uint256 amount;
        address receiver;
        uint64 nonce;
    }

    /// @dev Payload sent when wrapped claim is burned and source should unlock underlying claim.
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
    error PredictionMarketBridge__NotAuthorizedMarketMapper();

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
    event MarketFactoryUpdated(address indexed marketFactory);
    event  NewGasLimit(uint256 amount);

    /// @notice ERC20 used for buyback payouts.
    IERC20 public immutable collateral;
    /// @notice CCIP router that sends/receives messages.
    address public ccipRouter;
    /// @notice Token used to pay CCIP fees.
    address public ccipFeeToken;
    /// @notice Incrementing nonce used in outbound payloads.
    uint64 public outboundNonce;
    /// @notice Buyback payout ratio in bps (10_000 = full payout).
    uint16 public wrappedClaimBuybackBps;
    /// @notice Address that receives unlocked source claims after buyback.
    address public buybackUnlockReceiver;
    /// @notice Optional factory allowed to update market mappings.
    address public marketFactory;
    /// @notice Fixed gas limit used in CCIP extra args.
    uint256 public  ccipGasLimit = 1_300_000;

    /// @notice Chain selectors allowed for bridge traffic.
    mapping(uint64 => bool) public supportedChainSelector;
    /// @notice Trusted remote bridge address bytes by chain selector.
    mapping(uint64 => bytes) public trustedRemoteBySelector;
    /// @notice Replay-protection flag for processed CCIP message ids.
    mapping(bytes32 => bool) public processedCcipMessages;
    /// @notice Market address by market id on this chain.
    mapping(uint256 => address) public marketById;
    /// @notice Wrapped token address keyed by source chain + market + side.
    mapping(bytes32 => address) public wrappedClaimTokenByKey;

    /// @param initialOwner Bridge owner with config permissions.
    /// @param collateralToken Collateral used for wrapped-claim buybacks.
    constructor(address initialOwner, address collateralToken) Ownable(initialOwner) {
        if (initialOwner == address(0) || collateralToken == address(0)) revert PredictionMarketBridge__ZeroAddress();
        collateral = IERC20(collateralToken);
        wrappedClaimBuybackBps = BPS_DENOMINATOR;
        buybackUnlockReceiver = initialOwner;
    }

    /// @notice Configures router and fee token used for CCIP sends/receives.
    /// @dev Must be set before any bridge send path can execute.
    function setCcipConfig(address router, address feeToken) external onlyOwner {
        if (router == address(0) || feeToken == address(0)) revert PredictionMarketBridge__ZeroAddress();
        ccipRouter = router;
        ccipFeeToken = feeToken;
        emit CcipConfigUpdated(router, feeToken);
    }

    /// @notice Adds or removes a chain selector from bridge allowlist.
    /// @dev A selector must be enabled here before trusted remote can be configured and used.
    function setSupportedChainSelector(uint64 chainSelector, bool isSupported) external onlyOwner {
        if (chainSelector == 0) revert PredictionMarketBridge__UnsupportedChainSelector();
        supportedChainSelector[chainSelector] = isSupported;
        emit ChainSelectorSupportUpdated(chainSelector, isSupported);
    }

    /// @notice Stores trusted remote bridge for a supported selector.
    /// @dev Incoming CCIP sender bytes must exactly match this value for message acceptance.
    function setTrustedRemote(uint64 chainSelector, address remoteBridge) external onlyOwner {
        if (chainSelector == 0 || !supportedChainSelector[chainSelector]) {
            revert PredictionMarketBridge__UnsupportedChainSelector();
        }
        if (remoteBridge == address(0)) revert PredictionMarketBridge__ZeroAddress();
        trustedRemoteBySelector[chainSelector] = abi.encode(remoteBridge);
        emit TrustedRemoteUpdated(chainSelector, remoteBridge);
    }

    /// @notice Deletes trusted remote bridge config for a selector.
    /// @dev After removal, both send and receive paths for that selector will fail.
    function removeTrustedRemote(uint64 chainSelector) external onlyOwner {
        if (chainSelector == 0 || !supportedChainSelector[chainSelector]) {
            revert PredictionMarketBridge__UnsupportedChainSelector();
        }
        delete trustedRemoteBySelector[chainSelector];
        emit TrustedRemoteRemoved(chainSelector);
    }

    /// @notice Sets optional factory authorized to maintain market-id mappings.
    /// @dev Authorization model for mapping updates is (owner OR configured factory).
    function setMarketFactory(address factory) external onlyOwner {
        if (factory == address(0)) revert PredictionMarketBridge__ZeroAddress();
        marketFactory = factory;
        emit MarketFactoryUpdated(factory);
    }

    /// @notice Registers market id -> market address mapping used for winning-token lookup.
    /// @dev Required before unlock paths, because bridge must resolve which market contract
    /// defines winning YES/NO token for a given id.
    function setMarketIdMapping(uint256 marketId, address market) external {
        if (msg.sender != owner() && msg.sender != marketFactory) {
            revert PredictionMarketBridge__NotAuthorizedMarketMapper();
        }
        if (market == address(0)) revert PredictionMarketBridge__ZeroAddress();
        marketById[marketId] = market;
        emit MarketMapped(marketId, market);
    }

    /// @notice Sets buyback payout ratio for `sellWrappedClaimForCollateral`.
    /// @dev `10_000` = 100%, `9_800` = 98%.
    function setWrappedClaimBuybackBps(uint16 buybackBps) external onlyOwner {
        if (buybackBps > BPS_DENOMINATOR) revert PredictionMarketBridge__InvalidBps();
        wrappedClaimBuybackBps = buybackBps;
        emit BuybackBpsUpdated(buybackBps);
    }

    /// @notice Sets receiver of unlocked source claims produced by destination buybacks.
    /// @dev This lets protocol route unlocked claims to treasury/ops account instead of seller.
    function setBuybackUnlockReceiver(address receiver) external onlyOwner {
        if (receiver == address(0)) revert PredictionMarketBridge__ZeroAddress();
        buybackUnlockReceiver = receiver;
        emit BuybackUnlockReceiverUpdated(receiver);
    }

    /// @notice Funds collateral liquidity used to buy wrapped claims from users.
    /// @dev Collateral is pulled from owner and held by bridge until buyback/withdraw.
    function depositCollateralLiquidity(uint256 amount) external onlyOwner {
        if (amount == 0) revert PredictionMarketBridge__InvalidAmount();
        collateral.safeTransferFrom(msg.sender, address(this), amount);
        emit CollateralLiquidityDeposited(msg.sender, amount);
    }

    /// @notice Withdraws collateral liquidity buffer from bridge.
    /// @dev Administrative treasury operation; unrelated to claim unlocking balances.
    function withdrawCollateralLiquidity(address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert PredictionMarketBridge__ZeroAddress();
        if (amount == 0) revert PredictionMarketBridge__InvalidAmount();
        collateral.safeTransfer(to, amount);
        emit CollateralLiquidityWithdrawn(to, amount);
    }

    /// @notice Locks underlying winning claims and requests wrapped mint on destination.
    /// @dev Example: passing `amount = 5_000_000` represents 5 claim tokens (6 decimals).
    /// Flow:
    /// 1) validate destination selector + remote trust + receiver,
    /// 2) resolve market and confirm selected side is winning side,
    /// 3) transfer winning claims from user into bridge lockbox,
    /// 4) send CCIP mint request with monotonic nonce,
    /// 5) emit lock event with message id for traceability.
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

    /// @notice Burns wrapped claims and requests source-chain unlock to a receiver.
    /// @dev Flow:
    /// 1) resolve wrapped token by deterministic claim key,
    /// 2) pull wrapped token from caller and burn it,
    /// 3) send CCIP unlock payload to source chain,
    /// 4) source bridge later transfers locked underlying claim to `receiverOnSource`.
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

    /// @notice Sells wrapped claims to bridge for collateral and triggers source unlock to protocol receiver.
    /// @dev Economic logic:
    /// `collateralOut = wrappedAmount * wrappedClaimBuybackBps / 10_000`.
    /// Bridge enforces user slippage floor and available collateral liquidity.
    /// Wrapped claim is burned, user receives collateral immediately, and underlying claim is
    /// unlocked on source to `buybackUnlockReceiver` via CCIP message.
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

    /// @notice Quotes router fee for a prospective outbound CCIP bridge message.
    /// @dev Uses same message encoding path as `_sendCcipMessage`, but read-only.
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
                Client.EVMExtraArgsV2({gasLimit: ccipGasLimit, allowOutOfOrderExecution: true})
            )
        });
        fee = IRouterClient(ccipRouter).getFee(destinationChainSelector, message);
    }

    /// @inheritdoc IAny2EVMMessageReceiver
    /// @dev Inbound verification pipeline:
    /// 1) require configured router caller,
    /// 2) require selector supported and sender matches trusted remote bytes,
    /// 3) reject duplicate messageId (replay guard),
    /// 4) dispatch by message type to mint or unlock handler.
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

    /// @notice ERC165 support declaration used by CCIP infrastructure.
    function supportsInterface(bytes4 interfaceId) public pure override returns (bool) {
        return interfaceId == type(IAny2EVMMessageReceiver).interfaceId || interfaceId == type(IERC165).interfaceId;
    }

    /// @dev Handles inbound mint message from source lock event.
    /// If this claim key has no wrapped token yet, deploys one lazily, stores mapping, then mints.
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

    /// @dev Handles inbound unlock message after wrapped burn/buyback.
    /// Validates market mapping + winning side and transfers locked underlying claim inventory.
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

    /// @dev Resolves winning token address and verifies requested side matches final market outcome.
    /// Reverts if market not finally resolved or caller requested losing side token.
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

    /// @dev Shared outbound CCIP send helper for both mint and unlock message paths.
    /// Builds envelope, quotes fee, raises allowance, and sends via router.
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
                Client.EVMExtraArgsV2({gasLimit: ccipGasLimit, allowOutOfOrderExecution: true})
            )
        });

        uint256 fee = IRouterClient(ccipRouter).getFee(destinationChainSelector, message);
        IERC20(ccipFeeToken).safeIncreaseAllowance(ccipRouter, fee);
        messageId = IRouterClient(ccipRouter).ccipSend(destinationChainSelector, message);
    }

    /// @dev Deploys wrapped claim token for a unique `(sourceChain, marketId, side)` tuple.
    /// Name/symbol include source metadata so users can identify provenance.
    function _createWrappedClaimToken(uint64 sourceChainSelector, uint256 marketId, bool useYesToken)
        internal
        returns (address)
    {
        string memory outcomeLabel = useYesToken ? "YES" : "NO";
        string memory name = string(
            abi.encode("Wrapped Claim ", outcomeLabel, " M", Strings.toString(marketId), " S", Strings.toString(sourceChainSelector))
        );
        string memory symbol = string(
            abi.encode("wC", outcomeLabel, Strings.toString(marketId))
        );

        CcipWrappedClaimToken token = new CcipWrappedClaimToken(name, symbol, address(this));
        return address(token);
    }

    /// @dev Deterministic key used for wrapped-token registry and event correlation.
    function _claimKey(uint64 sourceChainSelector, uint256 marketId, bool useYesToken) internal pure returns (bytes32) {
        return keccak256(abi.encode(sourceChainSelector, marketId, useYesToken));
    }


    function getBridgeUSDCBalance() external view returns (uint256) {
        return collateral.balanceOf(address(this));
        
        }


        function setCCIPgasLimit(uint256 amount) external onlyOwner{

if(amount == 0) revert PredictionMarketBridge__InvalidAmount();
        ccipGasLimit = amount;
        emit NewGasLimit(amount);
        

        }
}
