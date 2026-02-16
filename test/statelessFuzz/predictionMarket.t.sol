// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {PredictionMarket} from "src/PredictionMarket.sol";
import {OutcomeToken} from "src/OutcomeToken.sol";
import {MarketConstants, MarketErrors, Resolution} from "src/libraries/MarketTypes.sol";

contract MockMarketFactoryFuzz {
    address public lastRemoved;
    uint256 public removeCount;

    function removeResolvedMarket(address market) external {
        lastRemoved = market;
        removeCount++;
    }
}

contract PredictionMarketStatelessFuzzTest is Test {
    OutcomeToken internal collateral;
    PredictionMarket internal market;
    MockMarketFactoryFuzz internal mockFactory;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal constant FORWARDER = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8;

    uint256 internal constant INITIAL_LIQUIDITY = 10_000e6;

    function setUp() external {
        collateral = new OutcomeToken("USDC", "USDC", address(this));
        mockFactory = new MockMarketFactoryFuzz();

        market = new PredictionMarket(
            "Will ETH close above 5k?",
            address(collateral),
            block.timestamp + 1 days,
            block.timestamp + 2 days,
            address(mockFactory),
            FORWARDER
        );

        collateral.mint(address(market), INITIAL_LIQUIDITY);
        market.seedLiquidity(INITIAL_LIQUIDITY);
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

    function testFuzz_MintCompleteSets_MintsEqualOutcomeTokens(uint96 amountRaw) external {
        uint256 amount = bound(uint256(amountRaw), MarketConstants.MINIMUM_AMOUNT, MarketConstants.MAX_RISK_EXPOSURE);

        uint256 expectedNet = _mintAndApprove(alice, amount);

        assertEq(market.yesToken().balanceOf(alice), expectedNet);
        assertEq(market.noToken().balanceOf(alice), expectedNet);
        assertEq(market.userRiskExposure(alice), amount);
    }

    function testFuzz_RedeemCompleteSets_ReturnsExpectedCollateral(uint96 mintRaw, uint96 redeemRaw) external {
        uint256 mintAmount = bound(uint256(mintRaw), 2e6, MarketConstants.MAX_RISK_EXPOSURE);
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

    function testFuzz_AddLiquidity_UpdatesSharesAndReserves(uint96 amountRaw) external {
        uint256 amount = bound(uint256(amountRaw), 2e6, MarketConstants.MAX_RISK_EXPOSURE);
        uint256 mintedNet = _mintAndApprove(alice, amount);

        uint256 yesReserveBefore = market.yesReserve();
        uint256 noReserveBefore = market.noReserve();
        uint256 totalSharesBefore = market.totalShares();

        vm.prank(alice);
        market.addLiquidity(mintedNet, mintedNet, 0);

        assertEq(market.lpShares(alice), mintedNet);
        assertEq(market.totalShares(), totalSharesBefore + mintedNet);
        assertEq(market.yesReserve(), yesReserveBefore + mintedNet);
        assertEq(market.noReserve(), noReserveBefore + mintedNet);
    }

    function testFuzz_RemoveLiquidity_ReturnsProportionalTokens(uint96 sharesRaw) external {
        uint256 shares = bound(uint256(sharesRaw), 1, INITIAL_LIQUIDITY);

        uint256 yesBefore = market.yesToken().balanceOf(address(this));
        uint256 noBefore = market.noToken().balanceOf(address(this));

        market.removeLiquidity(shares, 0, 0);

        assertEq(market.yesToken().balanceOf(address(this)), yesBefore + shares);
        assertEq(market.noToken().balanceOf(address(this)), noBefore + shares);
        assertEq(market.totalShares(), INITIAL_LIQUIDITY - shares);
    }

    function testFuzz_TransferShares_ConservesShares(uint96 sharesRaw) external {
        uint256 shares = bound(uint256(sharesRaw), 0, INITIAL_LIQUIDITY);

        uint256 beforeSum = market.lpShares(address(this)) + market.lpShares(bob);
        market.transferShares(bob, shares);
        uint256 afterSum = market.lpShares(address(this)) + market.lpShares(bob);

        assertEq(afterSum, beforeSum);
    }

    function testFuzz_SwapYesForNo_QuoteMatchesAndKNonDecreasing(uint96 mintRaw, uint96 yesInRaw) external {
        uint256 mintAmount = bound(uint256(mintRaw), MarketConstants.MINIMUM_AMOUNT, MarketConstants.MAX_RISK_EXPOSURE);
        uint256 mintedNet = _mintAndApprove(alice, mintAmount);

        uint256 yesIn = bound(uint256(yesInRaw), MarketConstants.MINIMUM_SWAP_AMOUNT, mintedNet);

        uint256 kBefore = market.yesReserve() * market.noReserve();
        uint256 noBefore = market.noToken().balanceOf(alice);

        (uint256 quoteOut,) = market.getYesForNoQuote(yesIn);

        vm.prank(alice);
        market.swapYesForNo(yesIn, quoteOut);

        uint256 kAfter = market.yesReserve() * market.noReserve();

        assertEq(market.noToken().balanceOf(alice), noBefore + quoteOut);
        assertGe(kAfter, kBefore);
    }

    function testFuzz_SwapNoForYes_QuoteMatchesAndKNonDecreasing(uint96 mintRaw, uint96 noInRaw) external {
        uint256 mintAmount = bound(uint256(mintRaw), MarketConstants.MINIMUM_AMOUNT, MarketConstants.MAX_RISK_EXPOSURE);
        uint256 mintedNet = _mintAndApprove(alice, mintAmount);

        uint256 noIn = bound(uint256(noInRaw), MarketConstants.MINIMUM_SWAP_AMOUNT, mintedNet);

        uint256 kBefore = market.yesReserve() * market.noReserve();
        uint256 yesBefore = market.yesToken().balanceOf(alice);

        (uint256 quoteOut,) = market.getNoForYesQuote(noIn);

        vm.prank(alice);
        market.swapNoForYes(noIn, quoteOut);

        uint256 kAfter = market.yesReserve() * market.noReserve();

        assertEq(market.yesToken().balanceOf(alice), yesBefore + quoteOut);
        assertGe(kAfter, kBefore);
    }

    function testFuzz_ResolveAndRedeemYes(uint96 mintRaw, uint96 redeemRaw) external {
        uint256 mintAmount = bound(uint256(mintRaw), 2e6, MarketConstants.MAX_RISK_EXPOSURE);
        uint256 mintedNet = _mintAndApprove(alice, mintAmount);
        uint256 redeemAmount = bound(uint256(redeemRaw), MarketConstants.MINIMUM_AMOUNT, mintedNet);

        vm.warp(market.resolutionTime() + 1);
        market.resolve(Resolution.Yes, "ipfs://proof");

        uint256 beforeCollateral = collateral.balanceOf(alice);

        vm.prank(alice);
        market.redeem(redeemAmount);

        uint256 expectedOut =
            redeemAmount - ((redeemAmount * MarketConstants.REDEEM_COMPLETE_SETS_FEE_BPS) / MarketConstants.FEE_PRECISION_BPS);

        assertEq(collateral.balanceOf(alice), beforeCollateral + expectedOut);
    }

    function testFuzz_WithdrawProtocolFees_AfterResolution(uint96 mintRaw, uint96 withdrawRaw) external {
        uint256 mintAmount = bound(uint256(mintRaw), MarketConstants.MINIMUM_AMOUNT, MarketConstants.MAX_RISK_EXPOSURE);
        _mintAndApprove(alice, mintAmount);

        vm.warp(market.resolutionTime() + 1);
        market.resolve(Resolution.Yes, "ipfs://proof");

        uint256 feeBalance = market.protocolCollateralFees();
        vm.assume(feeBalance > 0);

        uint256 withdrawAmount = bound(uint256(withdrawRaw), 1, feeBalance);
        uint256 beforeOwnerBalance = collateral.balanceOf(address(this));

        market.withdrawProtocolFees(withdrawAmount);

        assertEq(collateral.balanceOf(address(this)), beforeOwnerBalance + withdrawAmount);
        assertEq(market.protocolCollateralFees(), feeBalance - withdrawAmount);
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

        vm.expectRevert(PredictionMarket.PredictionMarket__StaleSyncMessage.selector);
        market.syncCanonicalPriceFromHub(600_000, 400_000, block.timestamp + 1 days, staleNonce);
    }

    function testFuzz_GetYesForNoQuote_CanonicalFormula(uint96 yesInRaw, uint32 yesPriceRaw) external {
        uint256 yesIn = bound(uint256(yesInRaw), MarketConstants.MINIMUM_SWAP_AMOUNT, 100_000e6);
        uint256 yesPrice = bound(uint256(yesPriceRaw), 1, MarketConstants.PRICE_PRECISION - 1);
        uint256 noPrice = MarketConstants.PRICE_PRECISION - yesPrice;

        market.setCrossChainController(address(this));
        market.syncCanonicalPriceFromHub(yesPrice, noPrice, block.timestamp + 1 days, 1);

        (uint256 netOut, uint256 fee) = market.getYesForNoQuote(yesIn);

        uint256 grossOut = (yesIn * yesPrice) / noPrice;
        uint256 expectedFee = (grossOut * MarketConstants.SWAP_FEE_BPS) / MarketConstants.FEE_PRECISION_BPS;

        assertEq(fee, expectedFee);
        assertEq(netOut, grossOut - expectedFee);
    }
}
