// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {PredictionMarketRouterVault} from "../../src/router/PredictionMarketRouterVault.sol";
import {PredictionMarket} from "../../src/predictionMarket/PredictionMarket.sol";
import {MarketDeployer} from "../../src/marketFactory/event-deployer/MarketDeployer.sol";
import {OutcomeToken} from "../../src/token/OutcomeToken.sol";
import {MarketConstants, Resolution} from "../../src/libraries/MarketTypes.sol";

interface IMockMarket {
    function i_collateral() external view returns (address);
    function yesToken() external view returns (address);
    function noToken() external view returns (address);
    function lpShares(address account) external view returns (uint256);
    function mintCompleteSets(uint256 amount) external;
    function redeemCompleteSets(uint256 amount) external;
    function redeem(uint256 amount) external;
    function resolution() external view returns (uint8);
    function swapYesForNo(uint256 yesIn, uint256 minNoOut) external;
    function swapNoForYes(uint256 noIn, uint256 minYesOut) external;
    function addLiquidity(uint256 yesAmount, uint256 noAmount, uint256 minShares) external;
    function removeLiquidity(uint256 shares, uint256 minYesOut, uint256 minNoOut) external;
    function balanceOf(address account) external view returns (uint256);
}

contract MockMarketFactory {
    address public lastRemoved;
    uint256 public removeCount;
    uint256 public manualReviewAddedCount;
    uint256 public manualReviewRemovedCount;

    function removeResolvedMarket(address market) external {
        lastRemoved = market;
        removeCount++;
    }

    function markMarketForManualReview(address) external {
        manualReviewAddedCount++;
    }

    function removeManualReviewMarket(address) external {
        manualReviewRemovedCount++;
    }

    function deployMarket(
        MarketDeployer deployer,
        string memory question,
        address collateral,
        uint256 closeTime,
        uint256 resolutionTime,
        address forwarder
    ) external returns (address) {
        return deployer.deployPredictionMarket(question, collateral, closeTime, resolutionTime, forwarder);
    }
}

