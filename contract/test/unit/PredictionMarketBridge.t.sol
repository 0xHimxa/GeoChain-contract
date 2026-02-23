// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {OutcomeToken} from "src/OutcomeToken.sol";
import {Client} from "src/ccip/Client.sol";
import {IRouterClient} from "src/ccip/IRouterClient.sol";
import {IAny2EVMMessageReceiver} from "src/ccip/IAny2EVMMessageReceiver.sol";
import {PredictionMarketBridge, IPredictionMarketClaimSource} from "src/ccip/PredictionMarketBridge.sol";

contract MockRouterForBridge is IRouterClient {
    uint256 public fee;
    uint256 public sentCount;
    uint64 public lastDestination;
    bytes public lastReceiver;
    bytes public lastData;

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
        lastData = message.data;
        messageId = keccak256(abi.encode(destinationChainSelector, sentCount));
    }
}

contract MockPredictionMarketClaimSource is IPredictionMarketClaimSource {
    address public override yesToken;
    address public override noToken;
    uint8 public override resolution;

    constructor(address _yesToken, address _noToken, uint8 _resolution) {
        yesToken = _yesToken;
        noToken = _noToken;
        resolution = _resolution;
    }

    function setResolution(uint8 _resolution) external {
        resolution = _resolution;
    }
}

contract PredictionMarketBridgeTest is Test {
    PredictionMarketBridge bridge;
    MockRouterForBridge router;
    MockPredictionMarketClaimSource market;
    OutcomeToken collateral;
    OutcomeToken feeToken;
    OutcomeToken yesToken;
    OutcomeToken noToken;

    address user = address(0xBEEF);
    address receiver = address(0xCAFE);
    address remoteBridge = address(0x1234);
    uint64 destinationSelector = 421614;
    uint256 marketId = 1;

    function setUp() external {
        collateral = new OutcomeToken("USDC", "USDC", address(this));
        feeToken = new OutcomeToken("LINK", "LINK", address(this));
        yesToken = new OutcomeToken("YES", "YES", address(this));
        noToken = new OutcomeToken("NO", "NO", address(this));

        bridge = new PredictionMarketBridge(address(this), address(collateral));
        router = new MockRouterForBridge();
        router.setFee(0);

        market = new MockPredictionMarketClaimSource(address(yesToken), address(noToken), 1);

        bridge.setCcipConfig(address(router), address(feeToken));
        bridge.setSupportedChainSelector(destinationSelector, true);
        bridge.setTrustedRemote(destinationSelector, remoteBridge);
        bridge.setMarketIdMapping(marketId, address(market));
    }

    function testConstructorRevertsWhenOwnerIsZero() external {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new PredictionMarketBridge(address(0), address(collateral));
    }

    function testConstructorRevertsWhenCollateralIsZero() external {
        vm.expectRevert(PredictionMarketBridge.PredictionMarketBridge__ZeroAddress.selector);
        new PredictionMarketBridge(address(this), address(0));
    }

    function testSupportsInterfaceReturnsExpectedValues() external view {
        assertTrue(bridge.supportsInterface(type(IAny2EVMMessageReceiver).interfaceId));
        assertTrue(bridge.supportsInterface(type(IERC165).interfaceId));
        assertFalse(bridge.supportsInterface(type(IRouterClient).interfaceId));
    }

    function testSetTrustedRemoteRevertsWhenSelectorUnsupported() external {
        vm.expectRevert(PredictionMarketBridge.PredictionMarketBridge__UnsupportedChainSelector.selector);
        bridge.setTrustedRemote(999999, remoteBridge);
    }

    function testSetMarketIdMappingRevertsForUnauthorizedCaller() external {
        vm.prank(user);
        vm.expectRevert(PredictionMarketBridge.PredictionMarketBridge__NotAuthorizedMarketMapper.selector);
        bridge.setMarketIdMapping(77, address(market));
    }

    function testSetMarketIdMappingAllowsConfiguredFactory() external {
        address factory = address(0xFACADE);
        bridge.setMarketFactory(factory);

        vm.prank(factory);
        bridge.setMarketIdMapping(77, address(market));

        assertEq(bridge.marketById(77), address(market));
    }

    function testLockAndBridgeClaimRevertsWhenMarketNotResolved() external {
        market.setResolution(0);
        yesToken.mint(user, 10e6);

        vm.startPrank(user);
        yesToken.approve(address(bridge), 10e6);
        vm.expectRevert(PredictionMarketBridge.PredictionMarketBridge__MarketNotResolved.selector);
        bridge.lockAndBridgeClaim(marketId, true, 10e6, destinationSelector, receiver);
        vm.stopPrank();
    }

    function testLockAndBridgeClaimRevertsWhenWrongWinningSidePicked() external {
        market.setResolution(1);
        noToken.mint(user, 10e6);

        vm.startPrank(user);
        noToken.approve(address(bridge), 10e6);
        vm.expectRevert(PredictionMarketBridge.PredictionMarketBridge__TokenNotWinningClaim.selector);
        bridge.lockAndBridgeClaim(marketId, false, 10e6, destinationSelector, receiver);
        vm.stopPrank();
    }

    function testLockAndBridgeClaimTransfersWinningTokenAndSendsMessage() external {
        uint256 amount = 25e6;
        yesToken.mint(user, amount);

        vm.startPrank(user);
        yesToken.approve(address(bridge), amount);
        bytes32 messageId = bridge.lockAndBridgeClaim(marketId, true, amount, destinationSelector, receiver);
        vm.stopPrank();

        assertEq(yesToken.balanceOf(user), 0);
        assertEq(yesToken.balanceOf(address(bridge)), amount);
        assertEq(bridge.outboundNonce(), 1);
        assertEq(router.sentCount(), 1);
        assertEq(router.lastDestination(), destinationSelector);
        assertEq(abi.decode(router.lastReceiver(), (address)), remoteBridge);
        assertTrue(messageId != bytes32(0));
    }
}
