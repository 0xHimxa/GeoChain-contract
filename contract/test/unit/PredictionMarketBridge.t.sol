// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {OutcomeToken} from "../../src/token/OutcomeToken.sol";
import {Client} from "../../src/ccip/Client.sol";
import {IRouterClient} from "../../src/ccip/IRouterClient.sol";
import {IAny2EVMMessageReceiver} from "../../src/ccip/IAny2EVMMessageReceiver.sol";
import {PredictionMarketBridge, IPredictionMarketClaimSource} from "../../src/Bridge/PredictionMarketBridge.sol";

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

    function _claimKey(uint64 sourceChainSelector, uint256 _marketId, bool useYesToken) internal pure returns (bytes32) {
        return keccak256(abi.encode(sourceChainSelector, _marketId, useYesToken));
    }

    function _asAny2Evm(
        bytes32 messageId,
        uint64 sourceChainSelector,
        address senderOnSource,
        uint8 messageType,
        bytes memory payload
    ) internal pure returns (Client.Any2EVMMessage memory m) {
        Client.EVMTokenAmount[] memory noTokens = new Client.EVMTokenAmount[](0);
        m = Client.Any2EVMMessage({
            messageId: messageId,
            sourceChainSelector: sourceChainSelector,
            sender: abi.encode(senderOnSource),
            data: abi.encode(messageType, payload),
            destTokenAmounts: noTokens
        });
    }

    function _deliverMintMessage(
        bytes32 messageId,
        uint64 sourceChainSelector,
        uint256 _marketId,
        bool useYesToken,
        uint256 amount,
        address mintReceiver
    ) internal returns (bytes32 key, address wrapped) {
        PredictionMarketBridge.LockClaimPayload memory payload = PredictionMarketBridge.LockClaimPayload({
            marketId: _marketId,
            useYesToken: useYesToken,
            amount: amount,
            receiver: mintReceiver,
            nonce: 1
        });
        Client.Any2EVMMessage memory message = _asAny2Evm(
            messageId, sourceChainSelector, remoteBridge, 0, abi.encode(payload)
        );
        vm.prank(address(router));
        bridge.ccipReceive(message);
        key = _claimKey(sourceChainSelector, _marketId, useYesToken);
        wrapped = bridge.wrappedClaimTokenByKey(key);
    }

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

    function testSetCcipConfigRevertsOnZeroAddress() external {
        vm.expectRevert(PredictionMarketBridge.PredictionMarketBridge__ZeroAddress.selector);
        bridge.setCcipConfig(address(0), address(feeToken));

        vm.expectRevert(PredictionMarketBridge.PredictionMarketBridge__ZeroAddress.selector);
        bridge.setCcipConfig(address(router), address(0));
    }

    function testSetSupportedChainSelectorRevertsOnZeroSelector() external {
        vm.expectRevert(PredictionMarketBridge.PredictionMarketBridge__UnsupportedChainSelector.selector);
        bridge.setSupportedChainSelector(0, true);
    }

    function testSetTrustedRemoteRevertsOnZeroAddress() external {
        vm.expectRevert(PredictionMarketBridge.PredictionMarketBridge__ZeroAddress.selector);
        bridge.setTrustedRemote(destinationSelector, address(0));
    }

    function testRemoveTrustedRemotePassAndRevertsOnUnsupported() external {
        bridge.removeTrustedRemote(destinationSelector);
        assertEq(bridge.trustedRemoteBySelector(destinationSelector).length, 0);

        vm.expectRevert(PredictionMarketBridge.PredictionMarketBridge__UnsupportedChainSelector.selector);
        bridge.removeTrustedRemote(999999);
    }

    function testSetMarketFactoryRevertsOnZeroAddress() external {
        vm.expectRevert(PredictionMarketBridge.PredictionMarketBridge__ZeroAddress.selector);
        bridge.setMarketFactory(address(0));
    }

    function testSetWrappedClaimBuybackBpsRevertsOnInvalidBps() external {
        vm.expectRevert(PredictionMarketBridge.PredictionMarketBridge__InvalidBps.selector);
        bridge.setWrappedClaimBuybackBps(10_001);
    }

    function testSetBuybackUnlockReceiverRevertsOnZeroAddress() external {
        vm.expectRevert(PredictionMarketBridge.PredictionMarketBridge__ZeroAddress.selector);
        bridge.setBuybackUnlockReceiver(address(0));
    }

    function testDepositAndWithdrawCollateralLiquidity() external {
        collateral.mint(address(this), 100e6);
        collateral.approve(address(bridge), 100e6);
        bridge.depositCollateralLiquidity(100e6);
        assertEq(collateral.balanceOf(address(bridge)), 100e6);

        bridge.withdrawCollateralLiquidity(address(this), 40e6);
        assertEq(collateral.balanceOf(address(bridge)), 60e6);
    }

    function testDepositAndWithdrawCollateralLiquidityRevertsOnBadInputs() external {
        vm.expectRevert(PredictionMarketBridge.PredictionMarketBridge__InvalidAmount.selector);
        bridge.depositCollateralLiquidity(0);

        vm.expectRevert(PredictionMarketBridge.PredictionMarketBridge__ZeroAddress.selector);
        bridge.withdrawCollateralLiquidity(address(0), 1);

        vm.expectRevert(PredictionMarketBridge.PredictionMarketBridge__InvalidAmount.selector);
        bridge.withdrawCollateralLiquidity(address(this), 0);
    }

    function testQuoteBridgeFeeRevertsWhenConfigMissing() external {
        PredictionMarketBridge freshBridge = new PredictionMarketBridge(address(this), address(collateral));
        vm.expectRevert(PredictionMarketBridge.PredictionMarketBridge__ZeroAddress.selector);
        freshBridge.quoteBridgeFee(destinationSelector, 0, hex"1234");
    }

    function testQuoteBridgeFeeRevertsWhenUnsupportedChainSelector() external {
        vm.expectRevert(PredictionMarketBridge.PredictionMarketBridge__UnsupportedChainSelector.selector);
        bridge.quoteBridgeFee(999999, 0, hex"1234");
    }

    function testQuoteBridgeFeeReturnsRouterFee() external {
        router.setFee(12345);
        uint256 fee = bridge.quoteBridgeFee(destinationSelector, 0, hex"1234");
        assertEq(fee, 12345);
    }

    function testLockAndBridgeClaimRevertsOnInvalidAmountAndReceiver() external {
        vm.expectRevert(PredictionMarketBridge.PredictionMarketBridge__InvalidAmount.selector);
        bridge.lockAndBridgeClaim(marketId, true, 0, destinationSelector, receiver);

        vm.expectRevert(PredictionMarketBridge.PredictionMarketBridge__ZeroAddress.selector);
        bridge.lockAndBridgeClaim(marketId, true, 1, destinationSelector, address(0));
    }

    function testLockAndBridgeClaimRevertsOnUnsupportedChainAndUnknownMarket() external {
        yesToken.mint(user, 10e6);
        vm.startPrank(user);
        yesToken.approve(address(bridge), 10e6);

        vm.expectRevert(PredictionMarketBridge.PredictionMarketBridge__UnsupportedChainSelector.selector);
        bridge.lockAndBridgeClaim(marketId, true, 10e6, 999999, receiver);

        vm.expectRevert(PredictionMarketBridge.PredictionMarketBridge__UnknownMarket.selector);
        bridge.lockAndBridgeClaim(999, true, 10e6, destinationSelector, receiver);
        vm.stopPrank();
    }

    function testLockAndBridgeClaimPassForNoWinningToken() external {
        market.setResolution(2);
        uint256 amount = 15e6;
        noToken.mint(user, amount);

        vm.startPrank(user);
        noToken.approve(address(bridge), amount);
        bridge.lockAndBridgeClaim(marketId, false, amount, destinationSelector, receiver);
        vm.stopPrank();

        assertEq(noToken.balanceOf(address(bridge)), amount);
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

    function testBurnWrappedAndUnlockClaimRevertsForBadInputs() external {
        vm.expectRevert(PredictionMarketBridge.PredictionMarketBridge__InvalidAmount.selector);
        bridge.burnWrappedAndUnlockClaim(destinationSelector, marketId, true, 0, receiver);

        vm.expectRevert(PredictionMarketBridge.PredictionMarketBridge__ZeroAddress.selector);
        bridge.burnWrappedAndUnlockClaim(destinationSelector, marketId, true, 1, address(0));

        vm.expectRevert(PredictionMarketBridge.PredictionMarketBridge__UnsupportedChainSelector.selector);
        bridge.burnWrappedAndUnlockClaim(999999, marketId, true, 1, receiver);
    }

    function testBurnWrappedAndUnlockClaimRevertsWhenWrappedTokenUnknown() external {
        vm.expectRevert(PredictionMarketBridge.PredictionMarketBridge__UnknownWrappedClaimToken.selector);
        bridge.burnWrappedAndUnlockClaim(destinationSelector, marketId, true, 1, receiver);
    }

    function testBurnWrappedAndUnlockClaimPass() external {
        (, address wrapped) = _deliverMintMessage(bytes32("m1"), destinationSelector, marketId, true, 10e6, user);
        assertEq(IERC20(wrapped).balanceOf(user), 10e6);

        vm.prank(user);
        IERC20(wrapped).approve(address(bridge), 10e6);
        vm.prank(user);
        bridge.burnWrappedAndUnlockClaim(destinationSelector, marketId, true, 10e6, receiver);

        assertEq(IERC20(wrapped).totalSupply(), 0);
        assertEq(IERC20(wrapped).balanceOf(address(bridge)), 0);
        assertEq(router.sentCount(), 1);
        assertEq(bridge.outboundNonce(), 1);
    }

    function testSellWrappedClaimForCollateralRevertsForBadInputs() external {
        vm.expectRevert(PredictionMarketBridge.PredictionMarketBridge__InvalidAmount.selector);
        bridge.sellWrappedClaimForCollateral(destinationSelector, marketId, true, 0, 0);

        bridge.setBuybackUnlockReceiver(address(0xA11CE));
        vm.expectRevert(PredictionMarketBridge.PredictionMarketBridge__UnsupportedChainSelector.selector);
        bridge.sellWrappedClaimForCollateral(999999, marketId, true, 1, 0);
    }

    function testSellWrappedClaimForCollateralRevertsWhenUnknownToken() external {
        vm.expectRevert(PredictionMarketBridge.PredictionMarketBridge__UnknownWrappedClaimToken.selector);
        bridge.sellWrappedClaimForCollateral(destinationSelector, marketId, true, 1, 0);
    }

    function testSellWrappedClaimForCollateralRevertsOnSlippageAndInsufficientLiquidity() external {
        (, address wrapped) = _deliverMintMessage(bytes32("m2"), destinationSelector, marketId, true, 10e6, user);

        vm.startPrank(user);
        IERC20(wrapped).approve(address(bridge), 10e6);
        vm.expectRevert(PredictionMarketBridge.PredictionMarketBridge__SlippageExceeded.selector);
        bridge.sellWrappedClaimForCollateral(destinationSelector, marketId, true, 10e6, 11e6);
        vm.stopPrank();

        vm.startPrank(user);
        vm.expectRevert(PredictionMarketBridge.PredictionMarketBridge__InsufficientCollateralLiquidity.selector);
        bridge.sellWrappedClaimForCollateral(destinationSelector, marketId, true, 10e6, 0);
        vm.stopPrank();
    }

    function testSellWrappedClaimForCollateralPass() external {
        (, address wrapped) = _deliverMintMessage(bytes32("m3"), destinationSelector, marketId, true, 10e6, user);
        assertEq(IERC20(wrapped).balanceOf(user), 10e6);

        collateral.mint(address(this), 20e6);
        collateral.approve(address(bridge), 20e6);
        bridge.depositCollateralLiquidity(20e6);
        assertEq(collateral.balanceOf(user), 0);

        vm.prank(user);
        IERC20(wrapped).approve(address(bridge), 10e6);
        vm.prank(user);
        (uint256 collateralOut, bytes32 msgId) =
            bridge.sellWrappedClaimForCollateral(destinationSelector, marketId, true, 10e6, 0);

        assertEq(collateralOut, 10e6);
        assertEq(collateral.balanceOf(user), 10e6);
        assertEq(IERC20(wrapped).totalSupply(), 0);
        assertEq(IERC20(wrapped).balanceOf(address(bridge)), 0);
        assertEq(router.sentCount(), 1);
        assertTrue(msgId != bytes32(0));
    }

    function testCcipReceiveRevertsWhenRouterSenderInvalid() external {
        PredictionMarketBridge.LockClaimPayload memory payload = PredictionMarketBridge.LockClaimPayload({
            marketId: marketId,
            useYesToken: true,
            amount: 1,
            receiver: user,
            nonce: 1
        });
        Client.Any2EVMMessage memory message =
            _asAny2Evm(bytes32("x1"), destinationSelector, remoteBridge, 0, abi.encode(payload));

        vm.prank(user);
        vm.expectRevert(PredictionMarketBridge.PredictionMarketBridge__InvalidRouterSender.selector);
        bridge.ccipReceive(message);
    }

    function testCcipReceiveRevertsWhenSourceSelectorUnsupported() external {
        PredictionMarketBridge.LockClaimPayload memory payload = PredictionMarketBridge.LockClaimPayload({
            marketId: marketId,
            useYesToken: true,
            amount: 1,
            receiver: user,
            nonce: 1
        });
        Client.Any2EVMMessage memory message = _asAny2Evm(bytes32("x2"), 999999, remoteBridge, 0, abi.encode(payload));

        vm.prank(address(router));
        vm.expectRevert(PredictionMarketBridge.PredictionMarketBridge__UnsupportedChainSelector.selector);
        bridge.ccipReceive(message);
    }

    function testCcipReceiveRevertsWhenRemoteSenderInvalid() external {
        PredictionMarketBridge.LockClaimPayload memory payload = PredictionMarketBridge.LockClaimPayload({
            marketId: marketId,
            useYesToken: true,
            amount: 1,
            receiver: user,
            nonce: 1
        });
        Client.Any2EVMMessage memory message =
            _asAny2Evm(bytes32("x3"), destinationSelector, address(0x9999), 0, abi.encode(payload));

        vm.prank(address(router));
        vm.expectRevert(PredictionMarketBridge.PredictionMarketBridge__InvalidRemoteSender.selector);
        bridge.ccipReceive(message);
    }

    function testCcipReceiveRevertsForUnknownMessageType() external {
        Client.EVMTokenAmount[] memory noTokens = new Client.EVMTokenAmount[](0);
        Client.Any2EVMMessage memory message = Client.Any2EVMMessage({
            messageId: bytes32("x4"),
            sourceChainSelector: destinationSelector,
            sender: abi.encode(remoteBridge),
            data: abi.encode(uint8(99), hex"1234"),
            destTokenAmounts: noTokens
        });

        vm.prank(address(router));
        vm.expectRevert(PredictionMarketBridge.PredictionMarketBridge__UnknownMessageType.selector);
        bridge.ccipReceive(message);
    }

    function testCcipReceiveRevertsWhenMessageAlreadyProcessed() external {
        _deliverMintMessage(bytes32("x5"), destinationSelector, marketId, true, 1e6, user);

        PredictionMarketBridge.LockClaimPayload memory payload = PredictionMarketBridge.LockClaimPayload({
            marketId: marketId,
            useYesToken: true,
            amount: 1e6,
            receiver: user,
            nonce: 1
        });
        Client.Any2EVMMessage memory repeat =
            _asAny2Evm(bytes32("x5"), destinationSelector, remoteBridge, 0, abi.encode(payload));
        vm.prank(address(router));
        vm.expectRevert(PredictionMarketBridge.PredictionMarketBridge__MessageAlreadyProcessed.selector);
        bridge.ccipReceive(repeat);
    }

    function testCcipReceiveMintMessageReusesExistingWrappedToken() external {
        (bytes32 key, address wrapped1) = _deliverMintMessage(bytes32("x6"), destinationSelector, marketId, true, 2e6, user);
        (, address wrapped2) = _deliverMintMessage(bytes32("x7"), destinationSelector, marketId, true, 3e6, receiver);

        assertEq(key, _claimKey(destinationSelector, marketId, true));
        assertEq(wrapped1, wrapped2);
        assertEq(OutcomeToken(wrapped1).balanceOf(user), 2e6);
        assertEq(OutcomeToken(wrapped1).balanceOf(receiver), 3e6);
    }

    function testCcipReceiveUnlockRevertsWhenUnknownMarket() external {
        PredictionMarketBridge.UnlockClaimPayload memory payload = PredictionMarketBridge.UnlockClaimPayload({
            marketId: 999,
            useYesToken: true,
            amount: 1e6,
            receiver: receiver,
            nonce: 1
        });
        Client.Any2EVMMessage memory message =
            _asAny2Evm(bytes32("x8"), destinationSelector, remoteBridge, 1, abi.encode(payload));
        vm.prank(address(router));
        vm.expectRevert(PredictionMarketBridge.PredictionMarketBridge__UnknownMarket.selector);
        bridge.ccipReceive(message);
    }

    function testCcipReceiveUnlockRevertsWhenInsufficientLockedClaims() external {
        PredictionMarketBridge.UnlockClaimPayload memory payload = PredictionMarketBridge.UnlockClaimPayload({
            marketId: marketId,
            useYesToken: true,
            amount: 1e6,
            receiver: receiver,
            nonce: 1
        });
        Client.Any2EVMMessage memory message =
            _asAny2Evm(bytes32("x9"), destinationSelector, remoteBridge, 1, abi.encode(payload));
        vm.prank(address(router));
        vm.expectRevert(PredictionMarketBridge.PredictionMarketBridge__InsufficientLockedClaims.selector);
        bridge.ccipReceive(message);
    }

    function testCcipReceiveUnlockTransfersUnderlyingClaim() external {
        yesToken.mint(address(bridge), 3e6);
        PredictionMarketBridge.UnlockClaimPayload memory payload = PredictionMarketBridge.UnlockClaimPayload({
            marketId: marketId,
            useYesToken: true,
            amount: 2e6,
            receiver: receiver,
            nonce: 1
        });
        Client.Any2EVMMessage memory message =
            _asAny2Evm(bytes32("x10"), destinationSelector, remoteBridge, 1, abi.encode(payload));

        vm.prank(address(router));
        bridge.ccipReceive(message);

        assertEq(yesToken.balanceOf(receiver), 2e6);
        assertEq(yesToken.balanceOf(address(bridge)), 1e6);
    }
}