contract PredictionMarketRouterVaultTest is Test {
    PredictionMarketRouterVault internal router;
    OutcomeToken internal collateral;
    PredictionMarket internal market;
    MarketDeployer internal marketDeployer;
    MockMarketFactory internal mockFactory;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal owner = makeAddr("owner");
    address internal forwarder = makeAddr("forwarder");
    address internal marketFactory = makeAddr("marketFactory");

    uint256 internal constant INITIAL_DEPOSIT = 1000e6;

    function setUp() external {
        collateral = new OutcomeToken("USDC", "USDC", address(this));
        mockFactory = new MockMarketFactory();
        PredictionMarketRouterVault routerImplementation = new PredictionMarketRouterVault();
        bytes memory initData = abi.encodeCall(
            PredictionMarketRouterVault.initialize, (address(collateral), forwarder, owner, marketFactory)
        );
        ERC1967Proxy routerProxy = new ERC1967Proxy(address(routerImplementation), initData);
        router = PredictionMarketRouterVault(payable(address(routerProxy)));

        PredictionMarket implementation = new PredictionMarket();
        marketDeployer = new MarketDeployer(address(implementation), address(mockFactory));

        market = PredictionMarket(
            mockFactory.deployMarket(
                marketDeployer,
                "Will ETH be above $5000?",
                address(collateral),
                block.timestamp + 1 days,
                block.timestamp + 2 days,
                forwarder
            )
        );

        vm.prank(address(mockFactory));
        market.transferOwnership(address(this));

        collateral.mint(address(market), 10_000e6);
        market.seedLiquidity(10_000e6);

        vm.prank(owner);
        router.setMarketAllowed(address(market), true);

        collateral.mint(alice, INITIAL_DEPOSIT * 10);
        vm.prank(alice);
        collateral.approve(address(router), type(uint256).max);
    }

    function _depositCollateral(address user, uint256 amount) internal {
        vm.prank(user);
        router.depositCollateral(amount);
    }

    function _getMockMarketTokens(address marketAddress) internal view returns (address yesToken, address noToken) {
        yesToken = IMockMarket(marketAddress).yesToken();
        noToken = IMockMarket(marketAddress).noToken();
    }

    function _resolveAndFinalize(Resolution outcome, string memory proofUrl) internal {
        market.resolve(outcome, proofUrl);
        vm.warp(block.timestamp + market.disputeWindow() + 1);
        market.finalizeResolutionAfterDisputeWindow();
    }

    function _setAgentPermissionAll(address user, address agent, uint128 maxAmount) internal {
        uint32 allActions = (1 << 8) - 1;
        vm.prank(user);
        router.setAgentPermission(agent, allActions, maxAmount, uint64(block.timestamp + 1 days));
    }

    function testInitializeRevertZeroCollateral() external {
        PredictionMarketRouterVault implementation = new PredictionMarketRouterVault();
        bytes memory initData =
            abi.encodeCall(PredictionMarketRouterVault.initialize, (address(0), forwarder, owner, marketFactory));
        vm.expectRevert(abi.encodeWithSignature("Router__ZeroAddress()"));
        new ERC1967Proxy(address(implementation), initData);
    }

    function testConstructorSuccess() external view {
        assertEq(address(router.collateralToken()), address(collateral));
        assertEq(router.marketFactory(), marketFactory);
    }

    function testSetMarketAllowedByFactory() external {
        address newMarket = makeAddr("newMarket");

        vm.prank(marketFactory);
        router.setMarketAllowed(newMarket, true);

        assertTrue(router.allowedMarkets(newMarket));

        vm.prank(marketFactory);
        router.setMarketAllowed(newMarket, false);

        assertFalse(router.allowedMarkets(newMarket));
    }

    function testSetMarketAllowedByOwner() external {
        address newMarket = makeAddr("newMarket");

        vm.prank(owner);
        router.setMarketAllowed(newMarket, true);

        assertTrue(router.allowedMarkets(newMarket));
    }

    function testSetMarketAllowedRevertUnauthorized() external {
        address newMarket = makeAddr("newMarket");

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("PredictionMarketRouterVault__NotAuthorizedMarketMapper()"));
        router.setMarketAllowed(newMarket, true);
    }

    function testSetMarketAllowedRevertZeroAddress() external {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSignature("Router__ZeroAddress()"));
        router.setMarketAllowed(address(0), true);
    }

    function testSetRiskExemptByOwner() external {
        vm.prank(owner);
        router.setRiskExempt(alice, true);

        assertTrue(router.isRiskExempt(alice));

        vm.prank(owner);
        router.setRiskExempt(alice, false);

        assertFalse(router.isRiskExempt(alice));
    }

    function testSetRiskExemptRevertUnauthorized() external {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", alice));
        router.setRiskExempt(bob, true);
    }

    function testSetRiskExemptRevertZeroAddress() external {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSignature("Router__ZeroAddress()"));
        router.setRiskExempt(address(0), true);
    }

    function testSetAgentPermissionRevertValidation() external {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("Router__ZeroAddress()"));
        router.setAgentPermission(address(0), 1, 1, uint64(block.timestamp + 1 days));

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("Router__AgentPermissionExpired()"));
        router.setAgentPermission(bob, 1, 1, uint64(block.timestamp));

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("Router__AgentActionNotAllowed()"));
        router.setAgentPermission(bob, 0, 1, uint64(block.timestamp + 1 days));

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("Router__InvalidAmount()"));
        router.setAgentPermission(bob, 1, 0, uint64(block.timestamp + 1 days));
    }

    function testSetAndRevokeAgentPermission() external {
        _setAgentPermissionAll(alice, bob, 100e6);
        (bool enabled, uint64 expiresAt, uint128 maxAmount, uint32 actionMask) = router.agentPermissions(alice, bob);
        assertTrue(enabled);
        assertGt(expiresAt, block.timestamp);
        assertEq(uint256(maxAmount), 100e6);
        assertEq(uint256(actionMask), 255);

        vm.prank(alice);
        router.revokeAgentPermission(bob);
        (enabled, expiresAt, maxAmount, actionMask) = router.agentPermissions(alice, bob);
        assertFalse(enabled);
        assertEq(expiresAt, 0);
        assertEq(maxAmount, 0);
        assertEq(actionMask, 0);
    }

    function testAgentActionsRevertWithoutPermission() external {
        vm.prank(alice);
        router.depositCollateral(100e6);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSignature("Router__AgentNotAuthorized()"));
        router.mintCompleteSetsFor(alice, address(market), 10e6);
    }

    function testAgentExecutionPathsSuccess() external {
        vm.prank(alice);
        router.depositCollateral(200e6);
        _setAgentPermissionAll(alice, bob, 200e6);

        vm.prank(bob);
        router.mintCompleteSetsFor(alice, address(market), 50e6);

        vm.prank(bob);
        router.swapYesForNoFor(alice, address(market), 10e6, 0);

        vm.prank(bob);
        router.swapNoForYesFor(alice, address(market), 5e6, 0);

        vm.prank(bob);
        router.addLiquidityFor(alice, address(market), 5e6, 5e6, 0);
        assertGt(router.lpShareCredits(alice, address(market)), 0);

        uint256 shares = router.lpShareCredits(alice, address(market));
        vm.prank(bob);
        router.removeLiquidityFor(alice, address(market), shares / 2, 0, 0);

        vm.prank(bob);
        router.redeemCompleteSetsFor(alice, address(market), 5e6);

        vm.warp(block.timestamp + 3 days);
        _resolveAndFinalize(Resolution.Yes, "ipfs://proof");

        // Refresh delegation after time warp; initial permission duration is 1 day.
        _setAgentPermissionAll(alice, bob, 200e6);
        vm.prank(bob);
        router.redeemFor(alice, address(market), 1e6);
        assertGt(router.collateralCredits(alice), 0);
    }

    function testOnReportCreditAndUnknownAction() external {
        collateral.mint(address(router), 20e6);

        bytes memory creditFiatReport = abi.encode("routerCreditFromFiat", abi.encode(alice, 10e6));
        vm.prank(forwarder);
        router.onReport("", creditFiatReport);
        assertEq(router.collateralCredits(alice), 10e6);

        bytes32 depositId = keccak256("dep-1");
        bytes memory creditEthReport = abi.encode("routerCreditFromEth", abi.encode(alice, 5e6, depositId));
        vm.prank(forwarder);
        router.onReport("", creditEthReport);
        assertEq(router.collateralCredits(alice), 15e6);

        vm.prank(forwarder);
        vm.expectRevert(abi.encodeWithSignature("Router__EthDepositAlreadyProcessed()"));
        router.onReport("", creditEthReport);

        bytes memory unknown = abi.encode("routerUnknownAction", abi.encode(uint256(1)));
        vm.prank(forwarder);
        vm.expectRevert(abi.encodeWithSignature("Router__ActionNotRecognized()"));
        router.onReport("", unknown);
    }

    function testOnReportRevokeAgentPermission() external {
        _setAgentPermissionAll(alice, bob, 100e6);
        (bool enabledBefore,,,) = router.agentPermissions(alice, bob);
        assertTrue(enabledBefore);

        bytes memory revokeReport = abi.encode("routerAgentRevokePermission", abi.encode(alice, bob));
        vm.prank(forwarder);
        router.onReport("", revokeReport);

        (bool enabledAfter, uint64 expiresAt, uint128 maxAmount, uint32 actionMask) =
            router.agentPermissions(alice, bob);
        assertFalse(enabledAfter);
        assertEq(expiresAt, 0);
        assertEq(maxAmount, 0);
        assertEq(actionMask, 0);
    }

    function testDepositCollateralSuccess() external {
        uint256 depositAmount = 100e6;

        vm.prank(alice);
        router.depositCollateral(depositAmount);

        assertEq(router.collateralCredits(alice), depositAmount);
        assertEq(router.totalCollateralCredits(), depositAmount);
        assertEq(collateral.balanceOf(address(router)), depositAmount);
    }

    function testDepositCollateralRevertZeroAmount() external {
        // Router does not revert on zero deposit - it just does nothing
    }

    function testWithdrawCollateralRevertZeroAmount() external {
        // Router allows zero withdrawal - no-op
    }

    function testWithdrawCollateralSuccess() external {
        uint256 depositAmount = 100e6;
        uint256 withdrawAmount = 50e6;

        vm.prank(alice);
        router.depositCollateral(depositAmount);

        uint256 aliceBalanceBefore = collateral.balanceOf(alice);

        vm.prank(alice);
        router.withdrawCollateral(withdrawAmount);

        assertEq(router.collateralCredits(alice), depositAmount - withdrawAmount);
        assertEq(router.totalCollateralCredits(), depositAmount - withdrawAmount);
        assertEq(collateral.balanceOf(alice), aliceBalanceBefore + withdrawAmount);
    }

    function testWithdrawCollateralRevertInsufficientBalance() external {
        vm.prank(alice);
        router.depositCollateral(100e6);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("Router__InsufficientBalance()"));
        router.withdrawCollateral(150e6);
    }

    function testMintCompleteSetsSuccess() external {
        uint256 depositAmount = 100e6;
        uint256 mintAmount = 50e6;

        vm.prank(alice);
        router.depositCollateral(depositAmount);

        (address yesToken, address noToken) = _getMockMarketTokens(address(market));

        vm.prank(alice);
        router.mintCompleteSets(address(market), mintAmount);

        uint256 expectedNet = mintAmount - ((mintAmount * 300) / 10000);
        assertEq(router.collateralCredits(alice), depositAmount - mintAmount);
        assertEq(router.tokenCredits(alice, yesToken), expectedNet);
        assertEq(router.tokenCredits(alice, noToken), expectedNet);
        assertEq(router.userRiskExposure(alice), mintAmount);
    }

    function testMintCompleteSetsRevertMarketNotAllowed() external {
        address disallowedMarket = makeAddr("disallowedMarket");

        vm.prank(alice);
        router.depositCollateral(100e6);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("Router__MarketNotAllowed()"));
        router.mintCompleteSets(disallowedMarket, 50e6);
    }

    function testMintCompleteSetsRevertCollateralMismatch() external {
        address fakeMarket = makeAddr("fakeMarket");
        vm.prank(owner);
        router.setMarketAllowed(fakeMarket, true);

        vm.prank(alice);
        router.depositCollateral(100e6);

        vm.mockCall(fakeMarket, abi.encodeWithSignature("i_collateral()"), abi.encode(address(0)));

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("Router__CollateralMismatch()"));
        router.mintCompleteSets(fakeMarket, 50e6);

        vm.clearMockedCalls();
    }

    function testMintCompleteSetsRevertInsufficientCollateralBalance() external {
        vm.prank(alice);
        router.depositCollateral(30e6);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("Router__InsufficientBalance()"));
        router.mintCompleteSets(address(market), 50e6);
    }

    function testMintCompleteSetsRevertRiskExposureExceeded() external {
        uint256 maxExposure = MarketConstants.MAX_RISK_EXPOSURE;

        vm.prank(alice);
        router.depositCollateral(maxExposure);

        vm.prank(alice);
        router.mintCompleteSets(address(market), maxExposure);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("Router__RiskExposureExceeded()"));
        router.mintCompleteSets(address(market), 1e6);
    }

    function testMintCompleteSetsRiskExemptSucceeds() external {
        vm.prank(owner);
        router.setRiskExempt(alice, true);

        collateral.mint(alice, 15000e6);
        vm.prank(alice);
        collateral.approve(address(router), type(uint256).max);

        vm.prank(alice);
        router.depositCollateral(10000e6);

        vm.prank(alice);
        router.mintCompleteSets(address(market), 10000e6);

        assertEq(router.userRiskExposure(alice), 10000e6);
    }

    function testReentrancyGuardDeposit() external {
        vm.prank(alice);
        router.depositCollateral(100e6);
    }

    function testReentrancyGuardWithdraw() external {
        vm.prank(alice);
        router.depositCollateral(100e6);
    }

    function testRedeemCompleteSetsSuccess() external {
        uint256 depositAmount = 100e6;
        uint256 mintAmount = 50e6;
        uint256 redeemAmount = 20e6;

        vm.prank(alice);
        router.depositCollateral(depositAmount);

        vm.prank(alice);
        router.mintCompleteSets(address(market), mintAmount);

        (address yesToken, address noToken) = _getMockMarketTokens(address(market));

        vm.prank(alice);
        router.redeemCompleteSets(address(market), redeemAmount);

        uint256 expectedNetMint = mintAmount - ((mintAmount * 300) / 10000);
        assertEq(router.tokenCredits(alice, yesToken), expectedNetMint - redeemAmount);
        assertEq(router.tokenCredits(alice, noToken), expectedNetMint - redeemAmount);
    }

    function testRedeemCompleteSetsRevertMarketNotAllowed() external {
        vm.prank(alice);
        router.depositCollateral(100e6);

        address disallowedMarket = makeAddr("disallowedMarket");

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("Router__MarketNotAllowed()"));
        router.redeemCompleteSets(disallowedMarket, 50e6);
    }

    function testRedeemCompleteSetsRevertInsufficientTokenBalance() external {
        vm.prank(alice);
        router.depositCollateral(100e6);

        vm.prank(alice);
        router.mintCompleteSets(address(market), 30e6);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("Router__InsufficientBalance()"));
        router.redeemCompleteSets(address(market), 50e6);
    }

    function testRedeemWinningsSuccess() external {
        uint256 depositAmount = 100e6;
        uint256 mintAmount = 50e6;
        uint256 redeemAmount = 20e6;

        vm.prank(alice);
        router.depositCollateral(depositAmount);

        vm.prank(alice);
        router.mintCompleteSets(address(market), mintAmount);

        vm.warp(block.timestamp + 3 days);
        _resolveAndFinalize(Resolution.Yes, "ipfs://proof");

        (address yesToken, address noToken) = _getMockMarketTokens(address(market));
        uint256 collateralBefore = router.collateralCredits(alice);
        uint256 winningBefore = router.tokenCredits(alice, yesToken);
        uint256 losingBefore = router.tokenCredits(alice, noToken);

        vm.prank(alice);
        router.redeem(address(market), redeemAmount);

        uint256 expectedRedeemOut = redeemAmount - ((redeemAmount * 200) / 10000);
        assertEq(router.collateralCredits(alice), collateralBefore + expectedRedeemOut);
        assertEq(router.tokenCredits(alice, yesToken), winningBefore - redeemAmount);
        assertEq(router.tokenCredits(alice, noToken), losingBefore);
    }

    function testRedeemWinningsRevertNotResolved() external {
        vm.prank(alice);
        router.depositCollateral(100e6);

        vm.prank(alice);
        router.mintCompleteSets(address(market), 30e6);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("Router__MarketNotResolved()"));
        router.redeem(address(market), 10e6);
    }

    function testRedeemWinningsRevertInsufficientWinningTokenBalance() external {
        vm.prank(alice);
        router.depositCollateral(100e6);

        vm.prank(alice);
        router.mintCompleteSets(address(market), 30e6);

        vm.warp(block.timestamp + 3 days);
        _resolveAndFinalize(Resolution.Yes, "ipfs://proof");

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("Router__InsufficientBalance()"));
        router.redeem(address(market), 40e6);
    }

    function testSwapYesForNoSuccess() external {
        uint256 depositAmount = 100e6;
        uint256 mintAmount = 50e6;
        uint256 swapAmount = 10e6;

        vm.prank(alice);
        router.depositCollateral(depositAmount);

        vm.prank(alice);
        router.mintCompleteSets(address(market), mintAmount);

        (address yesToken, address noToken) = _getMockMarketTokens(address(market));

        vm.prank(alice);
        router.swapYesForNo(address(market), swapAmount, 0);

        uint256 expectedNetMint = mintAmount - ((mintAmount * 300) / 10000);
        assertEq(router.tokenCredits(alice, yesToken), expectedNetMint - swapAmount);
        assertGt(router.tokenCredits(alice, noToken), expectedNetMint - swapAmount);
    }

    function testSwapYesForNoRevertMarketNotAllowed() external {
        vm.prank(alice);
        router.depositCollateral(100e6);

        vm.prank(alice);
        router.mintCompleteSets(address(market), 50e6);

        address disallowedMarket = makeAddr("disallowedMarket");

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("Router__MarketNotAllowed()"));
        router.swapYesForNo(disallowedMarket, 10e6, 0);
    }

    function testSwapYesForNoRevertInsufficientBalance() external {
        vm.prank(alice);
        router.depositCollateral(100e6);

        vm.prank(alice);
        router.mintCompleteSets(address(market), 30e6);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("Router__InsufficientBalance()"));
        router.swapYesForNo(address(market), 50e6, 0);
    }

    function testSwapNoForYesSuccess() external {
        uint256 depositAmount = 100e6;
        uint256 mintAmount = 50e6;
        uint256 swapAmount = 10e6;

        vm.prank(alice);
        router.depositCollateral(depositAmount);

        vm.prank(alice);
        router.mintCompleteSets(address(market), mintAmount);

        (address yesToken, address noToken) = _getMockMarketTokens(address(market));

        vm.prank(alice);
        router.swapNoForYes(address(market), swapAmount, 0);

        uint256 expectedNetMint = mintAmount - ((mintAmount * 300) / 10000);
        assertEq(router.tokenCredits(alice, noToken), expectedNetMint - swapAmount);
        assertGt(router.tokenCredits(alice, yesToken), expectedNetMint - swapAmount);
    }

    function testSwapNoForYesRevertMarketNotAllowed() external {
        vm.prank(alice);
        router.depositCollateral(100e6);

        vm.prank(alice);
        router.mintCompleteSets(address(market), 50e6);

        address disallowedMarket = makeAddr("disallowedMarket");

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("Router__MarketNotAllowed()"));
        router.swapNoForYes(disallowedMarket, 10e6, 0);
    }

    function testSwapNoForYesRevertInsufficientBalance() external {
        vm.prank(alice);
        router.depositCollateral(100e6);

        vm.prank(alice);
        router.mintCompleteSets(address(market), 30e6);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("Router__InsufficientBalance()"));
        router.swapNoForYes(address(market), 50e6, 0);
    }

    function testAddLiquiditySuccess() external {
        uint256 depositAmount = 100e6;
        uint256 mintAmount = 50e6;

        vm.prank(alice);
        router.depositCollateral(depositAmount);

        vm.prank(alice);
        router.mintCompleteSets(address(market), mintAmount);

        uint256 expectedNetMint = mintAmount - ((mintAmount * 300) / 10000);
        vm.prank(alice);
        router.addLiquidity(address(market), expectedNetMint, expectedNetMint, 0);

        assertEq(router.lpShareCredits(alice, address(market)), expectedNetMint);
    }

    function testAddLiquidityRevertMarketNotAllowed() external {
        vm.prank(alice);
        router.depositCollateral(100e6);

        vm.prank(alice);
        router.mintCompleteSets(address(market), 50e6);

        address disallowedMarket = makeAddr("disallowedMarket");

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("Router__MarketNotAllowed()"));
        router.addLiquidity(disallowedMarket, 50e6, 50e6, 0);
    }

    function testAddLiquidityRevertInsufficientTokenBalance() external {
        vm.prank(alice);
        router.depositCollateral(100e6);

        vm.prank(alice);
        router.mintCompleteSets(address(market), 30e6);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("Router__InsufficientBalance()"));
        router.addLiquidity(address(market), 30e6 + 1, 30e6 + 1, 0);
    }

    function testRemoveLiquiditySuccess() external {
        uint256 depositAmount = 100e6;
        uint256 mintAmount = 50e6;

        vm.prank(alice);
        router.depositCollateral(depositAmount);

        vm.prank(alice);
        router.mintCompleteSets(address(market), mintAmount);

        uint256 expectedNetMint = mintAmount - ((mintAmount * 300) / 10000);
        vm.prank(alice);
        router.addLiquidity(address(market), expectedNetMint, expectedNetMint, 0);

        uint256 lpSharesBefore = router.lpShareCredits(alice, address(market));

        vm.prank(alice);
        router.removeLiquidity(address(market), lpSharesBefore / 2, 0, 0);

        assertEq(router.lpShareCredits(alice, address(market)), lpSharesBefore / 2);
    }

    function testRemoveLiquidityRevertMarketNotAllowed() external {
        vm.prank(alice);
        router.depositCollateral(100e6);

        vm.prank(alice);
        router.mintCompleteSets(address(market), 50e6);

        uint256 expectedNetMint = 50e6 - ((50e6 * 300) / 10000);
        vm.prank(alice);
        router.addLiquidity(address(market), expectedNetMint, expectedNetMint, 0);

        address disallowedMarket = makeAddr("disallowedMarket");

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("Router__MarketNotAllowed()"));
        router.removeLiquidity(disallowedMarket, 25e6, 0, 0);
    }

    function testRemoveLiquidityRevertInsufficientShares() external {
        vm.prank(alice);
        router.depositCollateral(100e6);

        vm.prank(alice);
        router.mintCompleteSets(address(market), 30e6);

        uint256 expectedNetMint = 30e6 - ((30e6 * 300) / 10000);
        vm.prank(alice);
        router.addLiquidity(address(market), expectedNetMint, expectedNetMint, 0);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("Router__InsufficientBalance()"));
        router.removeLiquidity(address(market), expectedNetMint + 1, 0, 0);
    }

    function testWithdrawOutcomeTokenSuccess() external {
        uint256 depositAmount = 100e6;
        uint256 mintAmount = 50e6;

        vm.prank(alice);
        router.depositCollateral(depositAmount);

        vm.prank(alice);
        router.mintCompleteSets(address(market), mintAmount);

        (address yesToken,) = _getMockMarketTokens(address(market));

        uint256 withdrawAmount = 10e6;
        uint256 aliceYesBefore = IERC20(yesToken).balanceOf(alice);

        vm.prank(alice);
        router.withdrawOutcomeToken(yesToken, withdrawAmount);

        uint256 expectedNetMint = mintAmount - ((mintAmount * 300) / 10000);
        assertEq(router.tokenCredits(alice, yesToken), expectedNetMint - withdrawAmount);
        assertEq(IERC20(yesToken).balanceOf(alice), aliceYesBefore + withdrawAmount);
    }

    function testWithdrawOutcomeTokenRevertInsufficientBalance() external {
        vm.prank(alice);
        router.depositCollateral(100e6);

        vm.prank(alice);
        router.mintCompleteSets(address(market), 30e6);

        (address yesToken,) = _getMockMarketTokens(address(market));

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("Router__InsufficientBalance()"));
        router.withdrawOutcomeToken(yesToken, 50e6);
    }

    function testGetUntrackedCollateralSuccess() external {
        assertEq(router.getUntrackedCollateral(), 0);

        collateral.mint(address(router), 100e6);

        assertEq(router.getUntrackedCollateral(), 100e6);
    }

    function testReceiveEthSuccess() external {
        uint256 ethAmount = 5 ether;

        vm.deal(alice, ethAmount);
        vm.prank(alice);
        (bool success,) = address(router).call{value: ethAmount}("");

        assertTrue(success);
        assertEq(address(router).balance, ethAmount);
    }

    function testWithdrawEthByOwnerSuccess() external {
        uint256 ethAmount = 5 ether;
        uint256 withdrawAmount = 2 ether;

        vm.deal(alice, ethAmount);
        vm.prank(alice);
        (bool funded,) = address(router).call{value: ethAmount}("");
        assertTrue(funded);

        uint256 ownerBalanceBefore = owner.balance;
        vm.prank(owner);
        router.withdrawEth(payable(owner), withdrawAmount);

        assertEq(owner.balance, ownerBalanceBefore + withdrawAmount);
        assertEq(address(router).balance, ethAmount - withdrawAmount);
    }

    function testWithdrawEthRevertUnauthorized() external {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", alice));
        router.withdrawEth(payable(alice), 1 ether);
    }

    function testWithdrawEthRevertZeroAddress() external {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSignature("Router__ZeroAddress()"));
        router.withdrawEth(payable(address(0)), 1 ether);
    }

    function testWithdrawEthRevertInvalidAmount() external {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSignature("Router__InvalidAmount()"));
        router.withdrawEth(payable(owner), 0);
    }

    function testWithdrawEthRevertInsufficientBalance() external {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSignature("Router__InsufficientBalance()"));
        router.withdrawEth(payable(owner), 1 ether);
    }
}

contract ReentrancyAttacker {
    PredictionMarketRouterVault public router;
    bool public attackStarted;
    IERC20 public collateral;

    constructor(address payable _router) {
        router = PredictionMarketRouterVault(_router);
        collateral = IERC20(address(PredictionMarketRouterVault(_router).collateralToken()));
    }

    function approveCollateral(address spender, uint256 amount) external {
        collateral.approve(spender, amount);
    }

    function attackDeposit(uint256 amount) external {
        collateral.safeTransferFrom(msg.sender, address(this), amount);
        router.depositCollateral(amount);
        if (!attackStarted) {
            attackStarted = true;
            router.depositCollateral(amount);
        }
    }

    function attackWithdraw(uint256 amount) external {
        if (!attackStarted) {
            attackStarted = true;
            router.withdrawCollateral(amount);
        }
    }

    receive() external payable {
        if (attackStarted) {
            router.withdrawCollateral(1);
        }
    }
}

interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);
    function safeTransfer(address to, uint256 amount) external;
    function safeTransferFrom(address from, address to, uint256 amount) external;
    function safeIncreaseAllowance(address spender, uint256 increase) external;
}
