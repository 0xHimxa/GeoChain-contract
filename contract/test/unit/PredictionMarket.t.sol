// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {PredictionMarket} from "../../src/predictionMarket/PredictionMarket.sol";
import {PredictionMarketBase} from
    "../../src/predictionMarket/PredictionMarketBase.sol";
import {MarketDeployer} from "../../src/marketFactory/event-deployer/MarketDeployer.sol";
import {OutcomeToken} from "../../src/token/OutcomeToken.sol";
import {LMSRLib} from "../../src/libraries/LMSRLib.sol";
import {MarketErrors, MarketConstants, Resolution, State} from "../../src/libraries/MarketTypes.sol";

contract MockMarketFactory {
    address public lastRemoved;
    uint256 public removeCount;
    address public lastManualReviewAdded;
    address public lastManualReviewRemoved;
    uint256 public manualReviewAddedCount;
    uint256 public manualReviewRemovedCount;
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

    function markMarketForManualReview(address market) external {
        lastManualReviewAdded = market;
        manualReviewAddedCount++;
    }

    function removeManualReviewMarket(address market) external {
        lastManualReviewRemoved = market;
        manualReviewRemovedCount++;
    }

    function onHubMarketResolved(Resolution outcome, string calldata proofUrl) external {
        lastHubOutcome = outcome;
        lastHubProofUrl = proofUrl;
        onHubResolvedCount++;
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

contract PredictionMarketTest is Test {
    OutcomeToken internal collateral;
    PredictionMarket internal market;
    PredictionMarket internal implementation;
    MarketDeployer internal marketDeployer;
    MockMarketFactory internal mockFactory;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal constant FORWARDER = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8;

    uint256 internal constant LIQUIDITY_PARAM = 100_000e6;

    function setUp() external {
        collateral = new OutcomeToken("USDC", "USDC", address(this));
        mockFactory = new MockMarketFactory();
        implementation = new PredictionMarket();
        marketDeployer = new MarketDeployer(address(implementation), address(mockFactory));

        market = PredictionMarket(
            mockFactory.deployMarket(
                marketDeployer,
                "Will ETH be above $5000 by year end?",
                address(collateral),
                block.timestamp + 1 days,
                block.timestamp + 2 days,
                FORWARDER
            )
        );

        vm.prank(address(mockFactory));
        market.transferOwnership(address(this));

        uint256 subsidy = LMSRLib.maxSubsidyLoss(LIQUIDITY_PARAM);
        collateral.mint(address(market), subsidy);
        market.initializeMarket(LIQUIDITY_PARAM);
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

    function _resolveAndFinalize(Resolution outcome, string memory proofUrl) internal {
        market.resolve(outcome, proofUrl);
        vm.warp(block.timestamp + market.disputeWindow() + 1);
        market.finalizeResolutionAfterDisputeWindow();
    }

    function _newUninitializedMarket() internal returns (PredictionMarket m) {
        m = PredictionMarket(
            mockFactory.deployMarket(
                marketDeployer,
                "Uninitialized market",
                address(collateral),
                block.timestamp + 1 days,
                block.timestamp + 2 days,
                FORWARDER
            )
        );
        vm.prank(address(mockFactory));
        m.transferOwnership(address(this));
    }

    function _reportLmsrBuy(
        address trader,
        uint8 outcomeIndex,
        uint256 sharesDelta,
        uint256 costDelta,
        uint256 newYesPriceE6,
        uint256 newNoPriceE6,
        uint64 nonce
    ) internal {
        bytes memory report = abi.encode(
            "LMSRBuy",
            abi.encode(trader, outcomeIndex, sharesDelta, costDelta, newYesPriceE6, newNoPriceE6, nonce)
        );
        vm.prank(FORWARDER);
        market.onReport("", report);
    }

    function _reportLmsrSell(
        address trader,
        uint8 outcomeIndex,
        uint256 sharesDelta,
        uint256 refundDelta,
        uint256 newYesPriceE6,
        uint256 newNoPriceE6,
        uint64 nonce
    ) internal {
        bytes memory report = abi.encode(
            "LMSRSell",
            abi.encode(trader, outcomeIndex, sharesDelta, refundDelta, newYesPriceE6, newNoPriceE6, nonce)
        );
        vm.prank(FORWARDER);
        market.onReport("", report);
    }

    function testConstructorRevertInvalidArguments() external {
        vm.expectRevert(MarketErrors.PredictionMarket__InvalidArguments_PassedInConstructor.selector);
        mockFactory.deployMarket(marketDeployer, "", address(collateral), 1, 2, FORWARDER);

        vm.expectRevert(MarketErrors.PredictionMarket__InvalidArguments_PassedInConstructor.selector);
        mockFactory.deployMarket(marketDeployer, "q", address(0), 1, 2, FORWARDER);

        vm.expectRevert(MarketErrors.PredictionMarket__CloseTimeGreaterThanResolutionTime.selector);
        mockFactory.deployMarket(marketDeployer, "q", address(collateral), 3, 2, FORWARDER);
    }

    function testInitializeMarketSuccess() external {
        PredictionMarket uninitialized = _newUninitializedMarket();
        uint256 subsidy = LMSRLib.maxSubsidyLoss(50_000e6);
        collateral.mint(address(uninitialized), subsidy);

        uninitialized.initializeMarket(50_000e6);

        assertEq(uninitialized.liquidityParam(), 50_000e6);
        assertEq(uninitialized.subsidyDeposit(), subsidy);
        assertEq(uninitialized.lastYesPriceE6(), 500_000);
        assertEq(uninitialized.lastNoPriceE6(), 500_000);
        assertEq(uninitialized.tradeNonce(), 0);
    }

    function testInitializeMarketRevertWhenAlreadyInitialized() external {
        vm.expectRevert(MarketErrors.LMSR__AlreadyInitialized.selector);
        market.initializeMarket(LIQUIDITY_PARAM);
    }

    function testInitializeMarketRevertWhenAmountZero() external {
        PredictionMarket uninitialized = _newUninitializedMarket();
        vm.expectRevert(MarketErrors.PredictionMarket__AmountCantBeZero.selector);
        uninitialized.initializeMarket(0);
    }

    function testInitializeMarketRevertWhenInsufficientSubsidy() external {
        PredictionMarket uninitialized = _newUninitializedMarket();
        vm.expectRevert(MarketErrors.LMSR__InsufficientSubsidy.selector);
        uninitialized.initializeMarket(10_000e6);
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
        uint256 cap = (market.liquidityParam() * MarketConstants.MAX_EXPOSURE_BPS) / MarketConstants.MAX_EXPOSURE_PRECISION;
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

    function testMintRevertWhenMarketClosed() external {
        vm.warp(market.closeTime() + 1);

        _fundAndApproveCollateral(alice, 2e6);

        vm.prank(alice);
        vm.expectRevert(MarketErrors.PredictionMarket__IsClosed.selector);
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
        vm.expectRevert(MarketErrors.PredictionMarket__MintingCompleteSet__AmountLessThanMinimum.selector);
        market.mintCompleteSets(900_000);
    }

    function testMintRevertWhenInsufficientCollateralBalance() external {
        vm.prank(alice);
        vm.expectRevert(MarketErrors.PredictionMarket__MintCompleteSets_InsufficientTokenBalance.selector);
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
        _resolveAndFinalize(Resolution.Yes, "ipfs://proof");

        _fundAndApproveCollateral(alice, 2e6);
        vm.prank(alice);
        vm.expectRevert(MarketErrors.PredictionMarket__AlreadyResolved.selector);
        market.mintCompleteSets(2e6);
    }

    function testRedeemCompleteSetsReverts() external {
        vm.prank(alice);
        vm.expectRevert(MarketErrors.PredictionMarket__AmountCantBeZero.selector);
        market.redeemCompleteSets(0);

        _mintCompleteSets(alice, 2e6);
        vm.prank(alice);
        vm.expectRevert(MarketErrors.PredictionMarket__RedeemCompleteSetLessThanMinAllowed.selector);
        market.redeemCompleteSets(100);

        vm.prank(alice);
        vm.expectRevert(MarketErrors.PredictionMarket__RedeemCompleteSets_InsufficientTokenBalance.selector);
        market.redeemCompleteSets(3e6);
    }

    function testLmsrBuyViaReportSuccess() external {
        uint256 costDelta = 1_000e6;
        uint256 sharesDelta = 1_000e6;
        _fundAndApproveCollateral(alice, costDelta);

        _reportLmsrBuy(alice, 0, sharesDelta, costDelta, 520_000, 480_000, 0);

        uint256 fee = (costDelta * MarketConstants.LMSR_TRADE_FEE_BPS) / MarketConstants.FEE_PRECISION_BPS;
        uint256 actualCost = costDelta - fee;

        assertEq(market.yesToken().balanceOf(alice), sharesDelta);
        assertEq(market.yesSharesOutstanding(), sharesDelta);
        assertEq(market.lastYesPriceE6(), 520_000);
        assertEq(market.lastNoPriceE6(), 480_000);
        assertEq(market.tradeNonce(), 1);
        assertEq(market.protocolCollateralFees(), fee);
        assertEq(market.userRiskExposure(alice), actualCost);
    }

    function testLmsrBuyRevertWhenBelowMinimumTrade() external {
        _fundAndApproveCollateral(alice, 1_000e6);
        vm.prank(FORWARDER);
        vm.expectRevert(MarketErrors.LMSR__TradeBelowMinimum.selector);
        market.onReport("", abi.encode("LMSRBuy", abi.encode(alice, 0, 100, 1_000e6, 500_000, 500_000, 0)));
    }

    function testLmsrBuyRevertWhenInvalidPriceSum() external {
        _fundAndApproveCollateral(alice, 1_000e6);
        vm.prank(FORWARDER);
        vm.expectRevert(MarketErrors.LMSR__InvalidPriceSum.selector);
        market.onReport("", abi.encode("LMSRBuy", abi.encode(alice, 0, 1_000e6, 1_000e6, 700_000, 100_000, 0)));
    }

    function testLmsrSellRevertWhenInsufficientShares() external {
        vm.prank(FORWARDER);
        vm.expectRevert(MarketErrors.LMSR__InsufficientShares.selector);
        market.onReport("", abi.encode("LMSRSell", abi.encode(alice, 0, 1_000e6, 500e6, 520_000, 480_000, 0)));
    }

    function testLmsrSellViaReportSuccess() external {
        uint256 costDelta = 1_000e6;
        uint256 sharesDelta = 1_000e6;
        _fundAndApproveCollateral(alice, costDelta);
        _reportLmsrBuy(alice, 0, sharesDelta, costDelta, 520_000, 480_000, 0);

        uint256 beforeCollateral = collateral.balanceOf(alice);
        uint256 refundDelta = 500e6;

        _reportLmsrSell(alice, 0, sharesDelta, refundDelta, 500_000, 500_000, 1);

        uint256 fee = (refundDelta * MarketConstants.LMSR_TRADE_FEE_BPS) / MarketConstants.FEE_PRECISION_BPS;
        uint256 netRefund = refundDelta - fee;

        assertEq(market.yesToken().balanceOf(alice), 0);
        assertEq(market.yesSharesOutstanding(), 0);
        assertEq(market.tradeNonce(), 2);
        assertEq(collateral.balanceOf(alice), beforeCollateral + netRefund);
    }

    function testResolveRevertConditions() external {
        vm.expectRevert(MarketErrors.PredictionMarket__ResolveTimeNotReached.selector);
        market.resolve(Resolution.Yes, "ipfs://proof");

        vm.expectRevert(MarketErrors.PredictionMarket__ResolveTimeNotReached.selector);
        market.resolve(Resolution.Yes, "");

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

        assertEq(uint256(market.state()), uint256(State.Review));
        assertEq(uint256(market.proposedResolution()), uint256(Resolution.Yes));
    }

    function testFinalizeResolutionAfterDisputeWindowSuccess() external {
        _warpAfterResolution();
        market.resolve(Resolution.Yes, "ipfs://proof");

        vm.warp(block.timestamp + market.disputeWindow() + 1);
        market.finalizeResolutionAfterDisputeWindow();

        assertEq(uint256(market.state()), uint256(State.Resolved));
        assertEq(uint256(market.resolution()), uint256(Resolution.Yes));
    }

    function testFinalizeResolutionAfterDisputeWindowRevertsWhenTooEarly() external {
        _warpAfterResolution();
        market.resolve(Resolution.Yes, "ipfs://proof");

        vm.expectRevert(MarketErrors.PredictionMarket__DisputeWindowNotPassed.selector);
        market.finalizeResolutionAfterDisputeWindow();
    }

    function testDisputeProposedResolutionRequiresManualFinalizePath() external {
        _warpAfterResolution();
        market.resolve(Resolution.Yes, "ipfs://proof");

vm.prank(address(this));
market.setRouterVault(alice);
        vm.prank(alice);
        market.disputeProposedResolution(alice, Resolution.No);

        assertEq(market.resolutionDisputed(), true);

        vm.warp(block.timestamp + market.disputeWindow() + 1);
        vm.expectRevert(MarketErrors.PredictionMarket__ManualReviewNeeded.selector);
        market.finalizeResolutionAfterDisputeWindow();

        market.adjudicateDisputedResolution(Resolution.No, "ipfs://manual-proof");
        assertEq(uint256(market.state()), uint256(State.Resolved));
        assertEq(uint256(market.resolution()), uint256(Resolution.No));
    }

    function testResolveRevertsWhenLocalResolutionDisabledOnSpoke() external {
        market.setCrossChainController(alice);
        _warpAfterResolution();

        vm.expectRevert(bytes4(keccak256("PredictionMarket__LocalResolutionDisabled()")));
        market.resolve(Resolution.Yes, "ipfs://proof");
    }

    function testResolveYesSuccess() external {
        _warpAfterResolution();

        market.resolve(Resolution.Yes, "ipfs://proof");

        assertEq(uint256(market.state()), uint256(State.Review));
        assertEq(uint256(market.proposedResolution()), uint256(Resolution.Yes));
        assertEq(uint256(market.resolution()), uint256(Resolution.Unset));
        assertEq(mockFactory.removeCount(), 0);

        vm.warp(block.timestamp + market.disputeWindow() + 1);
        market.finalizeResolutionAfterDisputeWindow();

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

        vm.expectRevert(bytes4(keccak256("PredictionMarket__LocalResolutionDisabled()")));
        market.manualResolveMarket(Resolution.No, "ipfs://manual");
    }

    function testResolveNotifiesHubFactoryWhenControllerSet() external {
        mockFactory.setIsHubFactory(true);
        market.setCrossChainController(alice);
        _warpAfterResolution();

        market.resolve(Resolution.Yes, "ipfs://hub-proof");
        vm.warp(block.timestamp + market.disputeWindow() + 1);
        market.finalizeResolutionAfterDisputeWindow();

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
        vm.expectRevert(MarketErrors.PredictionMarket__ProofUrlCannotBeEmpty.selector);
        market.manualResolveMarket(Resolution.Yes, "");
    }

    function testManualResolveRevertMarketNotInReview() external {
        vm.expectRevert(MarketErrors.PredictionMarket__MarketNotInReview.selector);
        market.manualResolveMarket(Resolution.Yes, "ipfs://manual");
    }

    function testManualResolveRevertAfterAlreadyManuallyResolved() external {
        _warpAfterResolution();
        market.resolve(Resolution.Inconclusive, "ipfs://initial");
        market.manualResolveMarket(Resolution.Yes, "ipfs://manual");

        vm.expectRevert(MarketErrors.PredictionMarket__MarketNotInReview.selector);
        market.manualResolveMarket(Resolution.Yes, "ipfs://manual-2");
    }

    function testRedeemAfterResolutionYes() external {
        _mintCompleteSets(alice, 10e6);
        _warpAfterResolution();
        _resolveAndFinalize(Resolution.Yes, "ipfs://proof");

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
        _resolveAndFinalize(Resolution.No, "ipfs://proof");

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
        _resolveAndFinalize(Resolution.Yes, "ipfs://proof");
        vm.prank(alice);
        vm.expectRevert(MarketErrors.PredictionMarket__AmountCantBeZero.selector);
        market.redeem(0);
    }

    function testWithdrawProtocolFeesSuccessAfterResolution() external {
        uint256 amount = 10e6;
        _mintCompleteSets(alice, amount);

        uint256 expectedFee = (amount * 300) / 10_000;

        _warpAfterResolution();
        _resolveAndFinalize(Resolution.Yes, "ipfs://proof");
        market.setCrossChainController(address(this));

        uint256 beforeOwnerBalance = collateral.balanceOf(address(this));
        market.withdrawProtocolFees();

        assertEq(collateral.balanceOf(address(this)), beforeOwnerBalance + expectedFee);
        assertEq(market.protocolCollateralFees(), 0);
    }

    function testWithdrawProtocolFeesNoOpWhenNoFees() external {
        _warpAfterResolution();
        _resolveAndFinalize(Resolution.Yes, "ipfs://proof");
        market.setCrossChainController(address(this));
        uint256 beforeOwnerBalance = collateral.balanceOf(address(this));
        market.withdrawProtocolFees();
        assertEq(collateral.balanceOf(address(this)), beforeOwnerBalance);
        assertEq(market.protocolCollateralFees(), 0);
    }

    function testWithdrawProtocolFeesRevertStateNotResolved() external {
        market.setCrossChainController(address(this));
        vm.expectRevert(MarketErrors.PredictionMarket__StateNeedsToBeResolvedToWithdrawLiquidity.selector);
        market.withdrawProtocolFees();
    }

    function testWithdrawProtocolFeesRevertInsufficientFeeBalance() external {
        _mintCompleteSets(alice, 2e6);
        _warpAfterResolution();
        _resolveAndFinalize(Resolution.Yes, "ipfs://proof");
        market.setCrossChainController(address(this));
        uint256 burnAmount = collateral.balanceOf(address(market)) - (market.protocolCollateralFees() - 1);
        collateral.burn(address(market), burnAmount);
        vm.expectRevert(MarketErrors.PredictionMarket__WithdrawLiquidity_InsufficientFee.selector);
        market.withdrawProtocolFees();
    }

    function testWithdrawProtocolFeesRevertInsufficientContractBalance() external {
        _mintCompleteSets(alice, 10e6);
        uint256 fee = market.protocolCollateralFees();

        _warpAfterResolution();
        _resolveAndFinalize(Resolution.Yes, "ipfs://proof");
        market.setCrossChainController(address(this));

        uint256 keep = fee - 1;
        uint256 burnAmount = collateral.balanceOf(address(market)) - keep;
        collateral.burn(address(market), burnAmount);

        vm.expectRevert(MarketErrors.PredictionMarket__WithdrawLiquidity_InsufficientFee.selector);
        market.withdrawProtocolFees();
    }

    function testWithdrawProtocolFeesRevertUnauthorizedCaller() external {
        _mintCompleteSets(alice, 2e6);
        _warpAfterResolution();
        _resolveAndFinalize(Resolution.Yes, "ipfs://proof");

        vm.prank(alice);
        vm.expectRevert(MarketErrors.PredictionMarket__NotOwner_Or_CrossChainController.selector);
        market.withdrawProtocolFees();
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

    function testPauseAndUnpauseUpdatesPausedFlag() external {
        assertEq(market.paused(), false);
        market.pause();
        assertEq(market.paused(), true);
        market.unpause();
        assertEq(market.paused(), false);
    }

    function testResolveFromHubAccessAndSuccess() external {
        market.setCrossChainController(alice);

        vm.prank(bob);
        vm.expectRevert(bytes4(keccak256("PredictionMarket__OnlyCrossChainController()")));
        market.resolveFromHub(Resolution.Yes, "ipfs://proof");

        vm.prank(alice);
        market.resolveFromHub(Resolution.Yes, "ipfs://proof");

        assertEq(uint256(market.state()), uint256(State.Resolved));
        assertEq(uint256(market.resolution()), uint256(Resolution.Yes));
    }

    function testResolveFromHubRevertConditions() external {
        market.setCrossChainController(address(this));

        vm.expectRevert(MarketErrors.PredictionMarket__ProofUrlCannotBeEmpty.selector);
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
        vm.expectRevert(bytes4(keccak256("PredictionMarket__InvalidCanonicalPrice()")));
        market.syncCanonicalPriceFromHub(700_000, 200_000, block.timestamp + 1 days, 1);

        vm.prank(alice);
        market.syncCanonicalPriceFromHub(600_000, 400_000, block.timestamp + 1 days, 2);

        vm.prank(alice);
        vm.expectRevert(bytes4(keccak256("PredictionMarket__StaleSyncMessage()")));
        market.syncCanonicalPriceFromHub(600_000, 400_000, block.timestamp + 1 days, 2);

        assertEq(market.canonicalYesPriceE6(), 600_000);
        assertEq(market.canonicalNoPriceE6(), 400_000);
        assertEq(market.canonicalPriceNonce(), 2);
    }

    function testSetDeviationPolicyValidationAndPass() external {
        vm.expectRevert(bytes4(keccak256("PredictionMarket__DeviationPolicyInvalid()")));
        market.setDeviationPolicy(300, 200, 500, 100, 200, 50);

        market.setDeviationPolicy(200, 350, 600, 80, 300, 100);
        assertEq(market.softDeviationBps(), 200);
        assertEq(market.stressDeviationBps(), 350);
        assertEq(market.hardDeviationBps(), 600);
        assertEq(market.stressExtraFeeBps(), 80);
        assertEq(market.stressMaxOutBps(), 300);
        assertEq(market.unsafeMaxOutBps(), 100);
    }

    function testDeviationStatusReturnsDefaultsWhenNotInCanonicalMode() external view {
        (
            PredictionMarketBase.DeviationBand band,
            uint256 deviationBps,
            uint256 effectiveFeeBps,
            uint256 maxOutBps,
            bool allowYesForNo,
            bool allowNoForYes
        ) = market.getDeviationStatus();

        assertEq(uint8(band), uint8(PredictionMarketBase.DeviationBand.Normal));
        assertEq(deviationBps, 0);
        assertEq(effectiveFeeBps, MarketConstants.SWAP_FEE_BPS);
        assertEq(maxOutBps, MarketConstants.FEE_PRECISION_BPS);
        assertEq(allowYesForNo, true);
        assertEq(allowNoForYes, true);
    }

    function testDeviationStatusRevertsWhenCanonicalPriceIsStale() external {
        market.setCrossChainController(address(this));

        vm.expectRevert(bytes4(keccak256("PredictionMarket__CanonicalPriceStale()")));
        market.getDeviationStatus();
    }

    function testDeviationStatusRevertsWhenCanonicalPriceContainsZeroLeg() external {
        market.setCrossChainController(address(this));
        market.syncCanonicalPriceFromHub(0, 1_000_000, block.timestamp + 1 days, 1);

        vm.expectRevert(bytes4(keccak256("PredictionMarket__InvalidCanonicalPrice()")));
        market.getDeviationStatus();
    }

    function testDeviationStatusUnsafeAndCircuitUseEscalatedFeeAndReducedCaps()
        external
    {
        market.setCrossChainController(address(this));

        // Unsafe band: local YES=500000 vs canonical YES=460000 (400 bps deviation)
        market.syncCanonicalPriceFromHub(460_000, 540_000, block.timestamp + 1 days, 1);
        (
            PredictionMarketBase.DeviationBand unsafeBand,
            ,
            uint256 unsafeEffectiveFeeBps,
            uint256 unsafeMaxOutBps,
            bool unsafeAllowYesForNo,
            bool unsafeAllowNoForYes
        ) = market.getDeviationStatus();
        assertEq(uint8(unsafeBand), uint8(PredictionMarketBase.DeviationBand.Unsafe));
        assertEq(unsafeEffectiveFeeBps, 600); // 400 + (2 * 100 stress extra)
        assertEq(unsafeMaxOutBps, 50); // uses default unsafeMaxOutBps
        assertEq(unsafeAllowYesForNo, true);
        assertEq(unsafeAllowNoForYes, false);

        // Circuit breaker: local YES=500000 vs canonical YES=430000 (700 bps deviation)
        market.syncCanonicalPriceFromHub(430_000, 570_000, block.timestamp + 1 days, 2);
        (
            PredictionMarketBase.DeviationBand breakerBand,
            ,
            uint256 breakerEffectiveFeeBps,
            uint256 breakerMaxOutBps,
            bool breakerAllowYesForNo,
            bool breakerAllowNoForYes
        ) = market.getDeviationStatus();
        assertEq(
            uint8(breakerBand),
            uint8(PredictionMarketBase.DeviationBand.CircuitBreaker)
        );
        assertEq(breakerEffectiveFeeBps, 900); // 400 + (5 * 100 stress extra)
        assertEq(breakerMaxOutBps, 25); // reduced from default unsafeMaxOutBps=50
        assertEq(breakerAllowYesForNo, true);
        assertEq(breakerAllowNoForYes, false);
    }

    function testLmsrBuyOnSpokeUnsafeUsesEscalatedFeeWithoutDirectionBlock()
        external
    {
        uint256 costDelta = 50e6;
        uint256 sharesDelta = 50e6;
        _fundAndApproveCollateral(alice, costDelta * 2);

        market.setCrossChainController(address(this));
        market.syncCanonicalPriceFromHub(460_000, 540_000, block.timestamp + 1 days, 1);

        // local YES > canonical YES; both directions remain user-tradable.
        _reportLmsrBuy(alice, 0, sharesDelta, costDelta, 505_000, 495_000, 0);
        _reportLmsrBuy(alice, 1, sharesDelta, costDelta, 495_000, 505_000, 1);

        uint256 fee = (costDelta * 600) / MarketConstants.FEE_PRECISION_BPS;
        assertEq(market.protocolCollateralFees(), fee * 2);
    }

    function testCheckResolutionTime() external {
        bool readyBefore = market.checkResolutionTime();
        assertEq(readyBefore, false);

        vm.warp(market.resolutionTime() + 1);
        bool readyAfter = market.checkResolutionTime();
        assertEq(readyAfter, true);
        assertEq(uint256(market.state()), uint256(State.Open));
    }

    function testYesPriceProbabilityPaths() external {
        PredictionMarket uninitialized = _newUninitializedMarket();
        vm.expectRevert(MarketErrors.LMSR__NotInitialized.selector);
        uninitialized.getYesPriceProbability();

        assertEq(market.getYesPriceProbability(), 500_000);

        market.setCrossChainController(address(this));
        assertEq(market.getYesPriceProbability(), 500_000);

        market.syncCanonicalPriceFromHub(610_000, 390_000, block.timestamp + 1 days, 1);
        assertEq(market.getYesPriceProbability(), 500_000);
    }

    function testNoPriceProbabilityPaths() external {
        PredictionMarket uninitialized = _newUninitializedMarket();
        vm.expectRevert(MarketErrors.LMSR__NotInitialized.selector);
        uninitialized.getNoPriceProbability();

        assertEq(market.getNoPriceProbability(), 500_000);

        market.setCrossChainController(address(this));
        assertEq(market.getNoPriceProbability(), 500_000);

        market.syncCanonicalPriceFromHub(610_000, 390_000, block.timestamp + 1 days, 1);
        assertEq(market.getNoPriceProbability(), 500_000);
    }

    function testSetMarketIdByOwnerPass() external {
        market.setMarketId(1);
        assertEq(market.marketId(), 1);
    }

    function testSetMarketIdByCrossChainControllerPass() external {
        market.setCrossChainController(alice);
        vm.prank(alice);
        market.setMarketId(7);
        assertEq(market.marketId(), 7);
    }

    function testSetMarketIdRevertsForUnauthorizedCaller() external {
        vm.prank(alice);
        vm.expectRevert(MarketErrors.PredictionMarket__NotOwner_Or_CrossChainController.selector);
        market.setMarketId(3);
    }

    function testSetMarketIdRevertsWhenZeroOrAlreadySet() external {
        vm.expectRevert(bytes4(keccak256("PredictionMarket__InvalidMarketId()")));
        market.setMarketId(0);

        market.setMarketId(5);
        vm.expectRevert(bytes4(keccak256("PredictionMarket__MarketIdAlreadySet()")));
        market.setMarketId(6);
    }

    function testSetDisputeWindowValidationAndPass() external {
        vm.expectRevert(MarketErrors.PredictionMarket__DisputeWindowMustBeGreaterThanZero.selector);
        market.setDisputeWindow(0);

        market.setDisputeWindow(2 days);
        assertEq(market.disputeWindow(), 2 days);
    }

    function testDisputeRevertsForZeroDisputerAndNoPendingResolution() external {
        market.setRouterVault(alice);
        vm.prank(alice);
        vm.expectRevert(MarketErrors.PredictionMarket__DisputerCannotBeZero.selector);
        market.disputeProposedResolution(address(0), Resolution.Yes);

        vm.prank(alice);
        vm.expectRevert(MarketErrors.PredictionMarket__NoPendingResolution.selector);
        market.disputeProposedResolution(alice, Resolution.Yes);
    }

    function testDisputeRevertsWhenWindowClosedOrAlreadySubmitted() external {
        _warpAfterResolution();
        market.resolve(Resolution.Yes, "ipfs://proof");
        market.setRouterVault(bob);

        vm.prank(bob);
        market.disputeProposedResolution(alice, Resolution.No);

        vm.prank(bob);
        vm.expectRevert(MarketErrors.PredictionMarket__DisputeAlreadySubmittedByUser.selector);
        market.disputeProposedResolution(alice, Resolution.Yes);

        vm.warp(market.disputeDeadline() + 1);
        vm.prank(bob);
        vm.expectRevert(MarketErrors.PredictionMarket__DisputeWindowClosed.selector);
        market.disputeProposedResolution(bob, Resolution.Yes);
    }

    function testDisputeRevertsForInvalidOutcomeValue() external {
        _warpAfterResolution();
        market.resolve(Resolution.Yes, "ipfs://proof");
        market.setRouterVault(bob);

        vm.prank(bob);
        vm.expectRevert(MarketErrors.PredictionMarket__InvalidFinalOutcome.selector);
        market.disputeProposedResolution(alice, Resolution.Unset);
    }

    function testGetDisputeSnapshotAndCount() external {
        _warpAfterResolution();
        market.resolve(Resolution.Yes, "ipfs://proof");
        market.setRouterVault(bob);

        vm.prank(bob);
        market.disputeProposedResolution(alice, Resolution.No);

        assertEq(market.getDisputeSubmissionsCount(), 1);
        (
            State marketState,
            Resolution currentProposedResolution,
            bool isResolutionDisputed,
            uint256 currentDisputeDeadline,
            uint256 currentResolutionTime,
            string memory question,
            Resolution[] memory disputedUniqueOutcomes
        ) = market.getDisputeResolutionSnapshot();

        assertEq(uint256(marketState), uint256(State.Review));
        assertEq(uint256(currentProposedResolution), uint256(Resolution.Yes));
        assertEq(isResolutionDisputed, true);
        assertGt(currentDisputeDeadline, block.timestamp);
        assertEq(currentResolutionTime, market.resolutionTime());
        assertGt(bytes(question).length, 0);
        assertEq(disputedUniqueOutcomes.length, 1);
        assertEq(uint256(disputedUniqueOutcomes[0]), uint256(Resolution.No));
    }

    function testSetCrossChainControllerRevertZeroAddress() external {
        vm.expectRevert(MarketErrors.PredictionMarket__CrossChainControllerCantBeZero.selector);
        market.setCrossChainController(address(0));
    }

    function testOnReportRevertsForUnknownAction() external {
        bytes memory report = abi.encode("unknownResolutionAction", abi.encode(uint256(1)));
        vm.prank(FORWARDER);
        vm.expectRevert(MarketErrors.PredictionMarket__InvalidReport.selector);
        market.onReport("", report);
    }

    function testOnReportFinalizeResolutionAfterDisputeWindowAction() external {
        _warpAfterResolution();
        market.resolve(Resolution.Yes, "ipfs://proof");
        vm.warp(block.timestamp + market.disputeWindow() + 1);

        bytes memory report = abi.encode("FinalizeResolutionAfterDisputeWindow", bytes(""));
        vm.prank(FORWARDER);
        market.onReport("", report);

        assertEq(uint256(market.state()), uint256(State.Resolved));
        assertEq(uint256(market.resolution()), uint256(Resolution.Yes));
    }

    function testOnReportAdjudicateDisputedResolutionAction() external {
        _warpAfterResolution();
        market.resolve(Resolution.Yes, "ipfs://proof");
        market.setRouterVault(alice);

        vm.prank(alice);
        market.disputeProposedResolution(alice, Resolution.No);

        bytes memory report = abi.encode(
            "AdjudicateDisputedResolution", abi.encode(Resolution.No, "ipfs://adjudicated")
        );
        vm.prank(FORWARDER);
        market.onReport("", report);

        assertEq(uint256(market.state()), uint256(State.Resolved));
        assertEq(uint256(market.resolution()), uint256(Resolution.No));
    }

    function testOnReportResolveMarketValidationBranches() external {
        _warpAfterResolution();

        bytes memory unsetReport = abi.encode("ResolveMarket", abi.encode(Resolution.Unset, "ipfs://proof"));
        vm.prank(FORWARDER);
        vm.expectRevert(MarketErrors.PredictionMarket__InvalidFinalOutcome.selector);
        market.onReport("", unsetReport);

        bytes memory emptyProofReport = abi.encode("ResolveMarket", abi.encode(Resolution.Yes, ""));
        vm.prank(FORWARDER);
        vm.expectRevert(MarketErrors.PredictionMarket__ProofUrlCannotBeEmpty.selector);
        market.onReport("", emptyProofReport);
    }

    function testDisputeModifierRevertsForUnauthorizedAndFactoryTraderMismatch()
        external
    {
        _warpAfterResolution();
        market.resolve(Resolution.Yes, "ipfs://proof");

        vm.prank(bob);
        vm.expectRevert(bytes4(keccak256("PredictionMarket__OnlyRouterVaultAndFactory()")));
        market.disputeProposedResolution(alice, Resolution.No);

        vm.prank(address(mockFactory));
        vm.expectRevert(bytes4(keccak256("PredictionMarket__InvalidArbTrader()")));
        market.disputeProposedResolution(alice, Resolution.No);
    }

    function testGetLmsrStateAndSyncSnapshotViews() external view {
        (
            uint256 yesShares,
            uint256 noShares,
            uint256 b,
            uint256 yesPriceE6,
            uint256 noPriceE6,
            uint64 currentNonce
        ) = market.getLMSRState();
        assertEq(yesShares, market.yesSharesOutstanding());
        assertEq(noShares, market.noSharesOutstanding());
        assertEq(b, market.liquidityParam());
        assertEq(yesPriceE6, market.lastYesPriceE6());
        assertEq(noPriceE6, market.lastNoPriceE6());
        assertEq(currentNonce, market.tradeNonce());

        (uint256 marketState, uint256 snapshotYes, uint256 snapshotNo) = market.getSyncSnapshot();
        assertEq(marketState, uint256(market.state()));
        assertEq(snapshotYes, market.lastYesPriceE6());
        assertEq(snapshotNo, market.lastNoPriceE6());
    }

    function testSetOutcomeTokensAndRouterVaultValidationReverts() external {
        PredictionMarket uninitialized = _newUninitializedMarket();

        vm.expectRevert(bytes4(keccak256("PredictionMarket__InvalidOutcomeTokenAddress()")));
        uninitialized.setOutcomeTokens(address(0), address(1));

        vm.expectRevert(bytes4(keccak256("PredictionMarket__InvalidOutcomeTokenAddress()")));
        uninitialized.setOutcomeTokens(address(1), address(1));

        vm.expectRevert(bytes4(keccak256("PredictionMarket__RouterVaultZeroAddress()")));
        uninitialized.setRouterVault(address(0));

        vm.expectRevert(bytes4(keccak256("PredictionMarket__RiskExposureExemptZeroAddress()")));
        uninitialized.setRiskExempt(address(0), true);
    }
}
