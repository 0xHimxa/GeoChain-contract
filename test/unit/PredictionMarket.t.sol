// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {PredictionMarket} from "src/PredictionMarket.sol";
import {OutcomeToken} from "src/OutcomeToken.sol";
import {AMMLib} from "src/libraries/AMMLib.sol";
import {MarketErrors, MarketConstants, Resolution, State} from "src/libraries/MarketTypes.sol";

contract MockMarketFactory {
    address public lastRemoved;
    uint256 public removeCount;
    bool public isHubFactory;
    Resolution public lastHubOutcome;
    string public lastHubProofUrl;
    uint256 public onHubResolvedCount;

    function removeResolvedMarket(address market) external {
        lastRemoved = market;
        removeCount++;
    }

    function setIsHubFactory(bool value) external {
        isHubFactory = value;
    }

    function onHubMarketResolved(Resolution outcome, string calldata proofUrl) external {
        lastHubOutcome = outcome;
        lastHubProofUrl = proofUrl;
        onHubResolvedCount++;
    }
}

contract PredictionMarketTest is Test {
    OutcomeToken internal collateral;
    PredictionMarket internal market;
    MockMarketFactory internal mockFactory;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal constant FORWARDER = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8;

    uint256 internal constant INITIAL_LIQUIDITY = 10_000e6;

    function setUp() external {
        collateral = new OutcomeToken("USDC", "USDC", address(this));
        mockFactory = new MockMarketFactory();

        market = new PredictionMarket(
            "Will ETH be above $5000 by year end?",
            address(collateral),
            block.timestamp + 1 days,
            block.timestamp + 2 days,
            address(mockFactory),
            FORWARDER
        );

        collateral.mint(address(market), INITIAL_LIQUIDITY);
        market.seedLiquidity(INITIAL_LIQUIDITY);
    }

    function _fundAndApproveCollateral(address user, uint256 amount) internal {
        collateral.mint(user, amount);
        vm.prank(user);
        collateral.approve(address(market), type(uint256).max);
    }

    function _mintCompleteSets(address user, uint256 amount) internal returns (uint256 netAmount) {
        _fundAndApproveCollateral(user, amount);
        vm.prank(user);
        market.mintCompleteSets(amount);

        (, uint256 fee) = _deductFee(amount, MarketConstants.MINT_COMPLETE_SETS_FEE_BPS, MarketConstants.FEE_PRECISION_BPS);
        netAmount = amount - fee;
    }

    function _approveOutcomeTokens(address user) internal {
        vm.startPrank(user);
        market.yesToken().approve(address(market), type(uint256).max);
        market.noToken().approve(address(market), type(uint256).max);
        vm.stopPrank();
    }

    function _deductFee(uint256 amount, uint256 feeBps, uint256 precision)
        internal
        pure
        returns (uint256 netAmount, uint256 fee)
    {
        fee = (amount * feeBps) / precision;
        netAmount = amount - fee;
    }

    function _warpAfterResolution() internal {
        vm.warp(market.resolutionTime() + 1);
    }

    function _newUnseededMarket() internal returns (PredictionMarket m) {
        m = new PredictionMarket(
            "Unseeded market",
            address(collateral),
            block.timestamp + 1 days,
            block.timestamp + 2 days,
            address(mockFactory),
            FORWARDER
        );
    }

    function testConstructorRevertInvalidArguments() external {
        vm.expectRevert(MarketErrors.PredictionMarket__InvalidArguments_PassedInConstructor.selector);
        new PredictionMarket("", address(collateral), 1, 2, address(mockFactory), FORWARDER);

        vm.expectRevert(MarketErrors.PredictionMarket__InvalidArguments_PassedInConstructor.selector);
        new PredictionMarket("q", address(0), 1, 2, address(mockFactory), FORWARDER);

        vm.expectRevert(MarketErrors.PredictionMarket__CloseTimeGreaterThanResolutionTime.selector);
        new PredictionMarket("q", address(collateral), 3, 2, address(mockFactory), FORWARDER);
    }

    function testSeedLiquidityRevertWhenAlreadySeeded() external {
        collateral.mint(address(market), 100e6);
        vm.expectRevert(MarketErrors.PredictionMarket__InitailConstantLiquidityAlreadySet.selector);
        market.seedLiquidity(100e6);
    }

    function testSeedLiquidityRevertWhenAmountZero() external {
        PredictionMarket unseeded = _newUnseededMarket();
        vm.expectRevert(MarketErrors.PredictionMarket__InitailConstantLiquidityFundedAmountCantBeZero.selector);
        unseeded.seedLiquidity(0);
    }

    function testSeedLiquidityRevertWhenFundingGreaterThanBalance() external {
        PredictionMarket unseeded = _newUnseededMarket();
        vm.expectRevert(MarketErrors.PredictionMarket__FundingInitailAountGreaterThanAmountSent.selector);
        unseeded.seedLiquidity(1e6);
    }

    function testMintCompleteSetsSuccess() external {
        uint256 amount = 10e6;
        uint256 expectedNet = _mintCompleteSets(alice, amount);

        assertEq(market.yesToken().balanceOf(alice), expectedNet);
        assertEq(market.noToken().balanceOf(alice), expectedNet);
        assertEq(market.userRiskExposure(alice), amount);
        assertEq(market.protocolCollateralFees(), (amount * 300) / 10_000);
    }

    function testMintCompleteSetsRevertRiskExposureExceeded() external {
        uint256 cap = MarketConstants.MAX_RISK_EXPOSURE;

        _mintCompleteSets(alice, cap);

        _fundAndApproveCollateral(alice, 1e6);
        vm.prank(alice);
        vm.expectRevert(MarketErrors.PredictionMarket__RiskExposureExceeded.selector);
        market.mintCompleteSets(1e6);
    }

    function testRedeemCompleteSetsSuccess() external {
        uint256 mintAmount = 10e6;
        uint256 mintedNet = _mintCompleteSets(alice, mintAmount);
        uint256 redeemAmount = 2e6;

        uint256 beforeCollateral = collateral.balanceOf(alice);

        vm.prank(alice);
        market.redeemCompleteSets(redeemAmount);

        uint256 expectedCollateralOut = redeemAmount - ((redeemAmount * 200) / 10_000);

        assertEq(market.yesToken().balanceOf(alice), mintedNet - redeemAmount);
        assertEq(market.noToken().balanceOf(alice), mintedNet - redeemAmount);
        assertEq(collateral.balanceOf(alice), beforeCollateral + expectedCollateralOut);
    }

    function testAddLiquiditySuccess() external {
        uint256 mintedNet = _mintCompleteSets(alice, 10e6);
        _approveOutcomeTokens(alice);

        uint256 yesReserveBefore = market.yesReserve();
        uint256 noReserveBefore = market.noReserve();

        vm.prank(alice);
        market.addLiquidity(mintedNet, mintedNet, 0);

        assertEq(market.lpShares(alice), mintedNet);
        assertEq(market.totalShares(), INITIAL_LIQUIDITY + mintedNet);
        assertEq(market.yesReserve(), yesReserveBefore + mintedNet);
        assertEq(market.noReserve(), noReserveBefore + mintedNet);
    }

    function testAddLiquidityRevertWhenNotSeeded() external {
        PredictionMarket unseeded = _newUnseededMarket();
        vm.expectRevert(MarketErrors.PredictionMarket__InitailConstantLiquidityNotSetYet.selector);
        unseeded.addLiquidity(50, 50, 0);
    }

    function testAddLiquidityRevertWhenAmountsZero() external {
        vm.expectRevert(MarketErrors.PredictionMarket__AddLiquidity_YesAndNoCantBeZero.selector);
        market.addLiquidity(0, 0, 0);
    }

    function testAddLiquidityRevertWhenBelowMinimumShare() external {
        uint256 mintedNet = _mintCompleteSets(alice, 10e6);
        _approveOutcomeTokens(alice);

        vm.prank(alice);
        vm.expectRevert(MarketErrors.PredictionMarket__AddLiquidity_Yes_No_LessThanMiniMum.selector);
        market.addLiquidity(mintedNet, 49, 0);
    }

    function testAddLiquidityRevertWhenInsufficientTokenBalance() external {
        uint256 mintedNet = _mintCompleteSets(alice, 10e6);
        _approveOutcomeTokens(alice);

        vm.prank(alice);
        vm.expectRevert(MarketErrors.PredictionMarket__AddLiquidity_InsuffientTokenBalance.selector);
        market.addLiquidity(mintedNet + 1, mintedNet, 0);
    }

    function testAddLiquidityRevertWhenMinSharesTooHigh() external {
        uint256 mintedNet = _mintCompleteSets(alice, 10e6);
        _approveOutcomeTokens(alice);

        vm.prank(alice);
        vm.expectRevert(MarketErrors.PredictionMarket__AddLiquidity_ShareSendingIsLessThanMinShares.selector);
        market.addLiquidity(mintedNet, mintedNet, mintedNet + 1);
    }

    function testRemoveLiquiditySuccess() external {
        uint256 sharesToRemove = 100e6;

        uint256 beforeYes = market.yesToken().balanceOf(address(this));
        uint256 beforeNo = market.noToken().balanceOf(address(this));

        market.removeLiquidity(sharesToRemove, 0, 0);

        assertEq(market.yesToken().balanceOf(address(this)), beforeYes + sharesToRemove);
        assertEq(market.noToken().balanceOf(address(this)), beforeNo + sharesToRemove);
        assertEq(market.lpShares(address(this)), INITIAL_LIQUIDITY - sharesToRemove);
        assertEq(market.totalShares(), INITIAL_LIQUIDITY - sharesToRemove);
    }

    function testRemoveLiquidityRevertWhenZeroShares() external {
        vm.expectRevert(MarketErrors.PredictionMarket__WithDrawLiquidity_ZeroSharesPassedIn.selector);
        market.removeLiquidity(0, 0, 0);
    }

    function testRemoveLiquidityRevertWhenInsufficientShares() external {
        vm.expectRevert(MarketErrors.PredictionMarket__WithDrawLiquidity_InsufficientSharesBalance.selector);
        market.removeLiquidity(INITIAL_LIQUIDITY + 1, 0, 0);
    }

    function testRemoveLiquidityRevertWhenSlippageExceeded() external {
        vm.expectRevert(MarketErrors.PredictionMarket__WithDrawLiquidity_SlippageExceeded.selector);
        market.removeLiquidity(100e6, 101e6, 0);
    }

    function testRemoveLiquidityAndRedeemCollateralSuccess() external {
        uint256 sharesToRemove = 100e6;
        uint256 beforeCollateral = collateral.balanceOf(address(this));

        market.removeLiquidityAndRedeemCollateral(sharesToRemove, 0);

        uint256 expectedOut = sharesToRemove - ((sharesToRemove * 200) / 10_000);
        assertEq(collateral.balanceOf(address(this)), beforeCollateral + expectedOut);
        assertEq(market.lpShares(address(this)), INITIAL_LIQUIDITY - sharesToRemove);
    }

    function testRemoveLiquidityAndRedeemCollateralRevertWhenZeroShares() external {
        vm.expectRevert(MarketErrors.PredictionMarket__WithDrawLiquidity_ZeroSharesPassedIn.selector);
        market.removeLiquidityAndRedeemCollateral(0, 0);
    }

    function testRemoveLiquidityAndRedeemCollateralRevertWhenInsufficientShares() external {
        vm.expectRevert(MarketErrors.PredictionMarket__WithDrawLiquidity_InsufficientSharesBalance.selector);
        market.removeLiquidityAndRedeemCollateral(INITIAL_LIQUIDITY + 1, 0);
    }

    function testRemoveLiquidityAndRedeemCollateralRevertWhenSlippageExceeded() external {
        vm.expectRevert(MarketErrors.PredictionMarket__WithDrawLiquidity_SlippageExceeded.selector);
        market.removeLiquidityAndRedeemCollateral(100e6, 100e6);
    }

    function testRemoveLiquidityAndRedeemCollateralReturnsLeftoverTokens() external {
        _mintCompleteSets(alice, 10e6);
        _approveOutcomeTokens(alice);

        vm.prank(alice);
        market.swapYesForNo(1e6, 0);

        uint256 yesBefore = market.yesToken().balanceOf(address(this));
        uint256 noBefore = market.noToken().balanceOf(address(this));
        market.removeLiquidityAndRedeemCollateral(5_000e6, 0);
        uint256 yesAfter = market.yesToken().balanceOf(address(this));
        uint256 noAfter = market.noToken().balanceOf(address(this));

        assertTrue(yesAfter > yesBefore || noAfter > noBefore);
    }

    function testTransferSharesSuccess() external {
        uint256 transferAmount = 250e6;

        market.transferShares(bob, transferAmount);

        assertEq(market.lpShares(address(this)), INITIAL_LIQUIDITY - transferAmount);
        assertEq(market.lpShares(bob), transferAmount);
    }

    function testTransferSharesRevertZeroAddress() external {
        vm.expectRevert(MarketErrors.PredictionMarket__TransferShares_CantbeSendtoZeroAddress.selector);
        market.transferShares(address(0), 1);
    }

    function testTransferSharesRevertInsufficientShares() external {
        vm.expectRevert(MarketErrors.PredictionMarket__TransferShares_InsufficientShares.selector);
        vm.prank(alice);
        market.transferShares(bob, 1);
    }

    function testSwapYesForNoSuccess() external {
        uint256 mintedNet = _mintCompleteSets(alice, 10e6);
        _approveOutcomeTokens(alice);

        uint256 yesIn = 1e6;
        uint256 noBefore = market.noToken().balanceOf(alice);
        uint256 yesReserveBefore = market.yesReserve();
        uint256 noReserveBefore = market.noReserve();

        (uint256 quoteOut,) = market.getYesForNoQuote(yesIn);

        vm.prank(alice);
        market.swapYesForNo(yesIn, quoteOut);

        assertEq(market.noToken().balanceOf(alice), noBefore + quoteOut);
        assertEq(market.yesReserve(), yesReserveBefore + yesIn);
        assertEq(market.noReserve(), noReserveBefore - quoteOut);
        assertEq(market.yesToken().balanceOf(alice), mintedNet - yesIn);
    }

    function testSwapNoForYesSuccess() external {
        uint256 mintedNet = _mintCompleteSets(alice, 10e6);
        _approveOutcomeTokens(alice);

        uint256 noIn = 1e6;
        uint256 yesBefore = market.yesToken().balanceOf(alice);
        uint256 yesReserveBefore = market.yesReserve();
        uint256 noReserveBefore = market.noReserve();

        (uint256 quoteOut,) = market.getNoForYesQuote(noIn);

        vm.prank(alice);
        market.swapNoForYes(noIn, quoteOut);

        assertEq(market.yesToken().balanceOf(alice), yesBefore + quoteOut);
        assertEq(market.noReserve(), noReserveBefore + noIn);
        assertEq(market.yesReserve(), yesReserveBefore - quoteOut);
        assertEq(market.noToken().balanceOf(alice), mintedNet - noIn);
    }

    function testSwapRevertWhenBelowMinimumAmount() external {
        _mintCompleteSets(alice, 10e6);
        _approveOutcomeTokens(alice);

        vm.prank(alice);
        vm.expectRevert(MarketErrors.PredictionMarket__AmountLessThanMinSwapAllwed.selector);
        market.swapYesForNo(100, 0);

        vm.prank(alice);
        vm.expectRevert(MarketErrors.PredictionMarket__AmountLessThanMinSwapAllwed.selector);
        market.swapNoForYes(100, 0);
    }

    function testSwapYesForNoRevertWhenInsufficientYesBalance() external {
        vm.expectRevert(MarketErrors.PredictionMarket__SwapYesFoNo_YesExeedBalannce.selector);
        vm.prank(alice);
        market.swapYesForNo(1e6, 0);
    }

    function testSwapNoForYesRevertWhenInsufficientNoBalance() external {
        vm.expectRevert(MarketErrors.PredictionMarket__SwapNoFoYes_NoExeedBalannce.selector);
        vm.prank(alice);
        market.swapNoForYes(1e6, 0);
    }

    function testSwapYesForNoRevertWhenSlippageExceeded() external {
        _mintCompleteSets(alice, 10e6);
        _approveOutcomeTokens(alice);

        (uint256 quoteOut,) = market.getYesForNoQuote(1e6);
        vm.prank(alice);
        vm.expectRevert(MarketErrors.PredictionMarket__SwapingExceedSlippage.selector);
        market.swapYesForNo(1e6, quoteOut + 1);
    }

    function testSwapNoForYesRevertWhenSlippageExceeded() external {
        _mintCompleteSets(alice, 10e6);
        _approveOutcomeTokens(alice);

        (uint256 quoteOut,) = market.getNoForYesQuote(1e6);
        vm.prank(alice);
        vm.expectRevert(MarketErrors.PredictionMarket__SwapingExceedSlippage.selector);
        market.swapNoForYes(1e6, quoteOut + 1);
    }

    function testSwapYesForNoRevertWhenCanonicalDeviationTooHigh() external {
        market.setCrossChainController(address(this));
        market.syncCanonicalPriceFromHub(900_000, 100_000, block.timestamp + 1 days, 1);
        uint256 mintedNet = _mintCompleteSets(alice, 3_000e6);
        _approveOutcomeTokens(alice);
        assertGt(mintedNet, 2_000e6);

        vm.prank(alice);
        vm.expectRevert(PredictionMarket.PredictionMarket__CanonicalPriceDeviationTooHigh.selector);
        market.swapYesForNo(2_000e6, 0);
    }

    function testSwapNoForYesCanonicalSuccess() external {
        market.setCrossChainController(address(this));
        market.syncCanonicalPriceFromHub(520_000, 480_000, block.timestamp + 1 days, 1);
        _mintCompleteSets(alice, 10e6);
        _approveOutcomeTokens(alice);

        uint256 beforeYes = market.yesToken().balanceOf(alice);
        (uint256 quoteOut,) = market.getNoForYesQuote(1e6);
        vm.prank(alice);
        market.swapNoForYes(1e6, quoteOut);
        assertEq(market.yesToken().balanceOf(alice), beforeYes + quoteOut);
    }

    function testSwapNoForYesRevertWhenCanonicalDeviationTooHigh() external {
        market.setCrossChainController(address(this));
        market.syncCanonicalPriceFromHub(100_000, 900_000, block.timestamp + 1 days, 1);
        _mintCompleteSets(alice, 3_000e6);
        _approveOutcomeTokens(alice);

        vm.prank(alice);
        vm.expectRevert(PredictionMarket.PredictionMarket__CanonicalPriceDeviationTooHigh.selector);
        market.swapNoForYes(2_000e6, 0);
    }

    function testMintRevertWhenMarketClosed() external {
        vm.warp(market.closeTime() + 1);

        _fundAndApproveCollateral(alice, 2e6);

        vm.prank(alice);
        vm.expectRevert(MarketErrors.PredictionMarket__Isclosed.selector);
        market.mintCompleteSets(2e6);
    }

    function testMintRevertWhenAmountZero() external {
        vm.prank(alice);
        vm.expectRevert(MarketErrors.PredictionMarket__AmountCantBeZero.selector);
        market.mintCompleteSets(0);
    }

    function testMintRevertWhenAmountBelowMinimum() external {
        _fundAndApproveCollateral(alice, 900_000);
        vm.prank(alice);
        vm.expectRevert(MarketErrors.PredictionMarket__MintingCompleteset__AmountLessThanMinimu.selector);
        market.mintCompleteSets(900_000);
    }

    function testMintRevertWhenInsufficientCollateralBalance() external {
        vm.prank(alice);
        vm.expectRevert(MarketErrors.PredictionMarket__MintCompleteSets_InsuffientTokenBalance.selector);
        market.mintCompleteSets(2e6);
    }

    function testMintRevertWhenMarketInReview() external {
        _warpAfterResolution();
        market.resolve(Resolution.Inconclusive, "ipfs://initial");

        _fundAndApproveCollateral(alice, 2e6);
        vm.prank(alice);
        vm.expectRevert(MarketErrors.PredictionMarket__IsUnderManualReview.selector);
        market.mintCompleteSets(2e6);
    }

    function testMintRevertWhenResolved() external {
        _warpAfterResolution();
        market.resolve(Resolution.Yes, "ipfs://proof");

        _fundAndApproveCollateral(alice, 2e6);
        vm.prank(alice);
        vm.expectRevert(MarketErrors.PredictionMarket__AlreadyResolved.selector);
        market.mintCompleteSets(2e6);
    }

    function testResolveRevertConditions() external {
        vm.expectRevert(MarketErrors.PredictionMarket__ProofUrlCantBeEmpty.selector);
        market.resolve(Resolution.Yes, "");

        vm.expectRevert(MarketErrors.PredictionMarket__ResolveTimeNotReached.selector);
        market.resolve(Resolution.Yes, "ipfs://proof");

        _warpAfterResolution();
        market.resolve(Resolution.Inconclusive, "ipfs://initial");

        vm.expectRevert(MarketErrors.PredictionMarket__MarketNotClosed.selector);
        market.resolve(Resolution.Yes, "ipfs://proof");
    }

    function testForwarderOnReportCanResolveMarket() external {
        _warpAfterResolution();
        bytes memory report = abi.encode("ResolveMarket", abi.encode(Resolution.Yes, "ipfs://proof"));

        vm.prank(FORWARDER);
        market.onReport("", report);

        assertEq(uint256(market.state()), uint256(State.Resolved));
        assertEq(uint256(market.resolution()), uint256(Resolution.Yes));
    }

    function testResolveRevertsWhenLocalResolutionDisabledOnSpoke() external {
        market.setCrossChainController(alice);
        _warpAfterResolution();

        vm.expectRevert(PredictionMarket.PredictionMarket__LocalResolutionDisabled.selector);
        market.resolve(Resolution.Yes, "ipfs://proof");
    }

    function testResolveYesSuccess() external {
        _warpAfterResolution();

        market.resolve(Resolution.Yes, "ipfs://proof");

        assertEq(uint256(market.state()), uint256(State.Resolved));
        assertEq(uint256(market.resolution()), uint256(Resolution.Yes));
        assertEq(mockFactory.lastRemoved(), address(market));
        assertEq(mockFactory.removeCount(), 1);
    }

    function testResolveInconclusiveThenManualResolve() external {
        _warpAfterResolution();

        market.resolve(Resolution.Inconclusive, "ipfs://initial");

        assertEq(uint256(market.state()), uint256(State.Review));
        assertEq(uint256(market.resolution()), uint256(Resolution.Inconclusive));

        market.manualResolveMarket(Resolution.No, "ipfs://manual");

        assertEq(uint256(market.state()), uint256(State.Resolved));
        assertEq(uint256(market.resolution()), uint256(Resolution.No));
        assertEq(mockFactory.removeCount(), 1);
    }

    function testManualResolveRevertsWhenLocalResolutionDisabledOnSpoke() external {
        _warpAfterResolution();
        market.resolve(Resolution.Inconclusive, "ipfs://initial");
        market.setCrossChainController(alice);

        vm.expectRevert(PredictionMarket.PredictionMarket__LocalResolutionDisabled.selector);
        market.manualResolveMarket(Resolution.No, "ipfs://manual");
    }

    function testResolveNotifiesHubFactoryWhenControllerSet() external {
        mockFactory.setIsHubFactory(true);
        market.setCrossChainController(alice);
        _warpAfterResolution();

        market.resolve(Resolution.Yes, "ipfs://hub-proof");

        assertEq(uint256(mockFactory.lastHubOutcome()), uint256(Resolution.Yes));
        assertEq(mockFactory.lastHubProofUrl(), "ipfs://hub-proof");
        assertEq(mockFactory.onHubResolvedCount(), 1);
    }

    function testManualResolveRevertWhenInvalidOutcome() external {
        _warpAfterResolution();
        market.resolve(Resolution.Inconclusive, "ipfs://initial");

        vm.expectRevert(MarketErrors.PredictionMarket__InvalidFinalOutcome.selector);
        market.manualResolveMarket(Resolution.Inconclusive, "ipfs://manual");
    }

    function testManualResolveRevertProofEmpty() external {
        _warpAfterResolution();
        market.resolve(Resolution.Inconclusive, "ipfs://initial");
        vm.expectRevert(MarketErrors.PredictionMarket__ProofUrlCantBeEmpty.selector);
        market.manualResolveMarket(Resolution.Yes, "");
    }

    function testManualResolveRevertMarketNotInReview() external {
        vm.expectRevert(MarketErrors.PredictionMarket__MarketNotInReview.selector);
        market.manualResolveMarket(Resolution.Yes, "ipfs://manual");
    }

    function testManualResolveRevertManualReviewFlagFalse() external {
        _warpAfterResolution();
        market.resolve(Resolution.Inconclusive, "ipfs://initial");

        bytes32 slot13 = vm.load(address(market), bytes32(uint256(13)));
        bytes32 clearManualReviewMask = ~(bytes32(uint256(0xff)) << (8 * 2));
        vm.store(address(market), bytes32(uint256(13)), slot13 & clearManualReviewMask);

        vm.expectRevert(MarketErrors.PredictionMarket__ManualReviewNeeded.selector);
        market.manualResolveMarket(Resolution.Yes, "ipfs://manual");
    }

    function testRedeemAfterResolutionYes() external {
        _mintCompleteSets(alice, 10e6);
        _warpAfterResolution();
        market.resolve(Resolution.Yes, "ipfs://proof");

        uint256 redeemAmount = 1e6;
        uint256 beforeCollateral = collateral.balanceOf(alice);

        vm.prank(alice);
        market.redeem(redeemAmount);

        uint256 expectedNet = redeemAmount - ((redeemAmount * 200) / 10_000);
        assertEq(collateral.balanceOf(alice), beforeCollateral + expectedNet);
    }

    function testRedeemAfterResolutionNo() external {
        _mintCompleteSets(alice, 10e6);
        _warpAfterResolution();
        market.resolve(Resolution.No, "ipfs://proof");

        uint256 beforeCollateral = collateral.balanceOf(alice);
        vm.prank(alice);
        market.redeem(1e6);
        assertEq(collateral.balanceOf(alice), beforeCollateral + 980_000);
    }

    function testRedeemRevertWhenNotResolved() external {
        vm.prank(alice);
        vm.expectRevert(MarketErrors.PredictionMarket__NotResolved.selector);
        market.redeem(1e6);
    }

    function testRedeemRevertWhenAmountZero() external {
        _warpAfterResolution();
        market.resolve(Resolution.Yes, "ipfs://proof");
        vm.prank(alice);
        vm.expectRevert(MarketErrors.PredictionMarket__AmountCantBeZero.selector);
        market.redeem(0);
    }

    function testWithdrawLiquidityCollateralAfterResolveYes() external {
        _warpAfterResolution();
        market.resolve(Resolution.Yes, "ipfs://proof");

        uint256 sharesToWithdraw = 100e6;
        uint256 beforeCollateral = collateral.balanceOf(address(this));

        market.withdrawLiquidityCollateral(sharesToWithdraw);

        assertEq(collateral.balanceOf(address(this)), beforeCollateral + sharesToWithdraw);
        assertEq(market.lpShares(address(this)), INITIAL_LIQUIDITY - sharesToWithdraw);
    }

    function testWithdrawLiquidityCollateralAfterResolveNo() external {
        _warpAfterResolution();
        market.resolve(Resolution.No, "ipfs://proof");
        uint256 beforeCollateral = collateral.balanceOf(address(this));
        market.withdrawLiquidityCollateral(100e6);
        assertEq(collateral.balanceOf(address(this)), beforeCollateral + 100e6);
    }

    function testWithdrawLiquidityCollateralRevertWhenNotResolved() external {
        vm.expectRevert(MarketErrors.PredictionMarket__StateNeedToResolvedToWithdrawLiquidity.selector);
        market.withdrawLiquidityCollateral(1);
    }

    function testWithdrawLiquidityCollateralRevertWhenZeroShares() external {
        _warpAfterResolution();
        market.resolve(Resolution.Yes, "ipfs://proof");
        vm.expectRevert(MarketErrors.PredictionMarket__WithDrawLiquidity_ZeroSharesPassedIn.selector);
        market.withdrawLiquidityCollateral(0);
    }

    function testWithdrawLiquidityCollateralRevertWhenInsufficientShares() external {
        _warpAfterResolution();
        market.resolve(Resolution.Yes, "ipfs://proof");
        vm.expectRevert(MarketErrors.PredictionMarket__WithDrawLiquidity_InsufficientSharesBalance.selector);
        vm.prank(alice);
        market.withdrawLiquidityCollateral(1);
    }

    function testWithdrawLiquidityCollateralRevertWhenInvalidFinalOutcome() external {
        _warpAfterResolution();
        market.resolve(Resolution.Yes, "ipfs://proof");

        bytes32 slot13 = vm.load(address(market), bytes32(uint256(13)));
        bytes32 clearResolutionMask = ~(bytes32(uint256(0xff)) << 8);
        bytes32 withInconclusiveResolution = (slot13 & clearResolutionMask) | (bytes32(uint256(3)) << 8);
        vm.store(address(market), bytes32(uint256(13)), withInconclusiveResolution);

        vm.expectRevert(MarketErrors.PredictionMarket__InvalidFinalOutcome.selector);
        market.withdrawLiquidityCollateral(1);
    }

    function testWithdrawProtocolFeesSuccessAfterResolution() external {
        uint256 amount = 10e6;
        _mintCompleteSets(alice, amount);

        uint256 expectedFee = (amount * 300) / 10_000;

        _warpAfterResolution();
        market.resolve(Resolution.Yes, "ipfs://proof");

        uint256 beforeOwnerBalance = collateral.balanceOf(address(this));
        market.withdrawProtocolFees(expectedFee);

        assertEq(collateral.balanceOf(address(this)), beforeOwnerBalance + expectedFee);
        assertEq(market.protocolCollateralFees(), 0);
    }

    function testWithdrawProtocolFeesRevertZeroAmount() external {
        _warpAfterResolution();
        market.resolve(Resolution.Yes, "ipfs://proof");
        vm.expectRevert(MarketErrors.PredictionMarket__AmountCantBeZero.selector);
        market.withdrawProtocolFees(0);
    }

    function testWithdrawProtocolFeesRevertStateNotResolved() external {
        vm.expectRevert(MarketErrors.PredictionMarket__StateNeedToResolvedToWithdrawLiquidity.selector);
        market.withdrawProtocolFees(1);
    }

    function testWithdrawProtocolFeesRevertInsufficientFeeBalance() external {
        _mintCompleteSets(alice, 2e6);
        _warpAfterResolution();
        market.resolve(Resolution.Yes, "ipfs://proof");
        uint256 fee = market.protocolCollateralFees();
        assertEq(fee, 60_000);
        vm.expectRevert(MarketErrors.PredictionMarket__WithDrawLiquidity_Insufficientfee.selector);
        market.withdrawProtocolFees(fee + 1);
    }

    function testWithdrawProtocolFeesRevertInsufficientContractBalance() external {
        _mintCompleteSets(alice, 10e6);
        uint256 fee = market.protocolCollateralFees();

        _warpAfterResolution();
        market.resolve(Resolution.Yes, "ipfs://proof");

        uint256 keep = fee - 1;
        uint256 burnAmount = collateral.balanceOf(address(market)) - keep;
        collateral.burn(address(market), burnAmount);

        vm.expectRevert(MarketErrors.PredictionMarket__WithDrawLiquidity_Insufficientfee.selector);
        market.withdrawProtocolFees(fee);
    }

    function testPauseAndUnpauseFlow() external {
        market.pause();

        _fundAndApproveCollateral(alice, 2e6);
        vm.prank(alice);
        vm.expectRevert(MarketErrors.PredictionMarket__IsPaused.selector);
        market.mintCompleteSets(2e6);

        market.unpause();

        vm.prank(alice);
        market.mintCompleteSets(2e6);

        assertGt(market.yesToken().balanceOf(alice), 0);
    }

    function testResolveFromHubAccessAndSuccess() external {
        market.setCrossChainController(alice);

        vm.prank(bob);
        vm.expectRevert(PredictionMarket.PredictionMarket__OnlyCrossChainController.selector);
        market.resolveFromHub(Resolution.Yes, "ipfs://proof");

        vm.prank(alice);
        market.resolveFromHub(Resolution.Yes, "ipfs://proof");

        assertEq(uint256(market.state()), uint256(State.Resolved));
        assertEq(uint256(market.resolution()), uint256(Resolution.Yes));
    }

    function testResolveFromHubRevertConditions() external {
        market.setCrossChainController(address(this));

        vm.expectRevert(MarketErrors.PredictionMarket__ProofUrlCantBeEmpty.selector);
        market.resolveFromHub(Resolution.Yes, "");

        vm.expectRevert(MarketErrors.PredictionMarket__InvalidFinalOutcome.selector);
        market.resolveFromHub(Resolution.Inconclusive, "ipfs://proof");

        market.resolveFromHub(Resolution.Yes, "ipfs://proof");
        vm.expectRevert(MarketErrors.PredictionMarket__AlreadyResolved.selector);
        market.resolveFromHub(Resolution.Yes, "ipfs://proof-2");
    }

    function testSyncCanonicalPriceValidationAndStaleNonce() external {
        market.setCrossChainController(alice);

        vm.prank(alice);
        vm.expectRevert(PredictionMarket.PredictionMarket__InvalidCanonicalPrice.selector);
        market.syncCanonicalPriceFromHub(700_000, 200_000, block.timestamp + 1 days, 1);

        vm.prank(alice);
        market.syncCanonicalPriceFromHub(600_000, 400_000, block.timestamp + 1 days, 2);

        vm.prank(alice);
        vm.expectRevert(PredictionMarket.PredictionMarket__StaleSyncMessage.selector);
        market.syncCanonicalPriceFromHub(600_000, 400_000, block.timestamp + 1 days, 2);

        assertEq(market.canonicalYesPriceE6(), 600_000);
        assertEq(market.canonicalNoPriceE6(), 400_000);
        assertEq(market.canonicalPriceNonce(), 2);
    }

    function testCanonicalPricingQuoteAndStaleGuard() external {
        market.setCrossChainController(alice);

        vm.expectRevert(PredictionMarket.PredictionMarket__CanonicalPriceStale.selector);
        market.getYesForNoQuote(1e6);

        vm.prank(alice);
        market.syncCanonicalPriceFromHub(520_000, 480_000, block.timestamp + 1 days, 1);

        (uint256 netOut, uint256 fee) = market.getYesForNoQuote(1e6);
        (uint256 expectedOut, uint256 expectedFee,,) =
            AMMLib.getAmountOut(10_000e6, 10_000e6, 1e6, MarketConstants.SWAP_FEE_BPS, MarketConstants.FEE_PRECISION_BPS);

        assertEq(netOut, expectedOut);
        assertEq(fee, expectedFee);
    }

    function testGetYesForNoQuoteReverts() external {
        vm.expectRevert(MarketErrors.PredictionMarket__AmountCantBeZero.selector);
        market.getYesForNoQuote(0);

        vm.expectRevert(MarketErrors.PredictionMarket__AmountLessThanMinAllwed.selector);
        market.getYesForNoQuote(100);
    }

    function testGetNoForYesQuoteReverts() external {
        vm.expectRevert(MarketErrors.PredictionMarket__AmountCantBeZero.selector);
        market.getNoForYesQuote(0);

        vm.expectRevert(MarketErrors.PredictionMarket__AmountLessThanMinAllwed.selector);
        market.getNoForYesQuote(100);
    }

    function testGetNoForYesQuoteCanonicalAndStale() external {
        market.setCrossChainController(address(this));
        vm.expectRevert(PredictionMarket.PredictionMarket__CanonicalPriceStale.selector);
        market.getNoForYesQuote(1e6);

        market.syncCanonicalPriceFromHub(520_000, 480_000, block.timestamp + 1 days, 1);
        (uint256 netOut, uint256 fee) = market.getNoForYesQuote(1e6);
        (uint256 expectedOut, uint256 expectedFee,,) =
            AMMLib.getAmountOut(10_000e6, 10_000e6, 1e6, MarketConstants.SWAP_FEE_BPS, MarketConstants.FEE_PRECISION_BPS);
        assertEq(netOut, expectedOut);
        assertEq(fee, expectedFee);
    }

    function testCanonicalQuoteRevertsWhenDeviationTooHigh() external {
        market.setCrossChainController(address(this));
        market.syncCanonicalPriceFromHub(700_000, 300_000, block.timestamp + 1 days, 1);

        vm.expectRevert(PredictionMarket.PredictionMarket__CanonicalPriceDeviationTooHigh.selector);
        market.getYesForNoQuote(1e6);
    }

    function testCanonicalQuoteRevertWhenInvalidPrice() external {
        market.setCrossChainController(address(this));
        market.syncCanonicalPriceFromHub(0, 1_000_000, block.timestamp + 1 days, 1);

        vm.expectRevert(PredictionMarket.PredictionMarket__InvalidCanonicalPrice.selector);
        market.getYesForNoQuote(1e6);

        vm.expectRevert(PredictionMarket.PredictionMarket__InvalidCanonicalPrice.selector);
        market.getNoForYesQuote(1e6);
    }

    function testCheckResolutionTime() external {
        bool readyBefore = market.checkResolutionTime();
        assertEq(readyBefore, false);

        vm.warp(market.resolutionTime() + 1);
        bool readyAfter = market.checkResolutionTime();
        assertEq(readyAfter, true);
        assertEq(uint256(market.state()), uint256(State.Closed));
    }

    function testYesPriceProbabilityPaths() external {
        PredictionMarket unseeded = _newUnseededMarket();
        vm.expectRevert(MarketErrors.PredictionMarket__InitailConstantLiquidityNotSetYet.selector);
        unseeded.getYesPriceProbability();

        assertEq(market.getYesPriceProbability(), 500_000);

        market.setCrossChainController(address(this));
        vm.expectRevert(PredictionMarket.PredictionMarket__CanonicalPriceStale.selector);
        market.getYesPriceProbability();

        market.syncCanonicalPriceFromHub(610_000, 390_000, block.timestamp + 1 days, 1);
        assertEq(market.getYesPriceProbability(), 610_000);
    }

    function testNoPriceProbabilityPaths() external {
        PredictionMarket unseeded = _newUnseededMarket();
        vm.expectRevert(MarketErrors.PredictionMarket__InitailConstantLiquidityNotSetYet.selector);
        unseeded.getNoPriceProbability();

        assertEq(market.getNoPriceProbability(), 500_000);

        market.setCrossChainController(address(this));
        vm.expectRevert(PredictionMarket.PredictionMarket__CanonicalPriceStale.selector);
        market.getNoPriceProbability();

        market.syncCanonicalPriceFromHub(610_000, 390_000, block.timestamp + 1 days, 1);
        assertEq(market.getNoPriceProbability(), 390_000);
    }

    function testRedeemCompleteSetsReverts() external {
        vm.prank(alice);
        vm.expectRevert(MarketErrors.PredictionMarket__AmountCantBeZero.selector);
        market.redeemCompleteSets(0);

        _mintCompleteSets(alice, 2e6);
        vm.prank(alice);
        vm.expectRevert(MarketErrors.PredictionMarket__RedeemCompletesetLessThanMinAllowed.selector);
        market.redeemCompleteSets(100);

        vm.prank(alice);
        vm.expectRevert(MarketErrors.PredictionMarket__redeemCompleteSets_InsuffientTokenBalance.selector);
        market.redeemCompleteSets(3e6);
    }
}
