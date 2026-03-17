// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Test, console} from "forge-std/Test.sol";
import {MarketFactory} from "../../src/marketFactory/MarketFactory.sol";
import {MarketFactoryBase} from "../../src/marketFactory/MarketFactoryBase.sol";
import {OutcomeToken} from "../../src/token/OutcomeToken.sol";
import {MarketDeployer} from "../../src/marketFactory/event-deployer/MarketDeployer.sol";
import {PredictionMarket} from "../../src/predictionMarket/PredictionMarket.sol";
import {DeployMarketFactory} from "../../script/deployMarketFactory.s.sol";
import {MarketErrors, Resolution} from "../../src/libraries/MarketTypes.sol";
import {Client} from "../../src/ccip/Client.sol";
import {IRouterClient} from "../../src/ccip/IRouterClient.sol";

contract MockRouter is IRouterClient {
    uint256 public fee;
    uint256 public sentCount;
    uint64 public lastDestination;
    bytes public lastReceiver;

    function setFee(uint256 _fee) external {
        fee = _fee;
    }

    function getFee(uint64, Client.EVM2AnyMessage calldata) external view returns (uint256) {
        return fee;
    }

    function ccipSend(uint64 destinationChainSelector, Client.EVM2AnyMessage calldata message)
        external
        payable
        returns (bytes32 messageId)
    {
        sentCount++;
        lastDestination = destinationChainSelector;
        lastReceiver = message.receiver;
        messageId = keccak256(abi.encode(destinationChainSelector, sentCount));
    }
}

