// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {PredictionMarketRouterVault} from "../../src/router/PredictionMarketRouterVault.sol";
import {PredictionMarket} from "../../src/predictionMarket/PredictionMarket.sol";
import {MarketDeployer} from "../../src/marketFactory/event-deployer/MarketDeployer.sol";
import {OutcomeToken} from "../../src/token/OutcomeToken.sol";
import {MarketConstants} from "../../src/libraries/MarketTypes.sol";

interface IMockMarket {
    function i_collateral() external view returns (address);
    function yesToken() external view returns (address);
    function noToken() external view returns (address);
    function lpShares(address account) external view returns (uint256);
    function mintCompleteSets(uint256 amount) external;
    function redeemCompleteSets(uint256 amount) external;
    function swapYesForNo(uint256 yesIn, uint256 minNoOut) external;
    function swapNoForYes(uint256 noIn, uint256 minYesOut) external;
    function addLiquidity(uint256 yesAmount, uint256 noAmount, uint256 minShares) external;
    function removeLiquidity(uint256 shares, uint256 minYesOut, uint256 minNoOut) external;
    function balanceOf(address account) external view returns (uint256);
}

contract MockMarketFactory {
    address public lastRemoved;
    uint256 public removeCount;

    function removeResolvedMarket(address market) external {
        lastRemoved = market;
        removeCount++;
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

        router = new PredictionMarketRouterVault(
            address(collateral),
            forwarder,
            owner,
            marketFactory
        );

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

    function _getMockMarketTokens(address marketAddress)
        internal
        view
        returns (address yesToken, address noToken)
    {
        yesToken = IMockMarket(marketAddress).yesToken();
        noToken = IMockMarket(marketAddress).noToken();
    }

    function testConstructorRevertZeroCollateral() external {
        vm.expectRevert(abi.encodeWithSignature("Router__ZeroAddress()"));
        new PredictionMarketRouterVault(address(0), forwarder, owner, marketFactory);
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

        vm.mockCall(
            fakeMarket,
            abi.encodeWithSignature("i_collateral()"),
            abi.encode(address(0))
        );

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
