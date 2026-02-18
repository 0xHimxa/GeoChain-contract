// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {console} from "forge-std/console.sol";
import {PredictionMarket} from "./PredictionMarket.sol";
import {MarketDeployer} from "./MarketDeployer.sol";
import {ReceiverTemplateUpgradeable} from "script/interfaces/ReceiverTemplateUpgradeable.sol";
import {MarketErrors, Resolution, MarketConstants} from "./libraries/MarketTypes.sol";
import {AMMLib} from "./libraries/AMMLib.sol";
import {OutcomeToken} from "./OutcomeToken.sol";
import {Client} from "./ccip/Client.sol";
import {IRouterClient} from "./ccip/IRouterClient.sol";
import {IAny2EVMMessageReceiver} from "./ccip/IAny2EVMMessageReceiver.sol";

/**
 * @title MarketFactory
 * @author 0xHimxa
 * @notice Factory contract for deploying new prediction markets with initial liquidity
 * @dev UUPS upgradeable factory. Uses initialize() instead of constructor.
 */
contract MarketFactory is Initializable, ReceiverTemplateUpgradeable, UUPSUpgradeable, IAny2EVMMessageReceiver {
    using SafeERC20 for IERC20;

    // ========================================
    // STATE VARIABLES
    // ========================================

    /// @notice The ERC20 token used as collateral for all markets (e.g., USDC)
    IERC20 public collateral;

    /// @notice Total number of markets created by this factory
    uint256 public marketCount;

    /// @notice Fixed amount of testnet USDC to mint into the factory (100,000 USDC with 6 decimals)
    /// @dev On mainnet this will be replaced with a real USDC funding flow instead of minting
    uint256 private Amount_Funding_Factory;

    /// @notice Tracks whether an address has been verified via World ID (Sybil-resistance)
    mapping(address => bool) public isVerified;

    /// @notice Records used World ID nullifier hashes to prevent the same human from verifying multiple wallets
    mapping(uint256 => bool) internal nullifierHashes;

    /// @notice Ordered list of all currently active (unresolved) market addresses
    /// @dev Markets are appended on creation and removed via swap-and-pop when resolved
    address[] public activeMarkets;

    /// @notice Maps a market address to its index in the activeMarkets array for O(1) removal
    mapping(address => uint256) public marketToIndex;

    /// @notice External deployer contract that holds the PredictionMarket creation bytecode
    /// @dev Separating deployment bytecode keeps MarketFactory under the 24 KB contract size limit
    MarketDeployer private marketDeployer;

    /// @notice Chainlink CCIP router used for cross-chain messaging
    address public ccipRouter;

    /// @notice ERC20 token used to pay CCIP fees (typically LINK)
    address public ccipFeeToken;

    /// @notice Whether this deployment is the canonical hub factory (Ethereum main deployment)
    bool public isHubFactory;

    /// @notice Monotonic nonce used for outbound CCIP sync messages
    uint64 public ccipNonce;

    /// @notice Ordered list of configured spoke chain selectors
    uint64[] private s_spokeSelectors;

    /// @notice Tracks if a chain selector has already been inserted into s_spokeSelectors
    mapping(uint64 => bool) private s_spokeSelectorExists;

    /// @notice Tracks whether a chain selector is allowed for trusted remote configuration
    mapping(uint64 => bool) private s_supportedChainSelector;

    /// @notice Trusted remote factory sender per chain selector (encoded as abi.encode(address))
    mapping(uint64 => bytes) public trustedRemoteBySelector;

    /// @notice Replay protection for inbound CCIP messages
    mapping(bytes32 => bool) public processedCcipMessages;

    /// @notice Global market ID registry
    mapping(uint256 => address) public marketById;

    /// @notice Reverse lookup from market address to market ID
    mapping(address => uint256) public marketIdByAddress;

    /// @notice Highest applied hub resolution nonce per market
    mapping(uint256 => uint64) public resolutionNonceByMarketId;


    //CRE Ation types
    bytes32 private hashed_BroadCastPrice;
    bytes32 private hashed_BroadCastResolution;
    bytes32 private hashed_CreateMarket;
    bytes32 private hashed_PriceCorrection; 
   

uint256  private initailEventLiquidity;

    enum SyncMessageType {
        Price,
        Resolution
    }

    struct CanonicalPriceSync {
        uint256 marketId;
        uint256 yesPriceE6;
        uint256 noPriceE6;
        uint256 validUntil;
        uint64 nonce;
    }

    struct ResolutionSync {
        uint256 marketId;
        uint8 outcome;
        string proofUrl;
        uint64 nonce;
    }

    // ========================================
    // EVENTS
    // ========================================

    event MarketCreated(uint256 indexed marketId, address indexed market, uint256 indexed initialLiquidity);

    /// @notice Emitted when testnet USDC is minted into the factory via addLiquidityToFactory()
    event MarketFactory__LiquidityAdded(uint256 indexed amount);
    event CcipConfigUpdated(address indexed router, address indexed feeToken, bool indexed isHubFactory);
    event ChainSelectorSupportUpdated(uint64 indexed chainSelector, bool indexed isSupported);
    event TrustedRemoteUpdated(uint64 indexed chainSelector, address indexed remoteFactory);
    event TrustedRemoteRemoved(uint64 indexed chainSelector);
    event CcipMessageSent(bytes32 indexed messageId, uint64 indexed destinationChainSelector, uint8 indexed messageType);
    event CanonicalPriceMessageReceived(uint256 indexed marketId, uint256 yesPriceE6, uint256 noPriceE6, uint64 nonce);
    event ResolutionMessageReceived(uint256 indexed marketId, Resolution indexed outcome, uint64 nonce);
    event UnsafeArbitrageExecuted(
        address indexed market,
        bool indexed yesForNo,
        uint256 collateralSpent,
        uint256 deviationBeforeBps,
        uint256 deviationAfterBps
    );

    // ========================================
    // ERRORS
    // ========================================

    error MarketFactory__ZeroLiquidity();
    error MarketFactory__ZeroAddress();
    error MarketFactory__NotHubFactory();
    error MarketFactory__CcipRouterNotSet();
    error MarketFactory__CcipFeeTokenNotSet();
    error MarketFactory__InvalidRemoteSender();
    error MarketFactory__SourceChainNotAllowed();
    error MarketFactory__MessageAlreadyProcessed();
    error MarketFactory__UnknownSyncMessageType();
    error MarketFactory__MarketNotFound();
    error MarketFactory__InvalidResolutionOutcome();
    error MarketFactory__StaleResolutionNonce();
    error MarketFactory__ChainSelectorCantbezero();
 error MarketFactory__ChainSelectornNotSupported();
  error MarketFactory__ActionNotRecognized();
    error MarketFactory__OnlyRegisteredMarket();
    error MarketFactory__ArbNotUnsafe();
    error MarketFactory__ArbZeroAmount();
    error MarketFactory__ArbNoDirection();
    error MarketFactory__ArbNoExposure();
    error MarketFactory__ArbInsufficientImprovement();
    error MarketFactory__OnlyRegisteredMarket_Or_OwnerCanRemove();



    // ========================================
    // CONSTRUCTOR
    // ========================================



    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initializes the factory for proxy usage.
     * @param _collateral Address of collateral token
     * @param _forwarder Address passed to each newly created market
     * @param _marketDeployer Address of deployer helper contract
     * @param _initialOwner Owner of the proxy
     */
    function initialize(address _collateral, address _forwarder, address _marketDeployer, address _initialOwner)
        external
        initializer
    {
        if (
            _collateral == address(0) || _forwarder == address(0) || _marketDeployer == address(0)
                || _initialOwner == address(0)
        ) {
            revert MarketFactory__ZeroAddress();
        }

        __ReceiverTemplateUpgradeable_init(_forwarder, _initialOwner);
        collateral = IERC20(_collateral);
        marketDeployer = MarketDeployer(_marketDeployer);
        Amount_Funding_Factory = 100000e6;
        
        hashed_BroadCastPrice = keccak256( abi.encodePacked("broadCastPrice"));
        hashed_BroadCastResolution = keccak256(abi.encodePacked("broadCastResolution"));
        hashed_CreateMarket = keccak256(abi.encodePacked("createMarket"));
        hashed_PriceCorrection = keccak256(abi.encodePacked("priceCorrection"));

        initailEventLiquidity = 10000e6;

        s_supportedChainSelector[16281711391670634445] = true;
        s_supportedChainSelector[3478487238524512106] = true;
        s_supportedChainSelector[16015286601757825753] = true;

    }

    /// @notice Updates the MarketDeployer helper contract address (owner only)
    /// @param _marketDeployer New deployer address; reverts on zero address
    /// @dev Use this if the deployer needs to be redeployed without redeploying the factory proxy
    function setMarketDeployer(address _marketDeployer) external onlyOwner {
        if (_marketDeployer == address(0)) revert MarketFactory__ZeroAddress();
        marketDeployer = MarketDeployer(_marketDeployer);
    }

    /// @notice UUPS upgrade authorization hook — only the owner can upgrade the implementation
    /// @param newImplementation Address of the new implementation contract; must not be zero
    function _authorizeUpgrade(address newImplementation) internal view override onlyOwner {
        if (newImplementation == address(0)) {
            revert MarketFactory__ZeroAddress();
        }
    }

    /// @notice Mints testnet USDC into the factory so it has collateral to seed new markets
    /// @dev TESTNET ONLY — on mainnet, real USDC will be transferred in instead of minted.
    ///      The factory must be the owner of the collateral token for mint() to succeed.
    ///      This provides initial liquidity for newly created markets.
    function addLiquidityToFactory() external onlyOwner {
        console.log(OutcomeToken(address(collateral)).owner(), "Owner");
        OutcomeToken(address(collateral)).mint(address(this), Amount_Funding_Factory);
        emit MarketFactory__LiquidityAdded(Amount_Funding_Factory);
    }

    /**
     * @notice Creates a new prediction market with initial liquidity
     */
    function createMarket(string memory question, uint256 closeTime, uint256 resolutionTime, uint256 initialLiquidity)
        external
        onlyOwner
        returns (address market)
    {
        return _createMarket(question, closeTime, resolutionTime, initialLiquidity);
    }

    function _createMarket(string memory question, uint256 closeTime, uint256 resolutionTime, uint256 initialLiquidity)
        internal
        returns (address market)
    {
        if (closeTime == 0 || resolutionTime == 0 || bytes(question).length == 0) {
            revert MarketErrors.PredictionMarket__InvalidArguments_PassedInConstructor();
        }

        // Ensure closeTime comes before resolutionTime
        if (closeTime > resolutionTime) {
            revert MarketErrors.PredictionMarket__CloseTimeGreaterThanResolutionTime();
        }

        if (initialLiquidity == 0) revert MarketFactory__ZeroLiquidity();
        if (address(marketDeployer) == address(0)) {
            revert MarketFactory__ZeroAddress();
        }

        PredictionMarket m = PredictionMarket(
            marketDeployer.deployPredictionMarket(
                question, address(collateral), closeTime, resolutionTime, address(this), _getForwarderAddress()
            )
        );

        // Fund the new market with collateral from the factory's balance
        collateral.safeTransfer(address(m), initialLiquidity);

        // Seed the AMM pool with equal YES/NO reserves backed by the transferred collateral
        m.seedLiquidity(initialLiquidity);

       

        marketCount++;
        marketById[marketCount] = address(m);
        marketIdByAddress[address(m)] = marketCount;

        // Register the market in the active list for Chainlink CRE to iterate over
        activeMarkets.push(address(m));
        marketToIndex[address(m)] = activeMarkets.length - 1;
        m.setCrossChainController(address(this));

 // Transfer market ownership from the factory to the caller (deployer/admin)
        m.transferOwnership(owner());

        emit MarketCreated(marketCount, address(m), initialLiquidity);

        return address(m);
    }

    /// @notice Configures CCIP router, fee token, and mode (hub/spoke)
    function setCcipConfig(address _ccipRouter, address _ccipFeeToken, bool _isHubFactory) external onlyOwner {
        if (_ccipRouter == address(0) || _ccipFeeToken == address(0)) revert MarketFactory__ZeroAddress();
        ccipRouter = _ccipRouter;
        ccipFeeToken = _ccipFeeToken;
        isHubFactory = _isHubFactory;
        emit CcipConfigUpdated(_ccipRouter, _ccipFeeToken, _isHubFactory);
    }

    /// @notice Sets whether a chain selector is supported for trusted remote configuration
    /// @param chainSelector The CCIP chain selector to configure
    /// @param isSupported Whether the selector should be considered supported
    function setSupportedChainSelector(uint64 chainSelector, bool isSupported) external onlyOwner {
        if (chainSelector == 0) revert MarketFactory__ChainSelectorCantbezero();
        s_supportedChainSelector[chainSelector] = isSupported;
        emit ChainSelectorSupportUpdated(chainSelector, isSupported);
    }

    /// @notice Returns whether a chain selector is supported for trusted remote configuration
    function isSupportedChainSelector(uint64 chainSelector) external view returns (bool) {
        return s_supportedChainSelector[chainSelector];
    }

    /// @notice Adds or updates a trusted remote factory for a given chain selector
    /// @param chainSelector The CCIP chain selector
    /// @param remoteFactory Address of the trusted factory on the remote chain
    /// @dev Reverts if chain selector is not marked as supported via setSupportedChainSelector()
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

    /// @notice Removes a trusted remote configuration for a selector
    /// @param chainSelector The CCIP chain selector to remove
    /// @dev Reverts if chain selector is not marked as supported via setSupportedChainSelector()
    function removeTrustedRemote(uint64 chainSelector) external onlyOwner {
        if (chainSelector == 0) revert MarketFactory__ChainSelectorCantbezero();
        if (!s_supportedChainSelector[chainSelector]) {
            revert MarketFactory__ChainSelectornNotSupported();
        }

        delete trustedRemoteBySelector[chainSelector];

        if (s_spokeSelectorExists[chainSelector]) {
            s_spokeSelectorExists[chainSelector] = false;
            uint256 length = s_spokeSelectors.length;
            for (uint256 i = 0; i < length; i++) {
                if (s_spokeSelectors[i] == chainSelector) {
                    s_spokeSelectors[i] = s_spokeSelectors[length - 1];
                    s_spokeSelectors.pop();
                    break;
                }
            }
        }

        emit TrustedRemoteRemoved(chainSelector);
    }

    /// @notice Returns all configured spoke selectors
    function getSpokeSelectors() external view returns (uint64[] memory selectors) {
        return s_spokeSelectors;
    }

    /// @notice Syncs hub canonical price to all spokes via CCIP
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

    /// @notice Syncs final hub resolution to all spokes via CCIP
    function broadcastResolution(uint256 marketId, Resolution outcome, string memory proofUrl) external onlyOwner {
        _broadcastResolution(marketId, outcome, proofUrl);
    }

    /// @notice Called by a registered market after local hub resolution to fan out the result to spokes
    /// @param outcome Final resolution outcome from the hub market
    /// @param proofUrl Evidence URL for the resolution
    function onHubMarketResolved(Resolution outcome, string calldata proofUrl) external {
        uint256 marketId = marketIdByAddress[msg.sender];
        if (marketId == 0 || marketById[marketId] != msg.sender) revert MarketFactory__OnlyRegisteredMarket();
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

    /// @notice Allows owner to map mirrored market IDs on spoke deployments
    function setMarketIdMapping(uint256 marketId, address market) external onlyOwner {
        if (market == address(0)) revert MarketFactory__ZeroAddress();
        marketById[marketId] = market;
        marketIdByAddress[market] = marketId;
    }



    /// @notice Removes a resolved market from the activeMarkets array (swap-and-pop)
    /// @param market Address of the market that just resolved
    /// @dev Called by a PredictionMarket contract during its resolve() flow.
    ///      Uses swap-and-pop for O(1) removal: moves the last element into the removed slot.
    
    function removeResolvedMarket(address market) external {
        uint256 marketId = marketIdByAddress[market];
         address marketAddress = marketById[marketId];

         if(marketAddress == address(0)) revert MarketFactory__MarketNotFound();
        if (marketId == 0)  revert MarketFactory__MarketNotFound();

        if (msg.sender != marketAddress && msg.sender != owner()) {
            revert MarketFactory__OnlyRegisteredMarket_Or_OwnerCanRemove();
        }

        
        uint256 index = marketToIndex[market];
        address lastMarket = activeMarkets[activeMarkets.length - 1];

        // Overwrite the removed market with the last element, then pop
        activeMarkets[index] = lastMarket;
        marketToIndex[lastMarket] = index;
        activeMarkets.pop();

        delete marketToIndex[market];
    }

    /// @inheritdoc IAny2EVMMessageReceiver
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
            emit ResolutionMessageReceived(r.marketId, Resolution(r.outcome), r.nonce);
            return;
        }

        revert MarketFactory__UnknownSyncMessageType();
    }

    /// @notice Chainlink CRE receiver hook — currently a no-op placeholder
    /// @dev Will contain factory-level settlement logic once Chainlink CRE integration is complete
    function _processReport(bytes calldata report) internal override {
      (string memory actionType, bytes memory payload) = abi.decode(report, (string, bytes));
      bytes32 actionTypeHash = keccak256(abi.encodePacked(actionType));

      if (actionTypeHash == hashed_BroadCastPrice) {
        (uint256 marketId, uint256 yesPriceE6, uint256 noPriceE6, uint256 validUntil) = abi.decode(payload, (uint256, uint256, uint256, uint256));
      _broadcastCanonicalPrice( marketId,  yesPriceE6,  noPriceE6,  validUntil);
      
      } else if (actionTypeHash == hashed_BroadCastResolution) {
        (uint256 marketId, Resolution outcome, string memory proofUrl) = abi.decode(payload, (uint256, Resolution, string));

_broadcastResolution( marketId,  outcome, proofUrl);

      } else if (actionTypeHash == hashed_CreateMarket) {

        (string memory question, uint256 closeTime, uint256 resolutionTime) = abi.decode(payload, (string, uint256, uint256));


_createMarket( question, closeTime,  resolutionTime, initailEventLiquidity);

      }else if(actionTypeHash == hashed_PriceCorrection){
        (uint256 marketId, uint256 maxSpendCollateral, uint256 minDeviationImprovementBps) = abi.decode(payload, (uint256, uint256, uint256));
 _arbitrateUnsafeMarket(marketId, maxSpendCollateral, minDeviationImprovementBps); 
      }
      
      else{
         revert MarketFactory__ActionNotRecognized();
      }


  

    }

    /// @notice Sends a CCIP message to a destination chain
    /// @param destinationChainSelector The CCIP chain selector of the destination chain
    /// @param messageType The type of message (Price or Resolution)
    /// @param payload The encoded message payload
    /// @return messageId The CCIP message ID
    /// @dev Uses ccipFeeToken (LINK) to pay for fees, requires approval
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
            extraArgs: ""
        });

        uint256 fee = IRouterClient(ccipRouter).getFee(destinationChainSelector, message);
        IERC20(ccipFeeToken).safeIncreaseAllowance(ccipRouter, fee);
        messageId = IRouterClient(ccipRouter).ccipSend(destinationChainSelector, message);
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






 function _arbitrateUnsafeMarket(uint256 marketId, uint256 maxSpendCollateral, uint256 minDeviationImprovementBps) internal{


 address marketAddress = marketById[marketId];
        if (marketAddress == address(0)) revert MarketFactory__MarketNotFound();
        if (maxSpendCollateral == 0) revert MarketFactory__ArbZeroAmount();

        PredictionMarket m = PredictionMarket(marketAddress);

        (
            PredictionMarket.DeviationBand band,
            uint256 deviationBefore,
            uint256 effectiveFeeBps,
            uint256 maxOutBps,
            bool allowYesForNo,
            bool allowNoForYes
        ) = m.getDeviationStatus();

        if (band != PredictionMarket.DeviationBand.Unsafe) revert MarketFactory__ArbNotUnsafe();
        if (!allowYesForNo && !allowNoForYes) revert MarketFactory__ArbNoDirection();

        uint256 spend = maxSpendCollateral;

        bool yesForNo = allowYesForNo;
        uint256 reserveIn = yesForNo ? m.yesReserve() : m.noReserve();
        uint256 reserveOut = yesForNo ? m.noReserve() : m.yesReserve();
        uint256 maxOut = (reserveOut * maxOutBps) / MarketConstants.FEE_PRECISION_BPS;
        if (maxOut == 0) revert MarketFactory__ArbZeroAmount();

        uint256 bestSpend =
            _capSpendForMaxOut(spend, reserveIn, reserveOut, effectiveFeeBps, maxOut);
        if (bestSpend == 0) revert MarketFactory__ArbZeroAmount();

        _ensureAllowance(collateral, marketAddress, bestSpend);
        m.mintCompleteSets(bestSpend);

        uint256 swapIn = _netOutcomeFromCollateral(bestSpend);
        if (yesForNo) {
            _ensureAllowance(IERC20(address(m.yesToken())), marketAddress, swapIn);
            m.swapYesForNo(swapIn, 0);
        } else {
            _ensureAllowance(IERC20(address(m.noToken())), marketAddress, swapIn);
            m.swapNoForYes(swapIn, 0);
        }

        (, uint256 deviationAfter,,,,) = m.getDeviationStatus();
        if (deviationBefore <= deviationAfter) revert MarketFactory__ArbInsufficientImprovement();
        if (deviationBefore - deviationAfter < minDeviationImprovementBps) {
            revert MarketFactory__ArbInsufficientImprovement();
        }

        emit UnsafeArbitrageExecuted(marketAddress, yesForNo, bestSpend, deviationBefore, deviationAfter);


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
            (uint256 out,,,) =
                AMMLib.getAmountOut(reserveIn, reserveOut, swapIn, feeBps, MarketConstants.FEE_PRECISION_BPS);
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




function withdrawCollateralFromEvents(uint256 share, uint256 _marketId) external onlyOwner{

address marketAddress = marketById[_marketId];
 if(marketAddress == address(0)) revert MarketFactory__MarketNotFound();

 PredictionMarket(marketAddress).withdrawLiquidityCollateral(share);



}



}