contract MockPredictionRouter {
    mapping(address => bool) public allowedMarkets;
    uint256 public setCalls;
    address public lastMarket;
    bool public lastAllowed;

    function setMarketAllowed(address market, bool allowed) external {
        allowedMarkets[market] = allowed;
        setCalls++;
        lastMarket = market;
        lastAllowed = allowed;
    }
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

contract MarketFactoryTest is Test {
    event MarketCreated(uint256 indexed marketId, address indexed market, uint256 indexed initialLiquidity);
    event MarketFactory__LiquidityAdded(uint256 indexed amount);
    event CcipConfigUpdated(address indexed router, address indexed feeToken, bool indexed isHubFactory);
    event ChainSelectorSupportUpdated(uint64 indexed chainSelector, bool indexed isSupported);
    event TrustedRemoteUpdated(uint64 indexed chainSelector, address indexed remoteFactory);
    event TrustedRemoteRemoved(uint64 indexed chainSelector);
    event CcipMessageSent(bytes32 indexed messageId, uint64 indexed destinationChainSelector, uint8 indexed messageType);
    event CanonicalPriceMessageReceived(uint256 indexed marketId, uint256 yesPriceE6, uint256 noPriceE6, uint64 nonce);
    event ResolutionMessageReceived(uint256 indexed marketId, Resolution indexed outcome, uint64 nonce);

    OutcomeToken collateral;
    MarketFactory market;
    MockRouter router;
    MockPredictionRouter predictionRouter;
    OutcomeToken feeToken;
    address forwarder = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8;
    address marketOwner = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266;
    uint256 initialFunding = 1000000e6;
    uint256 initialLiquidity = 10000e6;

    uint64 sepoChainSelector = 11155111;
    uint64 polyChainSelector = 80002;
    uint64 baseChainSelector = 84532;



    function setUp() external {
        DeployMarketFactory deployer = new DeployMarketFactory();
        (address proxyAddress,, address collateralAddress) = deployer.run();
        collateral = OutcomeToken(collateralAddress);
        market = MarketFactory(proxyAddress);
        router = new MockRouter();
        predictionRouter = new MockPredictionRouter();
        feeToken = new OutcomeToken("FEE", "FEE", address(this));
    }

    function testCollateralAndForwarderAddress() external {
        address MarketCollateralAddress = address(market.collateral());
        assertEq(address(collateral), MarketCollateralAddress);
        assertEq(forwarder, market.getForwarderAddress());
    }

    function testCreateMarketRevertInvalidPram() external {
        string memory question = "";
        uint256 closeTime = 0;
        uint256 resolutionTime = 0;

        vm.startPrank(marketOwner);
        vm.expectRevert(MarketErrors.PredictionMarket__InvalidArguments_PassedInConstructor.selector);

        market.createMarket(question, closeTime, resolutionTime, 0);

        vm.expectRevert(MarketErrors.PredictionMarket__CloseTimeGreaterThanResolutionTime.selector);

        market.createMarket("will rain fall", block.timestamp + 1000, block.timestamp, 0);

        vm.expectRevert(MarketErrors.PredictionMarket__InvalidArguments_PassedInConstructor.selector);

        market.createMarket("", block.timestamp + 1000, block.timestamp + 1000, initialLiquidity);
        vm.expectRevert(MarketFactoryBase.MarketFactory__ZeroLiquidity.selector);

        market.createMarket("will rain fall", block.timestamp + 1000, block.timestamp + 10001, 0);

        vm.stopPrank();
    }

    function testCreateMarketPass() external {
        string memory question = "will rain fall";
        uint256 closeTime = block.timestamp + 1000;
        uint256 resolutionTime = block.timestamp + 20000;
        address eventCreatedAddress;

        vm.startPrank(marketOwner);
        vm.expectEmit(true, false, true, true);
        emit MarketCreated(1, address(0), initialLiquidity);

        eventCreatedAddress = market.createMarket(question, closeTime, resolutionTime, initialLiquidity);

        vm.stopPrank();
        assertEq(market.marketCount(), 1);
        assertEq(market.marketById(1), eventCreatedAddress);
        assertEq(market.marketIdByAddress(eventCreatedAddress), 1);
        assertEq(market.marketToIndex(eventCreatedAddress), 0);
        assertEq(market.activeMarkets(0), eventCreatedAddress);
    }

    function testForwarderOnReportCanCreateMarket() external {
        bytes memory payload = abi.encode("from-report", block.timestamp + 1000, block.timestamp + 2000);
        bytes memory report = abi.encode("createMarket", payload);

        vm.prank(forwarder);
        market.onReport("", report);

        assertEq(market.marketCount(), 1);
        address created = market.marketById(1);
        assertEq(created != address(0), true);
        assertEq(PredictionMarket(created).owner(), marketOwner);
    }

    function testForwarderOnReportSyncSpokeCanonicalPricePass() external {
        vm.prank(marketOwner);
        address created = market.createMarket("q", block.timestamp + 100, block.timestamp + 200, initialLiquidity);

        bytes memory payload = abi.encode(uint256(1), uint256(530_000), uint256(470_000), uint256(block.timestamp + 1 days));
        bytes memory report = abi.encode("syncSpokeCanonicalPrice", payload);

        vm.prank(forwarder);
        vm.expectEmit(true, true, false, true);
        emit CanonicalPriceMessageReceived(1, 530_000, 470_000, 2);
        market.onReport("", report);

        PredictionMarket prediction = PredictionMarket(created);
        assertEq(prediction.canonicalYesPriceE6(), 530_000);
        assertEq(prediction.canonicalNoPriceE6(), 470_000);
        assertEq(prediction.canonicalPriceNonce(), 2);
        assertEq(market.directPriceSyncNonceByMarketId(1), 2);

        vm.prank(forwarder);
        market.onReport("", report);
        assertEq(prediction.canonicalPriceNonce(), 3);
        assertEq(market.directPriceSyncNonceByMarketId(1), 3);
    }

    function testForwarderOnReportSyncSpokeCanonicalPriceRevertWhenHubFactory() external {
        vm.prank(marketOwner);
        market.createMarket("q", block.timestamp + 100, block.timestamp + 200, initialLiquidity);

        vm.prank(marketOwner);
        market.setCcipConfig(address(router), address(feeToken), true);

        bytes memory payload = abi.encode(uint256(1), uint256(510_000), uint256(490_000), uint256(block.timestamp + 1 days));
        bytes memory report = abi.encode("syncSpokeCanonicalPrice", payload);

        vm.prank(forwarder);
        vm.expectRevert(MarketFactoryBase.MarketFactory__NotSpokeFactory.selector);
        market.onReport("", report);
    }

    function testArbitrateUnsafeMarketImprovesDeviation() external {
        vm.startPrank(marketOwner);
        address created = market.createMarket("arb market", block.timestamp + 1000, block.timestamp + 20000, initialLiquidity);
        vm.stopPrank();

        vm.prank(address(market));
        PredictionMarket(created).syncCanonicalPriceFromHub(460_000, 540_000, block.timestamp + 1 days, 2);

        vm.prank(marketOwner);
        market.arbitrateUnsafeMarket(1, 1000e6, 1);

        (, uint256 deviationAfter,,,,) = PredictionMarket(created).getDeviationStatus();
        // LMSR mode: arbitrage is off-chain; on-chain call only emits and does not change deviation.
        assertEq(deviationAfter, 400);
    }

    function testCreateMarketTracksIncrementingUintIdsAndIndexes() external {
        vm.startPrank(marketOwner);
        address firstMarket = market.createMarket("first market", block.timestamp + 1 hours, block.timestamp + 2 hours, initialLiquidity);
        address secondMarket =
            market.createMarket("second market", block.timestamp + 3 hours, block.timestamp + 4 hours, initialLiquidity);
        vm.stopPrank();

        assertEq(market.marketCount(), 2);
        assertEq(market.marketById(1), firstMarket);
        assertEq(market.marketById(2), secondMarket);
        assertEq(market.marketIdByAddress(firstMarket), 1);
        assertEq(market.marketIdByAddress(secondMarket), 2);
        assertEq(market.marketToIndex(firstMarket), 0);
        assertEq(market.marketToIndex(secondMarket), 1);
    }

    function testCreateMarketSetsMarketAllowedOnPredictionRouter() external {
        vm.prank(marketOwner);
        market.setPredictionMarketRouter(address(predictionRouter));

        vm.prank(marketOwner);
        address created = market.createMarket("router allowlist", block.timestamp + 1 hours, block.timestamp + 2 hours, initialLiquidity);

        assertEq(predictionRouter.allowedMarkets(created), true);
        assertEq(predictionRouter.setCalls(), 1);
        assertEq(predictionRouter.lastMarket(), created);
        assertEq(predictionRouter.lastAllowed(), true);
    }

    function testRemoveResolvedMarketSwapAndPopUpdatesUintIndexes() external {
        vm.startPrank(marketOwner);
        address firstMarket = market.createMarket("first market", block.timestamp + 1 hours, block.timestamp + 2 hours, initialLiquidity);
        address secondMarket =
            market.createMarket("second market", block.timestamp + 3 hours, block.timestamp + 4 hours, initialLiquidity);
        market.removeResolvedMarket(firstMarket);
        vm.stopPrank();

        assertEq(market.activeMarkets(0), secondMarket);
        assertEq(market.marketToIndex(secondMarket), 0);

        // how is this possible?
        assertEq(market.marketToIndex(firstMarket), 0);

        vm.expectRevert();
        market.activeMarkets(1);
    }

    function testSetTrustedRemoteRevert() external {
        vm.startPrank(marketOwner);
        vm.expectRevert(MarketFactoryBase.MarketFactory__ZeroAddress.selector);
        market.setTrustedRemote(33155, address(0));

        vm.expectRevert(MarketFactoryBase.MarketFactory__ChainSelectorCantBeZero.selector);
        market.setTrustedRemote(0, address(100));

        vm.expectRevert(MarketFactoryBase.MarketFactory__ChainSelectorNotSupported.selector);
        market.setTrustedRemote(1, address(100));
        vm.stopPrank();
    }

    function testSetSupportedChainSelectorRevertZeroSelector() external {
        vm.prank(marketOwner);
        vm.expectRevert(MarketFactoryBase.MarketFactory__ChainSelectorCantBeZero.selector);
        market.setSupportedChainSelector(0, true);
    }

    function testSetSupportedChainSelectorPassAllowsNewSelectorForTrustedRemote() external {
        uint64 arbitrumSepoliaSelector = 421614;

        vm.startPrank(marketOwner);
        vm.expectEmit(true, true, false, false);
        emit ChainSelectorSupportUpdated(arbitrumSepoliaSelector, true);
        market.setSupportedChainSelector(arbitrumSepoliaSelector, true);
        market.setTrustedRemote(arbitrumSepoliaSelector, address(777));
        vm.stopPrank();

        assertEq(market.isSupportedChainSelector(arbitrumSepoliaSelector), true);
        bytes memory remote = market.trustedRemoteBySelector(arbitrumSepoliaSelector);
        assertEq(abi.decode(remote, (address)), address(777));
    }

    function testSetTrustedRemotePass() external {
        vm.startPrank(marketOwner);
        vm.expectEmit(true, true, false, false);
        emit TrustedRemoteUpdated(sepoChainSelector, address(100));

        market.setTrustedRemote(sepoChainSelector, address(100));
        vm.stopPrank();

        bytes memory remote = market.trustedRemoteBySelector(sepoChainSelector);
        assertEq(abi.decode(remote, (address)), address(100));
    }

    function testSetTrustedRemoteDoesNotDuplicateSelectorsArrayLength() external {
        vm.startPrank(marketOwner);
        market.setTrustedRemote(sepoChainSelector, address(100));
        market.setTrustedRemote(sepoChainSelector, address(101));
        vm.stopPrank();

        uint64[] memory selectors = market.getSpokeSelectors();
        assertEq(selectors.length, 1);
        assertEq(selectors[0], sepoChainSelector);

        bytes memory remote = market.trustedRemoteBySelector(sepoChainSelector);
        assertEq(abi.decode(remote, (address)), address(101));
    }

    function testSetTrustedRemoteSupportsAllAllowedChainSelectors() external {
        vm.startPrank(marketOwner);
        market.setTrustedRemote(sepoChainSelector, address(100));
        market.setTrustedRemote(polyChainSelector, address(200));
        market.setTrustedRemote(baseChainSelector, address(300));
        vm.stopPrank();

        uint64[] memory selectors = market.getSpokeSelectors();
        assertEq(selectors.length, 3);
    }

    function testRemoveTrustedRemoteRevert() external {
        vm.startPrank(marketOwner);
        vm.expectRevert(MarketFactoryBase.MarketFactory__ChainSelectorCantBeZero.selector);
        market.removeTrustedRemote(0);

        vm.expectRevert(MarketFactoryBase.MarketFactory__ChainSelectorNotSupported.selector);
        market.removeTrustedRemote(33137);
        vm.stopPrank();
    }

    function testRemoveTrustedRemoteRevertWhenSelectorSupportDisabled() external {
        vm.startPrank(marketOwner);
        market.setSupportedChainSelector(sepoChainSelector, false);
        vm.expectRevert(MarketFactoryBase.MarketFactory__ChainSelectorNotSupported.selector);
        market.removeTrustedRemote(sepoChainSelector);
        vm.stopPrank();
    }

    function testRemoveTrustedRemotePass() external {
        vm.startPrank(marketOwner);
        market.setTrustedRemote(sepoChainSelector, address(100));

        vm.expectEmit(true, true, false, false);
        emit TrustedRemoteRemoved(sepoChainSelector);

        market.removeTrustedRemote(sepoChainSelector);
        vm.stopPrank();

        bytes memory remote = market.trustedRemoteBySelector(sepoChainSelector);
        assertEq(remote.length, 0);

        uint64[] memory selectors = market.getSpokeSelectors();
        assertEq(selectors.length, 0);
    }

    function testAddLiquidityToFactoryMintsFixedUintAmount() external {
        uint256 beforeBalance = collateral.balanceOf(address(market));

        vm.prank(marketOwner);
        vm.expectEmit(true, false, false, true);
        emit MarketFactory__LiquidityAdded(100000e6);
        market.addLiquidityToFactory();

        uint256 afterBalance = collateral.balanceOf(address(market));
        assertEq(afterBalance - beforeBalance, 100000e6);
    }

    function testSetMarketDeployerRevertZeroAddress() external {
        vm.prank(marketOwner);
        vm.expectRevert(MarketFactoryBase.MarketFactory__ZeroAddress.selector);
        market.setMarketDeployer(address(0));
    }

    function testSetMarketDeployerPass() external {
        PredictionMarket implementation = new PredictionMarket();
        MarketDeployer newDeployer = new MarketDeployer(address(implementation),address(this));
        vm.prank(marketOwner);
        market.setMarketDeployer(address(newDeployer));
    }

    function testSetCcipConfigRevertZeroAddress() external {
        vm.prank(marketOwner);
        vm.expectRevert(MarketFactoryBase.MarketFactory__ZeroAddress.selector);
        market.setCcipConfig(address(0), address(feeToken), true);

        vm.prank(marketOwner);
        vm.expectRevert(MarketFactoryBase.MarketFactory__ZeroAddress.selector);
        market.setCcipConfig(address(router), address(0), true);
    }

    function testSetCcipConfigPass() external {
        vm.prank(marketOwner);
        vm.expectEmit(true, true, true, true);
        emit CcipConfigUpdated(address(router), address(feeToken), true);
        market.setCcipConfig(address(router), address(feeToken), true);

        assertEq(market.ccipRouter(), address(router));
        assertEq(market.ccipFeeToken(), address(feeToken));
        assertEq(market.isHubFactory(), true);
    }

    function testSetMarketIdMappingRevertZeroAddress() external {
        vm.prank(marketOwner);
        vm.expectRevert(MarketFactoryBase.MarketFactory__ZeroAddress.selector);
        market.setMarketIdMapping(99, address(0));
    }

    function testSetMarketIdMappingPass() external {
        address mirroredMarket = address(0xA11CE);
        vm.prank(marketOwner);
        market.setMarketIdMapping(99, mirroredMarket);

        assertEq(market.marketById(99), mirroredMarket);
        assertEq(market.marketIdByAddress(mirroredMarket), 99);
    }

    function testBroadcastCanonicalPriceRevertNotHubFactory() external {
        vm.prank(marketOwner);
        vm.expectRevert(MarketFactoryBase.MarketFactory__NotHubFactory.selector);
        market.broadcastCanonicalPrice(1, 500_000, 500_000, block.timestamp + 1 days);
    }

    function testBroadcastCanonicalPriceRevertMarketNotFound() external {
        vm.prank(marketOwner);
        market.setCcipConfig(address(router), address(feeToken), true);

        vm.prank(marketOwner);
        vm.expectRevert(MarketFactoryBase.MarketFactory__MarketNotFound.selector);
        market.broadcastCanonicalPrice(1, 500_000, 500_000, block.timestamp + 1 days);
    }

    function testBroadcastCanonicalPricePassWithZeroSelectorsDoesNotSendMessages() external {
        vm.prank(marketOwner);
        market.createMarket("q", block.timestamp + 100, block.timestamp + 200, initialLiquidity);

        vm.startPrank(marketOwner);
        market.setCcipConfig(address(router), address(feeToken), true);
        market.broadcastCanonicalPrice(1, 500_000, 500_000, block.timestamp + 1 days);
        vm.stopPrank();

        assertEq(market.ccipNonce(), 2);
        assertEq(router.sentCount(), 0);
    }

    function testBroadcastCanonicalPricePassSendsToAllConfiguredSelectors() external {
        vm.prank(marketOwner);
        market.createMarket("q", block.timestamp + 100, block.timestamp + 200, initialLiquidity);

        vm.startPrank(marketOwner);
        market.setCcipConfig(address(router), address(feeToken), true);
        market.setTrustedRemote(sepoChainSelector, address(100));
        market.setTrustedRemote(polyChainSelector, address(200));
        router.setFee(0);
        market.broadcastCanonicalPrice(1, 600_000, 400_000, block.timestamp + 1 days);
        vm.stopPrank();

        assertEq(market.ccipNonce(), 2);
        assertEq(router.sentCount(), 2);
    }

    function testBroadcastResolutionRevertInvalidOutcome() external {
        vm.prank(marketOwner);
        market.createMarket("q", block.timestamp + 100, block.timestamp + 200, initialLiquidity);

        vm.startPrank(marketOwner);
        market.setCcipConfig(address(router), address(feeToken), true);
        market.setTrustedRemote(sepoChainSelector, address(100));
        vm.expectRevert(MarketFactoryBase.MarketFactory__InvalidResolutionOutcome.selector);
        market.broadcastResolution(1, Resolution.Unset, "ipfs://proof");
        vm.stopPrank();
    }

    function testBroadcastResolutionPassIncrementsUintNonce() external {
        vm.prank(marketOwner);
        market.createMarket("q", block.timestamp + 100, block.timestamp + 200, initialLiquidity);

        vm.startPrank(marketOwner);
        market.setCcipConfig(address(router), address(feeToken), true);
        market.setTrustedRemote(sepoChainSelector, address(100));
        market.setTrustedRemote(polyChainSelector, address(200));
        market.broadcastResolution(1, Resolution.Yes, "ipfs://proof");
        vm.stopPrank();

        assertEq(market.ccipNonce(), 2);
        assertEq(router.sentCount(), 2);
    }

    function testCcipReceiveRevertInvalidRemoteSenderWhenRouterMismatch() external {
        vm.prank(marketOwner);
        market.setCcipConfig(address(router), address(feeToken), false);

        Client.EVMTokenAmount[] memory emptyAmounts = new Client.EVMTokenAmount[](0);
        Client.Any2EVMMessage memory message = Client.Any2EVMMessage({
            messageId: bytes32(uint256(1)),
            sourceChainSelector: sepoChainSelector,
            sender: abi.encode(address(100)),
            data: abi.encode(uint8(0), bytes("")),
            destTokenAmounts: emptyAmounts
        });

        vm.expectRevert(MarketFactoryBase.MarketFactory__InvalidRemoteSender.selector);
        market.ccipReceive(message);
    }

    function testCcipReceiveRevertSourceChainNotAllowed() external {
        vm.prank(marketOwner);
        market.setCcipConfig(address(router), address(feeToken), false);

        Client.EVMTokenAmount[] memory emptyAmounts = new Client.EVMTokenAmount[](0);
        Client.Any2EVMMessage memory message = Client.Any2EVMMessage({
            messageId: bytes32(uint256(2)),
            sourceChainSelector: sepoChainSelector,
            sender: abi.encode(address(100)),
            data: abi.encode(uint8(0), bytes("")),
            destTokenAmounts: emptyAmounts
        });

        vm.prank(address(router));
        vm.expectRevert(MarketFactoryBase.MarketFactory__SourceChainNotAllowed.selector);
        market.ccipReceive(message);
    }

    function testCcipReceiveRevertInvalidRemoteSenderWhenSenderBytesMismatch() external {
        vm.startPrank(marketOwner);
        market.setCcipConfig(address(router), address(feeToken), false);
        market.setTrustedRemote(sepoChainSelector, address(999));
        vm.stopPrank();

        Client.EVMTokenAmount[] memory emptyAmounts = new Client.EVMTokenAmount[](0);
        Client.Any2EVMMessage memory message = Client.Any2EVMMessage({
            messageId: bytes32(uint256(3)),
            sourceChainSelector: sepoChainSelector,
            sender: abi.encode(address(100)),
            data: abi.encode(uint8(0), bytes("")),
            destTokenAmounts: emptyAmounts
        });

        vm.prank(address(router));
        vm.expectRevert(MarketFactoryBase.MarketFactory__InvalidRemoteSender.selector);
        market.ccipReceive(message);
    }

    function testCcipReceiveRevertUnknownSyncMessageType() external {
        vm.startPrank(marketOwner);
        market.setCcipConfig(address(router), address(feeToken), false);
        market.setTrustedRemote(sepoChainSelector, address(100));
        vm.stopPrank();

        Client.EVMTokenAmount[] memory emptyAmounts = new Client.EVMTokenAmount[](0);
        Client.Any2EVMMessage memory message = Client.Any2EVMMessage({
            messageId: bytes32(uint256(4)),
            sourceChainSelector: sepoChainSelector,
            sender: abi.encode(address(100)),
            data: abi.encode(uint8(99), bytes("payload")),
            destTokenAmounts: emptyAmounts
        });

        vm.prank(address(router));
        vm.expectRevert(MarketFactoryBase.MarketFactory__UnknownSyncMessageType.selector);
        market.ccipReceive(message);
    }

    function testCcipReceiveRevertMessageAlreadyProcessed() external {
        vm.prank(marketOwner);
        address createdMarket = market.createMarket("q", block.timestamp + 100, block.timestamp + 200, initialLiquidity);

        vm.startPrank(marketOwner);
        market.setCcipConfig(address(router), address(feeToken), false);
        market.setTrustedRemote(sepoChainSelector, address(100));
        market.setMarketIdMapping(1, createdMarket);
        vm.stopPrank();

        CanonicalPriceSync memory payload = CanonicalPriceSync({
            marketId: 1,
            yesPriceE6: 510_000,
            noPriceE6: 490_000,
            validUntil: block.timestamp + 1 days,
            nonce: 2
        });
        Client.EVMTokenAmount[] memory emptyAmounts = new Client.EVMTokenAmount[](0);
        Client.Any2EVMMessage memory message = Client.Any2EVMMessage({
            messageId: bytes32(uint256(5)),
            sourceChainSelector: sepoChainSelector,
            sender: abi.encode(address(100)),
            data: abi.encode(uint8(0), abi.encode(payload)),
            destTokenAmounts: emptyAmounts
        });

        vm.prank(address(router));
        market.ccipReceive(message);

        vm.prank(address(router));
        vm.expectRevert(MarketFactoryBase.MarketFactory__MessageAlreadyProcessed.selector);
        market.ccipReceive(message);
    }

    function testCcipReceivePriceRevertMarketNotFound() external {
        vm.startPrank(marketOwner);
        market.setCcipConfig(address(router), address(feeToken), false);
        market.setTrustedRemote(sepoChainSelector, address(100));
        vm.stopPrank();

        CanonicalPriceSync memory payload = CanonicalPriceSync({
            marketId: 77,
            yesPriceE6: 600_000,
            noPriceE6: 400_000,
            validUntil: block.timestamp + 1 days,
            nonce: 1
        });

        Client.EVMTokenAmount[] memory emptyAmounts = new Client.EVMTokenAmount[](0);
        Client.Any2EVMMessage memory message = Client.Any2EVMMessage({
            messageId: bytes32(uint256(6)),
            sourceChainSelector: sepoChainSelector,
            sender: abi.encode(address(100)),
            data: abi.encode(uint8(0), abi.encode(payload)),
            destTokenAmounts: emptyAmounts
        });

        vm.prank(address(router));
        vm.expectRevert(MarketFactoryBase.MarketFactory__MarketNotFound.selector);
        market.ccipReceive(message);
    }

    function testCcipReceivePricePassUpdatesCanonicalUintValues() external {
        vm.prank(marketOwner);
        address createdMarket = market.createMarket("q", block.timestamp + 100, block.timestamp + 200, initialLiquidity);

        vm.startPrank(marketOwner);
        market.setCcipConfig(address(router), address(feeToken), false);
        market.setTrustedRemote(sepoChainSelector, address(100));
        market.setMarketIdMapping(1, createdMarket);
        vm.stopPrank();

        uint256 validUntil = block.timestamp + 1 days;
        CanonicalPriceSync memory payload = CanonicalPriceSync({
            marketId: 1,
            yesPriceE6: 550_000,
            noPriceE6: 450_000,
            validUntil: validUntil,
            nonce: 2
        });

        Client.EVMTokenAmount[] memory emptyAmounts = new Client.EVMTokenAmount[](0);
        Client.Any2EVMMessage memory message = Client.Any2EVMMessage({
            messageId: bytes32(uint256(7)),
            sourceChainSelector: sepoChainSelector,
            sender: abi.encode(address(100)),
            data: abi.encode(uint8(0), abi.encode(payload)),
            destTokenAmounts: emptyAmounts
        });

        vm.prank(address(router));
        vm.expectEmit(true, true, false, true);
        emit CanonicalPriceMessageReceived(1, 550_000, 450_000, 2);
        market.ccipReceive(message);

        PredictionMarket prediction = PredictionMarket(createdMarket);
        assertEq(prediction.canonicalYesPriceE6(), 550_000);
        assertEq(prediction.canonicalNoPriceE6(), 450_000);
        assertEq(prediction.canonicalPriceValidUntil(), validUntil);
        assertEq(prediction.canonicalPriceNonce(), 2);
        assertEq(market.processedCcipMessages(bytes32(uint256(7))), true);
    }

    function testCcipReceiveResolutionRevertInvalidOutcome() external {
        vm.prank(marketOwner);
        address createdMarket = market.createMarket("q", block.timestamp + 100, block.timestamp + 200, initialLiquidity);

        vm.startPrank(marketOwner);
        market.setCcipConfig(address(router), address(feeToken), false);
        market.setTrustedRemote(sepoChainSelector, address(100));
        market.setMarketIdMapping(1, createdMarket);
        vm.stopPrank();

        ResolutionSync memory payload =
            ResolutionSync({marketId: 1, outcome: uint8(Resolution.Unset), proofUrl: "p", nonce: 1});

        Client.EVMTokenAmount[] memory emptyAmounts = new Client.EVMTokenAmount[](0);
        Client.Any2EVMMessage memory message = Client.Any2EVMMessage({
            messageId: bytes32(uint256(8)),
            sourceChainSelector: sepoChainSelector,
            sender: abi.encode(address(100)),
            data: abi.encode(uint8(1), abi.encode(payload)),
            destTokenAmounts: emptyAmounts
        });

        vm.prank(address(router));
        vm.expectRevert(MarketFactoryBase.MarketFactory__InvalidResolutionOutcome.selector);
        market.ccipReceive(message);
    }

    function testCcipReceiveResolutionRevertStaleResolutionNonce() external {
        vm.prank(marketOwner);
        address createdMarket = market.createMarket("q", block.timestamp + 100, block.timestamp + 200, initialLiquidity);

        vm.startPrank(marketOwner);
        market.setCcipConfig(address(router), address(feeToken), false);
        market.setTrustedRemote(sepoChainSelector, address(100));
        market.setMarketIdMapping(1, createdMarket);
        vm.stopPrank();

        ResolutionSync memory freshPayload =
            ResolutionSync({marketId: 1, outcome: uint8(Resolution.Yes), proofUrl: "p", nonce: 2});
        Client.EVMTokenAmount[] memory emptyAmounts = new Client.EVMTokenAmount[](0);
        Client.Any2EVMMessage memory freshMessage = Client.Any2EVMMessage({
            messageId: bytes32(uint256(9)),
            sourceChainSelector: sepoChainSelector,
            sender: abi.encode(address(100)),
            data: abi.encode(uint8(1), abi.encode(freshPayload)),
            destTokenAmounts: emptyAmounts
        });

        vm.prank(address(router));
        market.ccipReceive(freshMessage);
        assertEq(market.resolutionNonceByMarketId(1), 2);

        ResolutionSync memory stalePayload =
            ResolutionSync({marketId: 1, outcome: uint8(Resolution.Yes), proofUrl: "p", nonce: 2});
        Client.Any2EVMMessage memory staleMessage = Client.Any2EVMMessage({
            messageId: bytes32(uint256(10)),
            sourceChainSelector: sepoChainSelector,
            sender: abi.encode(address(100)),
            data: abi.encode(uint8(1), abi.encode(stalePayload)),
            destTokenAmounts: emptyAmounts
        });

        vm.prank(address(router));
        vm.expectRevert(MarketFactoryBase.MarketFactory__StaleResolutionNonce.selector);
        market.ccipReceive(staleMessage);
    }

    function testCcipReceiveResolutionPassUpdatesNonceAndMarketResolution() external {
        vm.prank(marketOwner);
        address createdMarket = market.createMarket("q", block.timestamp + 100, block.timestamp + 200, initialLiquidity);

        vm.startPrank(marketOwner);
        market.setCcipConfig(address(router), address(feeToken), false);
        market.setTrustedRemote(sepoChainSelector, address(100));
        market.setMarketIdMapping(1, createdMarket);
        vm.stopPrank();

        ResolutionSync memory payload =
            ResolutionSync({marketId: 1, outcome: uint8(Resolution.Yes), proofUrl: "ipfs://proof", nonce: 3});
        Client.EVMTokenAmount[] memory emptyAmounts = new Client.EVMTokenAmount[](0);
        Client.Any2EVMMessage memory message = Client.Any2EVMMessage({
            messageId: bytes32(uint256(11)),
            sourceChainSelector: sepoChainSelector,
            sender: abi.encode(address(100)),
            data: abi.encode(uint8(1), abi.encode(payload)),
            destTokenAmounts: emptyAmounts
        });

        vm.prank(address(router));
        vm.expectEmit(true, true, false, true);
        emit ResolutionMessageReceived(1, Resolution.Yes, 3);
        market.ccipReceive(message);

        PredictionMarket prediction = PredictionMarket(createdMarket);
        assertEq(uint8(prediction.resolution()), uint8(Resolution.Yes));
        assertEq(market.resolutionNonceByMarketId(1), 3);
        assertEq(market.processedCcipMessages(bytes32(uint256(11))), true);
    }
}
