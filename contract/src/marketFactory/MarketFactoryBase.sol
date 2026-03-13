// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {
    Initializable
} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {
    UUPSUpgradeable
} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {
    SafeERC20
} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {console} from "forge-std/console.sol";
import {PredictionMarket} from "../predictionMarket/PredictionMarket.sol";
import {MarketDeployer} from "./event-deployer/MarketDeployer.sol";
import {
    ReceiverTemplateUpgradeable
} from "../../script/interfaces/ReceiverTemplateUpgradeable.sol";
import {
    MarketErrors,
    Resolution,
    MarketConstants
} from "../libraries/MarketTypes.sol";
import {OutcomeToken} from "../token/OutcomeToken.sol";
import {Client} from "../ccip/Client.sol";
import {IRouterClient} from "../ccip/IRouterClient.sol";
import {IAny2EVMMessageReceiver} from "../ccip/IAny2EVMMessageReceiver.sol";

interface IPredictionMarketBridgeMapper {
    function setMarketIdMapping(uint256 marketId, address market) external;
}

interface IPredictionMarketRouterMapper {
    function setMarketAllowed(address market, bool allowed) external;
}

/// @title MarketFactoryBase
/// @notice Base storage and shared creation logic for factory modules.
abstract contract MarketFactoryBase is
    Initializable,
    ReceiverTemplateUpgradeable,
    UUPSUpgradeable,
    IAny2EVMMessageReceiver
{
    using SafeERC20 for IERC20;

    /// @notice Collateral token shared by all markets created by this factory.
    IERC20 public collateral;
    /// @notice Total number of markets created so far.
    uint256 public marketCount;
    /// @dev Amount minted into factory when `addLiquidityToFactory` is called.
    uint256 private Amount_Funding_Factory;
    /// @notice Active market list used by UI/indexers.
    address[] public activeMarkets;
    /// @notice Membership marker for active market set.
    mapping(address => bool) public isActiveMarket;
    /// @notice Markets currently awaiting manual review after inconclusive resolution.
    address[] public manualReviewMarkets;
    /// @notice Index lookup for active market array.
    mapping(address => uint256) public marketToIndex;
    /// @notice Index lookup for manual-review market array.
    mapping(address => uint256) public manualReviewMarketToIndex;
    /// @notice Membership marker for manual-review market set.
    mapping(address => bool) public isManualReviewMarket;
    /// @dev External helper that deploys market clones.
    MarketDeployer private marketDeployer;

    /// @notice CCIP router used for cross-chain messaging.
    address public ccipRouter;
    /// @notice Fee token used to pay CCIP router.
    address public ccipFeeToken;
    /// @notice True when this factory is hub; false when it is spoke.
    bool public isHubFactory;
    /// @notice Monotonic nonce for outbound sync messages.
    uint64 public ccipNonce;

    /// @dev Spoke selectors that currently have trusted remotes configured.
    uint64[] internal s_spokeSelectors;
    /// @dev True if selector already exists in `s_spokeSelectors`.
    mapping(uint64 => bool) internal s_spokeSelectorExists;
    /// @dev Global allowlist of selectors this factory can configure.
    mapping(uint64 => bool) internal s_supportedChainSelector;
    /// @notice Trusted remote factory address bytes by selector.
    mapping(uint64 => bytes) public trustedRemoteBySelector;
    /// @notice Replay guard for inbound CCIP messages.
    mapping(bytes32 => bool) public processedCcipMessages;

    /// @notice Market address by market id.
    mapping(uint256 => address) public marketById;
    /// @notice Market id by market address.
    mapping(address => uint256) public marketIdByAddress;
    /// @notice Last accepted resolution nonce per market.
    mapping(uint256 => uint64) public resolutionNonceByMarketId;
    /// @notice Local nonce tracker for direct spoke price sync calls.
    mapping(uint256 => uint64) public directPriceSyncNonceByMarketId;

    /// @dev Action hash for broadcast-price report.
    bytes32 internal hashed_BroadCastPrice;
    /// @dev Action hash for direct spoke canonical-price sync report.
    bytes32 internal hashed_SyncSpokeCanonicalPrice;
    /// @dev Action hash for broadcast-resolution report.
    bytes32 internal hashed_BroadCastResolution;
    /// @dev Action hash for create-market report.
    bytes32 internal hashed_CreateMarket;
    /// @dev Action hash for unsafe-price-correction report.
    bytes32 internal hashed_PriceCorrection;
    /// @dev Action hash for add-liquidity-to-factory report.
    bytes32 internal hashed_AddLiquidityToFactory;
    /// @dev Action hash for combined withdraw report.
    bytes32 internal hashed_WithCollatralAndFee;
    /// @dev Action hash for pending-withdraw processing report.
    bytes32 internal hashed_ProcessPendingWithdrawals;

    /// @dev Default liquidity amount used for report-driven market creation.
    uint256 internal initailEventLiquidity;

    /// @dev FIFO queue of market ids waiting for post-resolution withdrawal.
    uint256[] internal pendingWithdrawQueue;
    /// @dev Current queue head index.
    uint256 internal pendingWithdrawHead;
    /// @dev Tracks whether a market id is already queued.
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

    event MarketCreated(
        uint256 indexed marketId,
        address indexed market,
        uint256 indexed initialLiquidity
    );
    event MarketFactory__LiquidityAdded(uint256 indexed amount);
    event CcipConfigUpdated(
        address indexed router,
        address indexed feeToken,
        bool indexed isHubFactory
    );
    event ChainSelectorSupportUpdated(
        uint64 indexed chainSelector,
        bool indexed isSupported
    );
    event TrustedRemoteUpdated(
        uint64 indexed chainSelector,
        address indexed remoteFactory
    );
    event TrustedRemoteRemoved(uint64 indexed chainSelector);
    event CcipMessageSent(
        bytes32 indexed messageId,
        uint64 indexed destinationChainSelector,
        uint8 indexed messageType
    );
    event CanonicalPriceMessageReceived(
        uint256 indexed marketId,
        uint256 yesPriceE6,
        uint256 noPriceE6,
        uint64 nonce
    );
    event ResolutionMessageReceived(
        uint256 indexed marketId,
        Resolution indexed outcome,
        uint64 nonce
    );
    event PredictionMarketBridgeUpdated(address indexed bridge);
    event PredictionMarketRouterUpdated(address indexed router);
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
    event MarketMarkedForManualReview(
        uint256 indexed marketId,
        address indexed market
    );
    event ManualReviewMarketRemoved(
        uint256 indexed marketId,
        address indexed market
    );
    event NewPredictionImplementationSet(
        address indexed newPredictionMarketImplementation
    );

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

    /// @dev Initial validity window used for first spoke canonical price sync.
    uint256 internal initialCanonicalPriceWindow;
    /// @dev Initial YES/NO canonical price used for new spoke markets.
    uint256 internal initialCanonicalPriceE6;
    /// @notice Optional bridge contract updated with new market mappings.
    address public predictionMarketBridge;
    /// @notice Optional router contract updated with market allowlist entries.
    address public predictionMarketRouter;

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
    error MarketFactory__InvalidMintAmount();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initializes core factory dependencies and default operational parameters.
    /// @dev This initializer wires collateral/deployer/forwarder, precomputes report action hashes,
    /// seeds a default supported selector allowlist, and defines bootstrap canonical pricing values
    /// for newly created spoke markets.
    function initialize(
        address _collateral,
        address _forwarder,
        address _marketDeployer,
        address _initialOwner
    ) public virtual initializer {
        if (
            _collateral == address(0) ||
            _forwarder == address(0) ||
            _marketDeployer == address(0) ||
            _initialOwner == address(0)
        ) {
            revert MarketFactory__ZeroAddress();
        }

        __ReceiverTemplateUpgradeable_init(_forwarder, _initialOwner);
        collateral = IERC20(_collateral);
        marketDeployer = MarketDeployer(_marketDeployer);
        Amount_Funding_Factory = 100000e6;

        hashed_BroadCastPrice = keccak256(abi.encode("broadCastPrice"));
        hashed_SyncSpokeCanonicalPrice = keccak256(
            abi.encode("syncSpokeCanonicalPrice")
        );
        hashed_BroadCastResolution = keccak256(
            abi.encode("broadCastResolution")
        );
        hashed_CreateMarket = keccak256(abi.encode("createMarket"));
        hashed_PriceCorrection = keccak256(abi.encode("priceCorrection"));
        hashed_AddLiquidityToFactory = keccak256(
            abi.encode("addLiquidityToFactory")
        );
        hashed_WithCollatralAndFee = keccak256(
            abi.encode("WithCollatralAndFee")
        );
        hashed_ProcessPendingWithdrawals = keccak256(
            abi.encode("processPendingWithdrawals")
        );
        initailEventLiquidity = 30000e6;

        s_supportedChainSelector[10344971235874465080] = true;
        s_supportedChainSelector[3478487238524512106] = true;
        s_supportedChainSelector[11155111] = true;
        s_supportedChainSelector[80002] = true;
        s_supportedChainSelector[84532] = true;

        hashed_SyncSpokeCanonicalPrice = keccak256(
            abi.encode("syncSpokeCanonicalPrice")
        );
        initialCanonicalPriceWindow = 5 minutes;
        initialCanonicalPriceE6 = 500_000;
    }

    /// @notice Updates the deployer contract that creates new market clones.
    /// @dev Does not modify existing markets; only affects future `createMarket` calls.
    function setMarketDeployer(address _marketDeployer) external onlyOwner {
        if (_marketDeployer == address(0)) revert MarketFactory__ZeroAddress();
        marketDeployer = MarketDeployer(_marketDeployer);
    }

    /// @notice Updates the clone implementation inside the current deployer.
    /// @dev Keeps deployer address constant while changing implementation target for new clones.
    function setNewMarketDeployerImplemntation(
        address _newPredictionMarketImplementation
    ) external onlyOwner {
        if (_newPredictionMarketImplementation == address(0))
            revert MarketFactory__ZeroAddress();
        MarketDeployer(address(marketDeployer)).setImplementation(
            _newPredictionMarketImplementation
        );
        emit NewPredictionImplementationSet(_newPredictionMarketImplementation);
    }

    /// @notice UUPS authorization hook.
    /// @dev Restricts upgrades to owner and blocks accidental zero implementation address.
    function _authorizeUpgrade(
        address newImplementation
    ) internal view override onlyOwner {
        if (newImplementation == address(0)) {
            revert MarketFactory__ZeroAddress();
        }
    }

    /// @notice Mints operational collateral into the factory.
    /// @dev Intended for environments where collateral is an owner-mintable token.
    /// The minted balance is later used for actions like market funding or arbitrage.
    function addLiquidityToFactory() external onlyOwner {
        return _addLiquidityToFactory();
    }

    /// @notice Mints collateral token to a target address.
    /// @dev Intended for environments where collateral is an owner-mintable token.
    function mintCollateralTo(address to, uint256 amount) external onlyOwner {
        _mintCollateralTo(to, amount);
    }

    /// @dev Internal mint helper used by owner call and report-driven action.
    function _addLiquidityToFactory() internal {
        _mintCollateralTo(address(this), Amount_Funding_Factory);
    }

    /// @dev Internal mint helper with dynamic recipient and amount.
    function _mintCollateralTo(address to, uint256 amount) internal {
        if (to == address(0)) revert MarketFactory__ZeroAddress();
        if (amount == 0) revert MarketFactory__InvalidMintAmount();
        console.log(OutcomeToken(address(collateral)).owner(), "Owner");
        OutcomeToken(address(collateral)).mint(to, amount);
        emit MarketFactory__LiquidityAdded(amount);
    }

    /// @notice Owner entrypoint to create and seed a new market.
    /// @dev Delegates to `_createMarket`, which performs deployment, registration, and wiring.
    function createMarket(
        string memory question,
        uint256 closeTime,
        uint256 resolutionTime,
        uint256 initialLiquidity
    ) external onlyOwner returns (address market) {
        return
            _createMarket(
                question,
                closeTime,
                resolutionTime,
                initialLiquidity
            );
    }

    /// @dev Full market bootstrap routine.
    /// Detailed flow:
    /// 1) validate temporal/question/liquidity inputs,
    /// 2) deploy market clone via `marketDeployer`,
    /// 3) transfer LMSR subsidy collateral and call `initializeMarket(b)`,
    /// 4) assign new market id and both-direction mappings,
    /// 5) mirror mapping to bridge (if configured),
    /// 6) add market to active list and index map,
    /// 7) set factory as cross-chain controller,
    /// 8) if this factory is a spoke, push bootstrap canonical price/nonce,
    /// 9) transfer market ownership to factory owner,
    /// 10) emit creation event.
    function _createMarket(
        string memory question,
        uint256 closeTime,
        uint256 resolutionTime,
        uint256 initialLiquidity
    ) internal returns (address market) {
        if (
            closeTime == 0 || resolutionTime == 0 || bytes(question).length == 0
        ) {
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
                question,
                address(collateral),
                closeTime,
                resolutionTime,
                _getForwarderAddress()
            )
        );

        // LMSR: initialLiquidity is the 'b' parameter.
        // Subsidy required = b × ln(2) / 1e6 ≈ 0.693 × b
        uint256 subsidyRequired = (initialLiquidity *
            MarketConstants.LMSR_LN2_E6) / MarketConstants.PRICE_PRECISION;
        collateral.safeTransfer(address(m), subsidyRequired);
        m.initializeMarket(initialLiquidity);

        marketCount++;
        marketById[marketCount] = address(m);
        marketIdByAddress[address(m)] = marketCount;
        m.setMarketId(marketCount);

        activeMarkets.push(address(m));
        marketToIndex[address(m)] = activeMarkets.length - 1;
        isActiveMarket[address(m)] = true;
        m.setCrossChainController(address(this));
        uint64 nonce = ++ccipNonce;

        if (!isHubFactory) {
            m.syncCanonicalPriceFromHub(
                initialCanonicalPriceE6,
                initialCanonicalPriceE6,
                block.timestamp + initialCanonicalPriceWindow,
                nonce
            );
        }

        if (predictionMarketBridge != address(0)) {
            IPredictionMarketBridgeMapper(predictionMarketBridge)
                .setMarketIdMapping(marketCount, address(m));
        }
        if (predictionMarketRouter != address(0)) {
            IPredictionMarketRouterMapper(predictionMarketRouter)
                .setMarketAllowed(address(m), true);
            m.setRiskExempt(predictionMarketRouter, true);
        }

        m.transferOwnership(owner());

        emit MarketCreated(marketCount, address(m), initialLiquidity);

        return address(m);
    }
}
