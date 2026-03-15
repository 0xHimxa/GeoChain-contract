// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {PredictionMarket} from "../../src/predictionMarket/PredictionMarket.sol";
import {MarketDeployer} from "../../src/marketFactory/event-deployer/MarketDeployer.sol";
import {OutcomeToken} from "../../src/token/OutcomeToken.sol";
import {FeeLib} from "../../src/libraries/FeeLib.sol";
import {MarketConstants, Resolution} from "../../src/libraries/MarketTypes.sol";
import {LMSRLib} from "../../src/libraries/LMSRLib.sol";
import {IReceiver} from "../../script/interfaces/IReceiver.sol";

contract MockMarketFactoryFuzz {
    address public lastRemoved;
    uint256 public removeCount;
    uint256 public manualReviewAddedCount;
    uint256 public manualReviewRemovedCount;
    bool public isHubFactory;

    function removeResolvedMarket(address market) external {
        lastRemoved = market;
        removeCount++;
    }

    function setIsHubFactory(bool value) external {
        isHubFactory = value;
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

contract PredictionMarketStatelessFuzzTest is Test {
    OutcomeToken internal collateral;
    PredictionMarket internal market;
    PredictionMarket internal implementation;
    MarketDeployer internal marketDeployer;
    MockMarketFactoryFuzz internal mockFactory;

    address internal alice = makeAddr("alice");
    address internal constant FORWARDER = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8;

    uint256 internal constant LIQUIDITY_PARAM = 10_000e6;

    function setUp() external {
        collateral = new OutcomeToken("USDC", "USDC", address(this));
        mockFactory = new MockMarketFactoryFuzz();
        implementation = new PredictionMarket();
        marketDeployer = new MarketDeployer(address(implementation), address(mockFactory));

        market = PredictionMarket(
            mockFactory.deployMarket(
                marketDeployer,
                "Will ETH close above 5k?",
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

    function _mintAndApprove(address user, uint256 amount) internal returns (uint256 netAmount) {
        collateral.mint(user, amount);
        vm.startPrank(user);
        collateral.approve(address(market), type(uint256).max);
        market.mintCompleteSets(amount);
        market.yesToken().approve(address(market), type(uint256).max);
        market.noToken().approve(address(market), type(uint256).max);
        vm.stopPrank();

        netAmount = amount - ((amount * MarketConstants.MINT_COMPLETE_SETS_FEE_BPS) / MarketConstants.FEE_PRECISION_BPS);
    }

    function _fundAndApproveCollateral(address user, uint256 amount) internal {
        collateral.mint(user, amount);
        vm.prank(user);
        collateral.approve(address(market), type(uint256).max);
    }

    function _resolveAndFinalize(Resolution outcome, string memory proofUrl) internal {
        market.resolve(outcome, proofUrl);
        vm.warp(block.timestamp + market.disputeWindow() + 1);
        market.finalizeResolutionAfterDisputeWindow();
    }

    function testFuzz_MintCompleteSets_MintsEqualOutcomeTokens(uint96 amountRaw) external {
        uint256 dynamicCap =
            (LIQUIDITY_PARAM * MarketConstants.MAX_EXPOSURE_BPS) / MarketConstants.MAX_EXPOSURE_PRECISION;
        uint256 amount = bound(uint256(amountRaw), MarketConstants.MINIMUM_AMOUNT, dynamicCap);

        uint256 expectedNet = _mintAndApprove(alice, amount);

        assertEq(market.yesToken().balanceOf(alice), expectedNet);
        assertEq(market.noToken().balanceOf(alice), expectedNet);
        assertEq(market.userRiskExposure(alice), amount);
    }

    function testFuzz_RedeemCompleteSets_ReturnsExpectedCollateral(uint96 mintRaw, uint96 redeemRaw) external {
        uint256 dynamicCap =
            (LIQUIDITY_PARAM * MarketConstants.MAX_EXPOSURE_BPS) / MarketConstants.MAX_EXPOSURE_PRECISION;
        uint256 mintAmount = bound(uint256(mintRaw), 2e6, dynamicCap);
        uint256 mintedNet = _mintAndApprove(alice, mintAmount);

        uint256 redeemAmount = bound(uint256(redeemRaw), MarketConstants.MINIMUM_AMOUNT, mintedNet);
        uint256 beforeCollateral = collateral.balanceOf(alice);

        vm.prank(alice);
        market.redeemCompleteSets(redeemAmount);

        uint256 expectedOut =
            redeemAmount - ((redeemAmount * MarketConstants.REDEEM_COMPLETE_SETS_FEE_BPS) / MarketConstants.FEE_PRECISION_BPS);

        assertEq(collateral.balanceOf(alice), beforeCollateral + expectedOut);
        assertEq(market.yesToken().balanceOf(alice), mintedNet - redeemAmount);
        assertEq(market.noToken().balanceOf(alice), mintedNet - redeemAmount);
    }

    function testFuzz_LMSRBuy_UpdatesExposureAndMints(uint96 costRaw, uint96 sharesRaw, uint8 outcomeRaw) external {
        uint256 dynamicCap =
            (LIQUIDITY_PARAM * MarketConstants.MAX_EXPOSURE_BPS) / MarketConstants.MAX_EXPOSURE_PRECISION;
        uint256 costDelta =
            bound(uint256(costRaw), MarketConstants.MINIMUM_LMSR_TRADE_AMOUNT, dynamicCap);
        uint256 sharesDelta =
            bound(uint256(sharesRaw), MarketConstants.MINIMUM_LMSR_TRADE_AMOUNT, 50_000e6);
        uint8 outcomeIndex = uint8(bound(uint256(outcomeRaw), 0, 1));

        _fundAndApproveCollateral(alice, costDelta);

        uint64 nonce = market.tradeNonce();
        bytes memory report = abi.encode(
            "LMSRBuy",
            abi.encode(alice, outcomeIndex, sharesDelta, costDelta, 600_000, 400_000, nonce)
        );
        vm.prank(FORWARDER);
        IReceiver(address(market)).onReport("", report);

        uint256 fee = FeeLib.calculateFee(
            costDelta,
            MarketConstants.LMSR_TRADE_FEE_BPS,
            MarketConstants.FEE_PRECISION_BPS
        );
        uint256 actualCost = costDelta - fee;

        if (outcomeIndex == 0) {
            assertEq(market.yesToken().balanceOf(alice), sharesDelta);
        } else {
            assertEq(market.noToken().balanceOf(alice), sharesDelta);
        }
        assertEq(market.userRiskExposure(alice), actualCost);
    }

    function testFuzz_LMSRSell_RefundsAndReducesExposure(
        uint96 costRaw,
        uint96 sharesRaw,
        uint96 refundRaw
    ) external {
        uint256 dynamicCap =
            (LIQUIDITY_PARAM * MarketConstants.MAX_EXPOSURE_BPS) / MarketConstants.MAX_EXPOSURE_PRECISION;
        uint256 costDelta =
            bound(uint256(costRaw), MarketConstants.MINIMUM_LMSR_TRADE_AMOUNT, dynamicCap);
        uint256 sharesDelta =
            bound(uint256(sharesRaw), MarketConstants.MINIMUM_LMSR_TRADE_AMOUNT, 50_000e6);
        uint256 refundDelta =
            bound(uint256(refundRaw), MarketConstants.MINIMUM_LMSR_TRADE_AMOUNT, costDelta);

        _fundAndApproveCollateral(alice, costDelta);

        uint64 nonce = market.tradeNonce();
        bytes memory buyReport = abi.encode(
            "LMSRBuy",
            abi.encode(alice, uint8(0), sharesDelta, costDelta, 600_000, 400_000, nonce)
        );
        vm.prank(FORWARDER);
        IReceiver(address(market)).onReport("", buyReport);

        uint256 exposureBefore = market.userRiskExposure(alice);
        uint256 collateralBefore = collateral.balanceOf(alice);

        nonce = market.tradeNonce();
        bytes memory sellReport = abi.encode(
            "LMSRSell",
            abi.encode(alice, uint8(0), sharesDelta, refundDelta, 590_000, 410_000, nonce)
        );
        vm.prank(FORWARDER);
        IReceiver(address(market)).onReport("", sellReport);

        uint256 fee = FeeLib.calculateFee(
            refundDelta,
            MarketConstants.LMSR_TRADE_FEE_BPS,
            MarketConstants.FEE_PRECISION_BPS
        );
        uint256 netRefund = refundDelta - fee;

        assertEq(collateral.balanceOf(alice), collateralBefore + netRefund);
        assertEq(market.userRiskExposure(alice), exposureBefore > refundDelta ? exposureBefore - refundDelta : 0);
    }

    function testFuzz_ResolveAndRedeemYes(uint96 mintRaw, uint96 redeemRaw) external {
        uint256 dynamicCap =
            (LIQUIDITY_PARAM * MarketConstants.MAX_EXPOSURE_BPS) / MarketConstants.MAX_EXPOSURE_PRECISION;
        uint256 mintAmount = bound(uint256(mintRaw), 2e6, dynamicCap);
        uint256 mintedNet = _mintAndApprove(alice, mintAmount);
        uint256 redeemAmount = bound(uint256(redeemRaw), MarketConstants.MINIMUM_AMOUNT, mintedNet);

        vm.warp(market.resolutionTime() + 1);
        _resolveAndFinalize(Resolution.Yes, "ipfs://proof");

        uint256 beforeCollateral = collateral.balanceOf(alice);

        vm.prank(alice);
        market.redeem(redeemAmount);

        uint256 expectedOut =
            redeemAmount - ((redeemAmount * MarketConstants.REDEEM_COMPLETE_SETS_FEE_BPS) / MarketConstants.FEE_PRECISION_BPS);

        assertEq(collateral.balanceOf(alice), beforeCollateral + expectedOut);
    }

    function testFuzz_WithdrawProtocolFees_AfterResolution(uint96 mintRaw) external {
        uint256 dynamicCap =
            (LIQUIDITY_PARAM * MarketConstants.MAX_EXPOSURE_BPS) / MarketConstants.MAX_EXPOSURE_PRECISION;
        uint256 mintAmount = bound(uint256(mintRaw), MarketConstants.MINIMUM_AMOUNT, dynamicCap);
        _mintAndApprove(alice, mintAmount);

        vm.warp(market.resolutionTime() + 1);
        _resolveAndFinalize(Resolution.Yes, "ipfs://proof");

        uint256 feeBalance = market.protocolCollateralFees();
        vm.assume(feeBalance > 0);
        market.setCrossChainController(address(this));

        uint256 beforeOwnerBalance = collateral.balanceOf(address(this));

        market.withdrawProtocolFees();

        assertEq(collateral.balanceOf(address(this)), beforeOwnerBalance + feeBalance);
        assertEq(market.protocolCollateralFees(), 0);
    }

    function testFuzz_SyncCanonicalPrice_StoresFreshState(uint32 yesPriceRaw, uint64 nonceRaw, uint32 validForRaw) external {
        uint256 yesPrice = bound(uint256(yesPriceRaw), 1, MarketConstants.PRICE_PRECISION - 1);
        uint256 noPrice = MarketConstants.PRICE_PRECISION - yesPrice;
        uint64 nonce = uint64(bound(uint256(nonceRaw), 1, type(uint64).max));
        uint256 validUntil = block.timestamp + bound(uint256(validForRaw), 1, 7 days);

        market.setCrossChainController(address(this));
        market.syncCanonicalPriceFromHub(yesPrice, noPrice, validUntil, nonce);

        assertEq(market.canonicalYesPriceE6(), yesPrice);
        assertEq(market.canonicalNoPriceE6(), noPrice);
        assertEq(market.canonicalPriceValidUntil(), validUntil);
        assertEq(market.canonicalPriceNonce(), nonce);
    }

    function testFuzz_SyncCanonicalPrice_RevertOnStaleNonce(uint64 firstNonceRaw, uint64 staleNonceRaw) external {
        uint64 firstNonce = uint64(bound(uint256(firstNonceRaw), 2, type(uint64).max));
        uint64 staleNonce = uint64(bound(uint256(staleNonceRaw), 1, firstNonce));

        market.setCrossChainController(address(this));
        market.syncCanonicalPriceFromHub(600_000, 400_000, block.timestamp + 1 days, firstNonce);

        vm.expectRevert(bytes4(keccak256("PredictionMarket__StaleSyncMessage()")));
        market.syncCanonicalPriceFromHub(600_000, 400_000, block.timestamp + 1 days, staleNonce);
    }

}
