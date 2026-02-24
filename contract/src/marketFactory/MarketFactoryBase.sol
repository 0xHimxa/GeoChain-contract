// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {console} from "forge-std/console.sol";
import {PredictionMarket} from "../predictionMarket/PredictionMarket.sol";
import {MarketDeployer} from "./event-deployer/MarketDeployer.sol";
import {ReceiverTemplateUpgradeable} from "../../script/interfaces/ReceiverTemplateUpgradeable.sol";
import {MarketErrors, Resolution, MarketConstants} from "../libraries/MarketTypes.sol";
import {OutcomeToken} from "../token/OutcomeToken.sol";
import {Client} from "../ccip/Client.sol";
import {IRouterClient} from "../ccip/IRouterClient.sol";
import {IAny2EVMMessageReceiver} from "../ccip/IAny2EVMMessageReceiver.sol";

interface IPredictionMarketBridgeMapper {
    function setMarketIdMapping(uint256 marketId, address market) external;
}

abstract contract MarketFactoryBase is
    Initializable,
    ReceiverTemplateUpgradeable,
    UUPSUpgradeable,
    IAny2EVMMessageReceiver
{
    using SafeERC20 for IERC20;

    IERC20 public collateral;
    uint256 public marketCount;
    uint256 private Amount_Funding_Factory;
    address[] public activeMarkets;
    mapping(address => uint256) public marketToIndex;
    MarketDeployer private marketDeployer;

    address public ccipRouter;
    address public ccipFeeToken;
    bool public isHubFactory;
    uint64 public ccipNonce;

    uint64[] internal s_spokeSelectors;
    mapping(uint64 => bool) internal s_spokeSelectorExists;
    mapping(uint64 => bool) internal s_supportedChainSelector;
    mapping(uint64 => bytes) public trustedRemoteBySelector;
    mapping(bytes32 => bool) public processedCcipMessages;

    mapping(uint256 => address) public marketById;
    mapping(address => uint256) public marketIdByAddress;
    mapping(uint256 => uint64) public resolutionNonceByMarketId;
    mapping(uint256 => uint64) public directPriceSyncNonceByMarketId;

    bytes32 internal hashed_BroadCastPrice;
    bytes32 internal hashed_SyncSpokeCanonicalPrice;
    bytes32 internal hashed_BroadCastResolution;
    bytes32 internal hashed_CreateMarket;
    bytes32 internal hashed_PriceCorrection;
    bytes32 internal hashed_AddLiquidityToFactory;
    bytes32 internal hashed_WithCollatralAndFee;
    bytes32 internal hashed_ProcessPendingWithdrawals;

    uint256 internal initailEventLiquidity;

    uint256[] internal pendingWithdrawQueue;
    uint256 internal pendingWithdrawHead;
    mapping(uint256 => bool) internal isPendingWithdrawQueued;

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

    event MarketCreated(uint256 indexed marketId, address indexed market, uint256 indexed initialLiquidity);
    event MarketFactory__LiquidityAdded(uint256 indexed amount);
    event CcipConfigUpdated(address indexed router, address indexed feeToken, bool indexed isHubFactory);
    event ChainSelectorSupportUpdated(uint64 indexed chainSelector, bool indexed isSupported);
    event TrustedRemoteUpdated(uint64 indexed chainSelector, address indexed remoteFactory);
    event TrustedRemoteRemoved(uint64 indexed chainSelector);
    event CcipMessageSent(bytes32 indexed messageId, uint64 indexed destinationChainSelector, uint8 indexed messageType);
    event CanonicalPriceMessageReceived(uint256 indexed marketId, uint256 yesPriceE6, uint256 noPriceE6, uint64 nonce);
    event ResolutionMessageReceived(uint256 indexed marketId, Resolution indexed outcome, uint64 nonce);
    event PredictionMarketBridgeUpdated(address indexed bridge);
    event UnsafeArbitrageExecuted(
        address indexed market,
        bool indexed yesForNo,
        uint256 collateralSpent,
        uint256 deviationBeforeBps,
        uint256 deviationAfterBps
    );
    event WithdrawEnqueued(uint256 indexed marketId);
    event WithdrawDequeued(uint256 indexed marketId);
    event WithdrawProcessed(uint256 indexed marketId);
    event WithdrawRequeued(uint256 indexed marketId);
    event WithdrawSkippedNoShares(uint256 indexed marketId);
    event WithdrawSkippedNotResolved(uint256 indexed marketId);
    event MarkertFactor_ReslovedEventReomved(uint256 indexed marketId);
    event NewPredictionImplementationSet(address indexed newPredictionMarketImplementation);

    struct UnsafeArbContext {
        address marketAddress;
        PredictionMarket market;
        uint256 deviationBefore;
        uint256 effectiveFeeBps;
        uint256 maxOutBps;
        bool yesForNo;
        uint256 reserveIn;
        uint256 reserveOut;
        uint256 maxOut;
        uint256 bestSpend;
        uint256 swapIn;
        uint256 deviationAfter;
    }

    uint256 internal initialCanonicalPriceWindow;
    uint256 internal initialCanonicalPriceE6;
    address public predictionMarketBridge;

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
    error MarketFactory__ArbInsufficientImprovement();
    error MarketFactory__OnlyRegisteredMarket_Or_OwnerCanRemove();
    error MarketFactory__NotSpokeFactory();
    error MarketFactory__InvalidMaxBatch();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address _collateral, address _forwarder, address _marketDeployer, address _initialOwner)
        public
        virtual
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

        hashed_BroadCastPrice = keccak256(abi.encode("broadCastPrice"));
        hashed_SyncSpokeCanonicalPrice = keccak256(abi.encode("syncSpokeCanonicalPrice"));
        hashed_BroadCastResolution = keccak256(abi.encode("broadCastResolution"));
        hashed_CreateMarket = keccak256(abi.encode("createMarket"));
        hashed_PriceCorrection = keccak256(abi.encode("priceCorrection"));
        hashed_AddLiquidityToFactory = keccak256(abi.encode("addLiquidityToFactory"));
        hashed_WithCollatralAndFee = keccak256(abi.encode("WithCollatralAndFee"));
        hashed_ProcessPendingWithdrawals = keccak256(abi.encode("processPendingWithdrawals"));
        initailEventLiquidity = 30000e6;

        s_supportedChainSelector[10344971235874465080] = true;
        s_supportedChainSelector[3478487238524512106] = true;
        s_supportedChainSelector[11155111] = true;
        s_supportedChainSelector[80002] = true;
        s_supportedChainSelector[84532] = true;

        hashed_SyncSpokeCanonicalPrice = keccak256(abi.encode("syncSpokeCanonicalPrice"));
        initialCanonicalPriceWindow = 5 minutes;
        initialCanonicalPriceE6 = 500_000;
    }

    function setMarketDeployer(address _marketDeployer) external onlyOwner {
        if (_marketDeployer == address(0)) revert MarketFactory__ZeroAddress();
        marketDeployer = MarketDeployer(_marketDeployer);
    }

    function setNewMarketDeployerImplemntation(address _newPredictionMarketImplementation) external onlyOwner {
        if (_newPredictionMarketImplementation == address(0)) revert MarketFactory__ZeroAddress();
        MarketDeployer(address(marketDeployer)).setImplementation(_newPredictionMarketImplementation);
        emit NewPredictionImplementationSet(_newPredictionMarketImplementation);
    }

    function _authorizeUpgrade(address newImplementation) internal view override onlyOwner {
        if (newImplementation == address(0)) {
            revert MarketFactory__ZeroAddress();
        }
    }

    function addLiquidityToFactory() external onlyOwner {
        return _addLiquidityToFactory();
    }

    function _addLiquidityToFactory() internal {
        console.log(OutcomeToken(address(collateral)).owner(), "Owner");
        OutcomeToken(address(collateral)).mint(address(this), Amount_Funding_Factory);
        emit MarketFactory__LiquidityAdded(Amount_Funding_Factory);
    }

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

        if (closeTime > resolutionTime) {
            revert MarketErrors.PredictionMarket__CloseTimeGreaterThanResolutionTime();
        }

        if (initialLiquidity == 0) revert MarketFactory__ZeroLiquidity();
        if (address(marketDeployer) == address(0)) {
            revert MarketFactory__ZeroAddress();
        }

        PredictionMarket m = PredictionMarket(
            marketDeployer.deployPredictionMarket(
                question, address(collateral), closeTime, resolutionTime, _getForwarderAddress()
            )
        );

        collateral.safeTransfer(address(m), initialLiquidity);
        m.seedLiquidity(initialLiquidity);

        marketCount++;
        marketById[marketCount] = address(m);
        marketIdByAddress[address(m)] = marketCount;
        m.setMarketId(marketCount);
        if (predictionMarketBridge != address(0)) {
            IPredictionMarketBridgeMapper(predictionMarketBridge).setMarketIdMapping(marketCount, address(m));
        }

        activeMarkets.push(address(m));
        marketToIndex[address(m)] = activeMarkets.length - 1;
        m.setCrossChainController(address(this));
        uint64 nonce = ++ccipNonce;

        if (!isHubFactory) {
            m.syncCanonicalPriceFromHub(
                initialCanonicalPriceE6, initialCanonicalPriceE6, block.timestamp + initialCanonicalPriceWindow, nonce
            );
        }

        m.transferOwnership(owner());

        emit MarketCreated(marketCount, address(m), initialLiquidity);

        return address(m);
    }
}
