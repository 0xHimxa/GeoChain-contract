// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {PredictionMarketRouterVault} from "../../src/router/PredictionMarketRouterVault.sol";
import {PredictionMarket} from "../../src/predictionMarket/PredictionMarket.sol";
import {MarketDeployer} from "../../src/marketFactory/event-deployer/MarketDeployer.sol";
import {OutcomeToken} from "../../src/token/OutcomeToken.sol";
import {MarketConstants, Resolution} from "../../src/libraries/MarketTypes.sol";
import {FeeLib} from "../../src/libraries/FeeLib.sol";

interface IMockMarket {
    function i_collateral() external view returns (address);
    function yesToken() external view returns (address);
    function noToken() external view returns (address);
    function mintCompleteSets(uint256 amount) external;
    function redeemCompleteSets(uint256 amount) external;
    function redeem(uint256 amount) external;
    function resolution() external view returns (uint8);
    function balanceOf(address account) external view returns (uint256);
    function liquidityParam() external view returns (uint256);
    function disputeProposedResolution(uint8 proposedOutcome) external;
    function executeBuy(address trader, uint8 outcomeIndex, uint256 sharesDelta, uint256 costDelta, uint256 newYesPriceE6, uint256 newNoPriceE6, uint64 nonce) external;
    function executeSell(address trader, uint8 outcomeIndex, uint256 sharesDelta, uint256 refundDelta, uint256 newYesPriceE6, uint256 newNoPriceE6, uint64 nonce) external;
}

contract MockMarketFactoryFuzz {
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

contract PredictionMarketRouterVaultStatelessFuzzTest is Test {
    PredictionMarketRouterVault internal router;
    OutcomeToken internal collateral;
    PredictionMarket internal market;
    MarketDeployer internal marketDeployer;
    MockMarketFactoryFuzz internal mockFactory;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal owner = makeAddr("owner");
    address internal forwarder = makeAddr("forwarder");
    address internal marketFactory = makeAddr("marketFactory");

    uint256 internal constant INITIAL_DEPOSIT = 1000e6;
    uint256 internal constant INITIAL_LIQUIDITY = 10_000e6;
    uint256 internal constant LIQUIDITY_PARAM = 10_000e6;

    function setUp() external {
        collateral = new OutcomeToken("USDC", "USDC", address(this));
        mockFactory = new MockMarketFactoryFuzz();
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

        collateral.mint(address(market), INITIAL_LIQUIDITY);
        market.initializeMarket(LIQUIDITY_PARAM);
        market.setRouterVault(address(router));

        vm.prank(owner);
        router.setMarketAllowed(address(market), true);

        collateral.mint(alice, INITIAL_DEPOSIT * 100);
        vm.prank(alice);
        collateral.approve(address(router), type(uint256).max);

        collateral.mint(bob, INITIAL_DEPOSIT * 100);
        vm.prank(bob);
        collateral.approve(address(router), type(uint256).max);
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

    function _setAgentPermission(address user, address agent, uint32 actionMask, uint128 maxAmount, uint64 expiresAt) internal {
        vm.prank(user);
        router.setAgentPermission(agent, actionMask, maxAmount, expiresAt);
    }

    function testFuzz_SetAgentPermission_Validation(
        address agent,
        uint32 actionMask,
        uint128 maxAmount,
        uint64 expiresAt
    ) external {
        vm.assume(agent != address(0));
        vm.assume(expiresAt > block.timestamp);
        vm.assume(actionMask != 0);
        vm.assume(maxAmount != 0);

        vm.prank(alice);
        router.setAgentPermission(agent, actionMask, maxAmount, expiresAt);

        (bool enabled, uint64 actualExpires, uint128 actualMax, uint32 actualMask) = router.agentPermissions(alice, agent);
        assertTrue(enabled);
        assertEq(actualExpires, expiresAt);
        assertEq(actualMax, maxAmount);
        assertEq(actualMask, actionMask);
    }

    function testFuzz_SetAgentPermission_RevertZeroAddress(uint32 actionMask, uint128 maxAmount) external {
        vm.assume(actionMask != 0);
        vm.assume(maxAmount != 0);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("Router__ZeroAddress()"));
        router.setAgentPermission(address(0), actionMask, maxAmount, uint64(block.timestamp + 1 days));
    }

    function testFuzz_SetAgentPermission_RevertExpired(uint32 actionMask, uint128 maxAmount) external {
        vm.assume(actionMask != 0);
        vm.assume(maxAmount != 0);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("Router__AgentPermissionExpired()"));
        router.setAgentPermission(bob, actionMask, maxAmount, uint64(block.timestamp));
    }

    function testFuzz_SetAgentPermission_RevertZeroActionMask(uint64 expiresAt) external {
        vm.assume(expiresAt > block.timestamp);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("Router__AgentActionNotAllowed()"));
        router.setAgentPermission(bob, 0, 1, expiresAt);
    }

    function testFuzz_SetAgentPermission_RevertZeroMaxAmount(uint32 actionMask, uint64 expiresAt) external {
        vm.assume(actionMask != 0);
        vm.assume(expiresAt > block.timestamp);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("Router__InvalidAmount()"));
        router.setAgentPermission(bob, actionMask, 0, expiresAt);
    }

    function testFuzz_RevokeAgentPermission(address agent) external {
        vm.assume(agent != address(0));

        _setAgentPermission(alice, agent, AGENT_ACTION_MINT, 100e6, uint64(block.timestamp + 1 days));

        vm.prank(alice);
        router.revokeAgentPermission(agent);

        (bool enabled, uint64 expiresAt, uint128 maxAmount, uint32 actionMask) = router.agentPermissions(alice, agent);
        assertFalse(enabled);
        assertEq(expiresAt, 0);
        assertEq(maxAmount, 0);
        assertEq(actionMask, 0);
    }

    function testFuzz_RevokeAgentPermission_RevertZeroAddress() external {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("Router__ZeroAddress()"));
        router.revokeAgentPermission(address(0));
    }

    function testFuzz_DepositCollateral(uint256 amount) external {
        amount = bound(amount, 1, 1000e6);

        uint256 balanceBefore = collateral.balanceOf(alice);
        uint256 routerBalanceBefore = collateral.balanceOf(address(router));

        vm.prank(alice);
        router.depositCollateral(amount);

        assertEq(router.collateralCredits(alice), amount);
        assertEq(router.totalCollateralCredits(), amount);
        assertEq(collateral.balanceOf(address(router)), routerBalanceBefore + amount);
        assertEq(collateral.balanceOf(alice), balanceBefore - amount);
    }

    function testFuzz_DepositFor(uint256 amount, address beneficiary) external {
        amount = bound(amount, 1, 1000e6);
        vm.assume(beneficiary != address(0));

        vm.prank(alice);
        router.depositFor(beneficiary, amount);

        assertEq(router.collateralCredits(beneficiary), amount);
    }

    function testFuzz_DepositFor_RevertZeroBeneficiary(uint256 amount) external {
        amount = bound(amount, 1, 1000e6);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("Router__ZeroAddress()"));
        router.depositFor(address(0), amount);
    }

    function testFuzz_WithdrawCollateral(uint256 depositAmount, uint256 withdrawAmount) external {
        depositAmount = bound(depositAmount, 1, 1000e6);
        withdrawAmount = bound(withdrawAmount, 1, depositAmount);

        vm.prank(alice);
        router.depositCollateral(depositAmount);

        uint256 aliceBalanceBefore = collateral.balanceOf(alice);

        vm.prank(alice);
        router.withdrawCollateral(withdrawAmount);

        assertEq(router.collateralCredits(alice), depositAmount - withdrawAmount);
        assertEq(router.totalCollateralCredits(), depositAmount - withdrawAmount);
        assertEq(collateral.balanceOf(alice), aliceBalanceBefore + withdrawAmount);
    }

    function testFuzz_WithdrawCollateral_RevertInsufficientBalance(uint256 depositAmount, uint256 withdrawAmount) external {
        depositAmount = bound(depositAmount, 1, 500e6);
        withdrawAmount = bound(withdrawAmount, depositAmount + 1, depositAmount * 2);

        vm.prank(alice);
        router.depositCollateral(depositAmount);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("Router__InsufficientBalance()"));
        router.withdrawCollateral(withdrawAmount);
    }

    function testFuzz_MintCompleteSets(uint256 mintAmount) external {
        mintAmount = bound(mintAmount, MarketConstants.MINIMUM_AMOUNT, 100e6);

        vm.prank(alice);
        router.depositCollateral(mintAmount * 2);

        (address yesToken, address noToken) = _getMockMarketTokens(address(market));

        (bool success,) = address(router).call(
            abi.encodeWithSelector(router.mintCompleteSets.selector, address(market), mintAmount)
        );

        if (success) {
            uint256 expectedNet = mintAmount - ((mintAmount * MarketConstants.MINT_COMPLETE_SETS_FEE_BPS) / MarketConstants.FEE_PRECISION_BPS);
            assertEq(router.collateralCredits(alice), mintAmount * 2 - mintAmount);
            assertEq(router.tokenCredits(alice, yesToken), expectedNet);
            assertEq(router.tokenCredits(alice, noToken), expectedNet);
        }
    }

    function testFuzz_MintCompleteSets_RevertMarketNotAllowed(uint256 amount) external {
        amount = bound(amount, 1, 100e6);
        address disallowedMarket = makeAddr("disallowedMarket");

        vm.prank(alice);
        router.depositCollateral(amount);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("Router__MarketNotAllowed()"));
        router.mintCompleteSets(disallowedMarket, amount);
    }

    function testFuzz_MintCompleteSets_RevertInsufficientBalance(uint256 depositAmount, uint256 mintAmount) external {
        depositAmount = bound(depositAmount, 1, 100e6);
        mintAmount = bound(mintAmount, depositAmount + 1, depositAmount * 2);

        vm.prank(alice);
        router.depositCollateral(depositAmount);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("Router__InsufficientBalance()"));
        router.mintCompleteSets(address(market), mintAmount);
    }

    function testFuzz_MintCompleteSets_RevertCollateralMismatch(uint256 amount) external {
        amount = bound(amount, 1, 100e6);
        address fakeMarket = makeAddr("fakeMarket");
        
        vm.prank(owner);
        router.setMarketAllowed(fakeMarket, true);

        vm.prank(alice);
        router.depositCollateral(amount);

        vm.mockCall(fakeMarket, abi.encodeWithSignature("i_collateral()"), abi.encode(address(0)));

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("Router__CollateralMismatch()"));
        router.mintCompleteSets(fakeMarket, amount);

        vm.clearMockedCalls();
    }

    function testFuzz_MintCompleteSets_RevertMarketNotInitialized(uint256 amount) external {
        amount = bound(amount, 1, 100e6);
        address fakeMarket = makeAddr("fakeMarket");

        vm.prank(owner);
        router.setMarketAllowed(fakeMarket, true);

        vm.prank(alice);
        router.depositCollateral(amount);

        vm.mockCall(fakeMarket, abi.encodeWithSignature("i_collateral()"), abi.encode(address(collateral)));
        vm.mockCall(fakeMarket, abi.encodeWithSignature("liquidityParam()"), abi.encode(uint256(0)));

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("Router__MarketNotInitialized()"));
        router.mintCompleteSets(fakeMarket, amount);

        vm.clearMockedCalls();
    }

    function testFuzz_MintCompleteSets_ExposuresNotExceedCap(uint256 depositAmount, uint256 mintAmount) external {
        uint256 dynamicCap =
            (LIQUIDITY_PARAM * MarketConstants.MAX_EXPOSURE_BPS) / MarketConstants.MAX_EXPOSURE_PRECISION;
        depositAmount = bound(depositAmount, MarketConstants.MINIMUM_AMOUNT, dynamicCap);
        mintAmount = bound(mintAmount, MarketConstants.MINIMUM_AMOUNT, depositAmount);
        
        vm.prank(alice);
        router.depositCollateral(depositAmount);

        vm.prank(alice);
        router.mintCompleteSets(address(market), mintAmount);

        assertLe(router.userRiskExposure(alice), dynamicCap);
    }

    function testFuzz_RedeemCompleteSets(uint256 mintAmount, uint256 redeemAmount) external {
        mintAmount = bound(mintAmount, MarketConstants.MINIMUM_AMOUNT * 2, 500e6);
        redeemAmount = bound(redeemAmount, MarketConstants.MINIMUM_AMOUNT, mintAmount / 2);

        vm.prank(alice);
        router.depositCollateral(mintAmount);

        vm.prank(alice);
        router.mintCompleteSets(address(market), mintAmount);

        (address yesToken, address noToken) = _getMockMarketTokens(address(market));

        vm.prank(alice);
        router.redeemCompleteSets(address(market), redeemAmount);

        uint256 netMint = mintAmount - ((mintAmount * MarketConstants.MINT_COMPLETE_SETS_FEE_BPS) / MarketConstants.FEE_PRECISION_BPS);
        assertEq(router.tokenCredits(alice, yesToken), netMint - redeemAmount);
        assertEq(router.tokenCredits(alice, noToken), netMint - redeemAmount);
    }

    function testFuzz_RedeemCompleteSets_RevertInsufficientBalance(uint256 mintAmount, uint256 redeemAmount) external {
        mintAmount = bound(mintAmount, MarketConstants.MINIMUM_AMOUNT * 2, 200e6);
        redeemAmount = bound(redeemAmount, mintAmount + 1, mintAmount * 2);

        vm.prank(alice);
        router.depositCollateral(mintAmount);

        vm.prank(alice);
        router.mintCompleteSets(address(market), mintAmount);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("Router__InsufficientBalance()"));
        router.redeemCompleteSets(address(market), redeemAmount);
    }

    function testFuzz_RedeemCompleteSets_RevertMarketNotAllowed(uint256 amount) external {
        amount = bound(amount, 1, 100e6);
        address disallowedMarket = makeAddr("disallowedMarket");

        vm.prank(alice);
        router.depositCollateral(amount);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("Router__MarketNotAllowed()"));
        router.redeemCompleteSets(disallowedMarket, amount);
    }

    function testFuzz_RedeemWinnings(uint256 mintAmount, uint256 redeemAmount) external {
        mintAmount = bound(mintAmount, MarketConstants.MINIMUM_AMOUNT * 2, 500e6);
        redeemAmount = bound(redeemAmount, MarketConstants.MINIMUM_AMOUNT, mintAmount / 2);

        vm.prank(alice);
        router.depositCollateral(mintAmount);

        vm.prank(alice);
        router.mintCompleteSets(address(market), mintAmount);

        vm.warp(block.timestamp + 3 days);
        _resolveAndFinalize(Resolution.Yes, "ipfs://proof");

        (address yesToken,) = _getMockMarketTokens(address(market));
        uint256 collateralBefore = router.collateralCredits(alice);
        uint256 winningBefore = router.tokenCredits(alice, yesToken);

        vm.prank(alice);
        router.redeem(address(market), redeemAmount);

        uint256 expectedRedeemOut = redeemAmount - ((redeemAmount * MarketConstants.REDEEM_COMPLETE_SETS_FEE_BPS) / MarketConstants.FEE_PRECISION_BPS);
        assertEq(router.collateralCredits(alice), collateralBefore + expectedRedeemOut);
        assertEq(router.tokenCredits(alice, yesToken), winningBefore - redeemAmount);
    }

    function testFuzz_RedeemWinnings_RevertNotResolved(uint256 mintAmount, uint256 redeemAmount) external {
        mintAmount = bound(mintAmount, MarketConstants.MINIMUM_AMOUNT * 2, 200e6);
        redeemAmount = bound(redeemAmount, MarketConstants.MINIMUM_AMOUNT, mintAmount);

        vm.prank(alice);
        router.depositCollateral(mintAmount);

        vm.prank(alice);
        router.mintCompleteSets(address(market), mintAmount);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("Router__MarketNotResolved()"));
        router.redeem(address(market), redeemAmount);
    }

    function testFuzz_RedeemWinnings_RevertInsufficientBalance(uint256 mintAmount, uint256 redeemAmount) external {
        mintAmount = bound(mintAmount, MarketConstants.MINIMUM_AMOUNT * 2, 200e6);
        redeemAmount = bound(redeemAmount, mintAmount + 1, mintAmount * 2);

        vm.prank(alice);
        router.depositCollateral(mintAmount);

        vm.prank(alice);
        router.mintCompleteSets(address(market), mintAmount);

        vm.warp(block.timestamp + 3 days);
        _resolveAndFinalize(Resolution.Yes, "ipfs://proof");

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("Router__InsufficientBalance()"));
        router.redeem(address(market), redeemAmount);
    }

    function testFuzz_WithdrawOutcomeToken(uint256 mintAmount, uint256 withdrawAmount) external {
        mintAmount = bound(mintAmount, MarketConstants.MINIMUM_AMOUNT * 2, 500e6);
        withdrawAmount = bound(withdrawAmount, MarketConstants.MINIMUM_AMOUNT, mintAmount / 2);

        vm.prank(alice);
        router.depositCollateral(mintAmount);

        vm.prank(alice);
        router.mintCompleteSets(address(market), mintAmount);

        (address yesToken,) = _getMockMarketTokens(address(market));

        vm.prank(alice);
        router.withdrawOutcomeToken(yesToken, withdrawAmount);

        uint256 netMint = mintAmount - ((mintAmount * MarketConstants.MINT_COMPLETE_SETS_FEE_BPS) / MarketConstants.FEE_PRECISION_BPS);
        assertEq(router.tokenCredits(alice, yesToken), netMint - withdrawAmount);
    }

    function testFuzz_WithdrawOutcomeToken_RevertInsufficientBalance(uint256 mintAmount, uint256 withdrawAmount) external {
        mintAmount = bound(mintAmount, MarketConstants.MINIMUM_AMOUNT * 2, 200e6);
        withdrawAmount = bound(withdrawAmount, mintAmount + 1, mintAmount * 2);

        vm.prank(alice);
        router.depositCollateral(mintAmount);

        vm.prank(alice);
        router.mintCompleteSets(address(market), mintAmount);

        (address yesToken,) = _getMockMarketTokens(address(market));

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("Router__InsufficientBalance()"));
        router.withdrawOutcomeToken(yesToken, withdrawAmount);
    }

    function testFuzz_AgentMintCompleteSets(
        uint256 mintAmount
    ) external {
        mintAmount = bound(mintAmount, MarketConstants.MINIMUM_AMOUNT, 100e6);

        vm.prank(alice);
        router.depositCollateral(mintAmount * 2);

        vm.prank(alice);
        router.setAgentPermission(bob, AGENT_ACTION_MINT, uint128(mintAmount * 2), uint64(block.timestamp + 1 days));

        vm.prank(bob);
        
        (bool success,) = address(router).call(
            abi.encodeWithSelector(router.mintCompleteSetsFor.selector, alice, address(market), mintAmount)
        );

        if (success) {
            (address yesToken, address noToken) = _getMockMarketTokens(address(market));
            uint256 expectedNet = mintAmount - ((mintAmount * MarketConstants.MINT_COMPLETE_SETS_FEE_BPS) / MarketConstants.FEE_PRECISION_BPS);
            assertEq(router.tokenCredits(alice, yesToken), expectedNet);
            assertEq(router.tokenCredits(alice, noToken), expectedNet);
        }
    }

    function testFuzz_AgentMintCompleteSets_RevertNotAuthorized(
        uint256 mintAmount,
        uint32 actionMask,
        uint128 maxAmount
    ) external {
        mintAmount = bound(mintAmount, 1, 100e6);
        
        vm.prank(alice);
        router.depositCollateral(mintAmount * 2);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSignature("Router__AgentNotAuthorized()"));
        router.mintCompleteSetsFor(alice, address(market), mintAmount);
    }

    function testFuzz_AgentMintCompleteSets_RevertExpiredPermission(uint256 mintAmount) external {
        mintAmount = bound(mintAmount, 1, 100e6);

        vm.prank(alice);
        router.depositCollateral(mintAmount * 2);

        vm.prank(alice);
        router.setAgentPermission(bob, AGENT_ACTION_MINT, 1000e6, uint64(block.timestamp + 1));

        vm.warp(block.timestamp + 2);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSignature("Router__AgentPermissionExpired()"));
        router.mintCompleteSetsFor(alice, address(market), mintAmount);
    }

    function testFuzz_AgentMintCompleteSets_RevertAmountExceeded(
        uint256 mintAmount,
        uint256 maxAmountRaw
    ) external {
        mintAmount = bound(mintAmount, 2, 100e6);
        uint128 maxAmount = uint128(bound(maxAmountRaw, 1, mintAmount - 1));

        vm.prank(alice);
        router.depositCollateral(mintAmount * 2);

        _setAgentPermission(alice, bob, AGENT_ACTION_MINT, maxAmount, uint64(block.timestamp + 1 days));

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSignature("Router__AgentAmountExceeded()"));
        router.mintCompleteSetsFor(alice, address(market), mintAmount);
    }

    function testFuzz_AgentMintCompleteSets_RevertActionNotAllowed(
        uint256 mintAmount,
        uint32 actionMask
    ) external {
        mintAmount = bound(mintAmount, 1, 100e6);
        vm.assume(actionMask != 0);
        vm.assume(actionMask & AGENT_ACTION_MINT == 0);

        vm.prank(alice);
        router.depositCollateral(mintAmount * 2);

        _setAgentPermission(alice, bob, actionMask, 1000e6, uint64(block.timestamp + 1 days));

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSignature("Router__AgentActionNotAllowed()"));
        router.mintCompleteSetsFor(alice, address(market), mintAmount);
    }

    function testFuzz_AgentRedeemCompleteSets(
        uint256 mintAmount,
        uint256 redeemAmount,
        uint32 actionMask,
        uint128 maxAmount
    ) external {
        mintAmount = bound(mintAmount, MarketConstants.MINIMUM_AMOUNT * 4, 500e6);
        redeemAmount = bound(redeemAmount, MarketConstants.MINIMUM_AMOUNT, mintAmount / 2);
        vm.assume(actionMask & AGENT_ACTION_REDEEM_COMPLETE_SETS != 0);
        vm.assume(maxAmount >= redeemAmount);

        vm.prank(alice);
        router.depositCollateral(mintAmount);

        vm.prank(alice);
        router.mintCompleteSets(address(market), mintAmount);

        _setAgentPermission(alice, bob, actionMask, maxAmount, uint64(block.timestamp + 1 days));

        vm.prank(bob);
        router.redeemCompleteSetsFor(alice, address(market), redeemAmount);

        (address yesToken, address noToken) = _getMockMarketTokens(address(market));
        uint256 netMint = mintAmount - ((mintAmount * MarketConstants.MINT_COMPLETE_SETS_FEE_BPS) / MarketConstants.FEE_PRECISION_BPS);
        assertEq(router.tokenCredits(alice, yesToken), netMint - redeemAmount);
    }

    function testFuzz_AgentRedeemWinnings(
        uint256 mintAmount,
        uint256 redeemAmount,
        uint32 actionMask,
        uint128 maxAmount
    ) external {
        mintAmount = bound(mintAmount, MarketConstants.MINIMUM_AMOUNT * 4, 500e6);
        redeemAmount = bound(redeemAmount, MarketConstants.MINIMUM_AMOUNT, mintAmount / 2);
        vm.assume(actionMask & AGENT_ACTION_REDEEM_WINNINGS != 0);
        vm.assume(maxAmount >= redeemAmount);

        vm.prank(alice);
        router.depositCollateral(mintAmount);

        vm.prank(alice);
        router.mintCompleteSets(address(market), mintAmount);

        vm.warp(block.timestamp + 3 days);
        _resolveAndFinalize(Resolution.Yes, "ipfs://proof");

        _setAgentPermission(alice, bob, actionMask, maxAmount, uint64(block.timestamp + 1 days));

        vm.prank(bob);
        router.redeemFor(alice, address(market), redeemAmount);

        uint256 expectedOut = redeemAmount - ((redeemAmount * MarketConstants.REDEEM_COMPLETE_SETS_FEE_BPS) / MarketConstants.FEE_PRECISION_BPS);
        assertGt(router.collateralCredits(alice), 0);
    }

    function testFuzz_SetMarketAllowed_ByOwner(address newMarket) external {
        vm.assume(newMarket != address(0));

        vm.prank(owner);
        router.setMarketAllowed(newMarket, true);

        assertTrue(router.allowedMarkets(newMarket));

        vm.prank(owner);
        router.setMarketAllowed(newMarket, false);

        assertFalse(router.allowedMarkets(newMarket));
    }

    function testFuzz_SetMarketAllowed_ByFactory(address newMarket) external {
        vm.assume(newMarket != address(0));

        vm.prank(marketFactory);
        router.setMarketAllowed(newMarket, true);

        assertTrue(router.allowedMarkets(newMarket));
    }

    function testFuzz_SetMarketAllowed_RevertUnauthorized(address newMarket) external {
        vm.assume(newMarket != address(0));

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("PredictionMarketRouterVault__NotAuthorizedMarketMapper()"));
        router.setMarketAllowed(newMarket, true);
    }

    function testFuzz_SetMarketAllowed_RevertZeroAddress() external {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSignature("Router__ZeroAddress()"));
        router.setMarketAllowed(address(0), true);
    }

    function testFuzz_SetRiskExempt(address account, bool exempt) external {
        vm.assume(account != address(0));

        vm.prank(owner);
        router.setRiskExempt(account, exempt);

        assertEq(router.isRiskExempt(account), exempt);
    }

    function testFuzz_SetRiskExempt_RevertUnauthorized(address account) external {
        vm.assume(account != address(0));

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", alice));
        router.setRiskExempt(account, true);
    }

    function testFuzz_SetRiskExempt_RevertZeroAddress() external {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSignature("Router__ZeroAddress()"));
        router.setRiskExempt(address(0), true);
    }

    function testFuzz_WithdrawEth(uint256 ethAmount, uint256 withdrawAmount) external {
        ethAmount = bound(ethAmount, 1 ether, 10 ether);
        withdrawAmount = bound(withdrawAmount, 1 ether, ethAmount);

        vm.deal(alice, ethAmount);
        vm.prank(alice);
        (bool success,) = address(router).call{value: ethAmount}("");
        assertTrue(success);

        uint256 ownerBalanceBefore = owner.balance;

        vm.prank(owner);
        router.withdrawEth(payable(owner), withdrawAmount);

        assertEq(owner.balance, ownerBalanceBefore + withdrawAmount);
        assertEq(address(router).balance, ethAmount - withdrawAmount);
    }

    function testFuzz_WithdrawEth_RevertUnauthorized(uint256 withdrawAmount) external {
        vm.assume(withdrawAmount > 0);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", alice));
        router.withdrawEth(payable(alice), withdrawAmount);
    }

    function testFuzz_WithdrawEth_RevertZeroAddress(uint256 amount) external {
        vm.assume(amount > 0);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSignature("Router__ZeroAddress()"));
        router.withdrawEth(payable(address(0)), amount);
    }

    function testFuzz_WithdrawEth_RevertInvalidAmount(uint256 ethAmount) external {
        ethAmount = bound(ethAmount, 1 ether, 10 ether);
        
        vm.deal(alice, ethAmount);
        vm.prank(alice);
        (bool success,) = address(router).call{value: ethAmount}("");
        assertTrue(success);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSignature("Router__InvalidAmount()"));
        router.withdrawEth(payable(owner), 0);
    }

    function testFuzz_WithdrawEth_RevertInsufficientBalance(uint256 withdrawAmount) external {
        vm.assume(withdrawAmount > 0);
        
        vm.assume(address(router).balance < withdrawAmount);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSignature("Router__InsufficientBalance()"));
        router.withdrawEth(payable(owner), withdrawAmount);
    }

    function testFuzz_GetUntrackedCollateral(uint256 mintAmount) external {
        mintAmount = bound(mintAmount, MarketConstants.MINIMUM_AMOUNT, 1000e6);

        assertEq(router.getUntrackedCollateral(), 0);

        collateral.mint(address(router), mintAmount);

        assertEq(router.getUntrackedCollateral(), mintAmount);
    }

    function testFuzz_OnReportCreditFromFiat(uint256 amount) external {
        amount = bound(amount, 1, 1000e6);

        collateral.mint(address(router), amount);

        bytes memory creditFiatReport = abi.encode("routerCreditFromFiat", abi.encode(alice, amount));
        vm.prank(forwarder);
        router.onReport("", creditFiatReport);

        assertEq(router.collateralCredits(alice), amount);
    }

    function testFuzz_OnReportCreditFromEth(uint256 amount) external {
        amount = bound(amount, 1, 1000e6);

        collateral.mint(address(router), amount);

        bytes32 depositId = keccak256(abi.encodePacked(block.timestamp, alice, amount));
        bytes memory creditEthReport = abi.encode("routerCreditFromEth", abi.encode(alice, amount, depositId));
        vm.prank(forwarder);
        router.onReport("", creditEthReport);

        assertEq(router.collateralCredits(alice), amount);
    }

    function testFuzz_OnReportCreditFromEth_RevertDuplicateDepositId(uint256 amount) external {
        amount = bound(amount, 1, 1000e6);

        collateral.mint(address(router), amount * 2);

        bytes32 depositId = keccak256("dep-1");
        bytes memory creditEthReport = abi.encode("routerCreditFromEth", abi.encode(alice, amount, depositId));
        
        vm.prank(forwarder);
        router.onReport("", creditEthReport);

        vm.prank(forwarder);
        vm.expectRevert(abi.encodeWithSignature("Router__EthDepositAlreadyProcessed()"));
        router.onReport("", creditEthReport);
    }

    function testFuzz_OnReportCreditFromEth_RevertZeroDepositId(uint256 amount) external {
        amount = bound(amount, 1, 1000e6);

        collateral.mint(address(router), amount);

        bytes32 depositId = bytes32(0);
        bytes memory creditEthReport = abi.encode("routerCreditFromEth", abi.encode(alice, amount, depositId));
        
        vm.prank(forwarder);
        vm.expectRevert(abi.encodeWithSignature("Router__InvalidDepositId()"));
        router.onReport("", creditEthReport);
    }

    function testFuzz_OnReportCreditFromFiat_RevertInsufficientUntrackedCollateral(uint256 depositAmount, uint256 creditAmount) external {
        depositAmount = bound(depositAmount, 1, 500e6);
        creditAmount = bound(creditAmount, depositAmount + 1, depositAmount * 2);

        collateral.mint(address(router), depositAmount);

        bytes memory creditFiatReport = abi.encode("routerCreditFromFiat", abi.encode(alice, creditAmount));
        
        vm.prank(forwarder);
        vm.expectRevert(abi.encodeWithSignature("Router__InsufficientUntrackedCollateral()"));
        router.onReport("", creditFiatReport);
    }

    function testFuzz_OnReportUnknownAction() external {
        bytes memory unknown = abi.encode("routerUnknownAction", abi.encode(uint256(1)));
        
        vm.prank(forwarder);
        vm.expectRevert(abi.encodeWithSignature("Router__ActionNotRecognized()"));
        router.onReport("", unknown);
    }

    function testFuzz_OnReportBuyUpdatesExposure(uint256 costDelta, uint256 sharesDelta) external {
        costDelta = bound(costDelta, MarketConstants.MINIMUM_LMSR_TRADE_AMOUNT, 200e6);
        sharesDelta = bound(sharesDelta, MarketConstants.MINIMUM_LMSR_TRADE_AMOUNT, 50e6);

        vm.prank(alice);
        router.depositCollateral(costDelta);

        bytes memory buyReport = abi.encode(
            "routerBuy",
            abi.encode(alice, address(market), uint8(0), sharesDelta, costDelta, 600_000, 400_000, uint64(0))
        );
        vm.prank(forwarder);
        router.onReport("", buyReport);

        (address yesToken,) = _getMockMarketTokens(address(market));
        uint256 fee = FeeLib.calculateFee(
            costDelta,
            MarketConstants.LMSR_TRADE_FEE_BPS,
            MarketConstants.FEE_PRECISION_BPS
        );
        uint256 actualCost = costDelta - fee;

        assertEq(router.tokenCredits(alice, yesToken), sharesDelta);
        assertEq(router.userAMMBoughtShares(alice, address(market), 0), sharesDelta);
        assertEq(router.userRiskExposure(alice), actualCost);
    }

    function testFuzz_OnReportSellUpdatesExposure(uint256 buyCostDelta, uint256 sellSharesDelta, uint256 refundDelta)
        external
    {
        buyCostDelta = bound(buyCostDelta, MarketConstants.MINIMUM_LMSR_TRADE_AMOUNT, 200e6);
        sellSharesDelta = bound(sellSharesDelta, MarketConstants.MINIMUM_LMSR_TRADE_AMOUNT, 50e6);
        refundDelta = bound(refundDelta, MarketConstants.MINIMUM_LMSR_TRADE_AMOUNT, 100e6);

        vm.prank(alice);
        router.depositCollateral(buyCostDelta);

        bytes memory buyReport = abi.encode(
            "routerBuy",
            abi.encode(alice, address(market), uint8(0), sellSharesDelta, buyCostDelta, 600_000, 400_000, uint64(0))
        );
        vm.prank(forwarder);
        router.onReport("", buyReport);

        uint256 collateralBefore = router.collateralCredits(alice);
        uint256 exposureBefore = router.userRiskExposure(alice);

        bytes memory sellReport = abi.encode(
            "routerSell",
            abi.encode(alice, address(market), uint8(0), sellSharesDelta, refundDelta, 590_000, 410_000, uint64(1))
        );
        vm.prank(forwarder);
        router.onReport("", sellReport);

        uint256 fee = FeeLib.calculateFee(
            refundDelta,
            MarketConstants.LMSR_TRADE_FEE_BPS,
            MarketConstants.FEE_PRECISION_BPS
        );
        uint256 netRefund = refundDelta - fee;

        assertEq(router.collateralCredits(alice), collateralBefore + netRefund);
        assertEq(router.userRiskExposure(alice), exposureBefore > refundDelta ? exposureBefore - refundDelta : 0);
        assertEq(router.userAMMBoughtShares(alice, address(market), 0), sellSharesDelta - sellSharesDelta);
    }

    function testFuzz_OnReportSellRevertWhenNotAMMBought(uint256 mintAmount) external {
        mintAmount = bound(mintAmount, MarketConstants.MINIMUM_AMOUNT, 100e6);

        vm.prank(alice);
        router.depositCollateral(mintAmount);

        vm.prank(alice);
        router.mintCompleteSets(address(market), mintAmount);

        bytes memory sellReport = abi.encode(
            "routerSell",
            abi.encode(alice, address(market), uint8(0), mintAmount, mintAmount, 590_000, 410_000, uint64(0))
        );
        vm.prank(forwarder);
        vm.expectRevert(abi.encodeWithSignature("Router__InsufficientAMMBoughtShares()"));
        router.onReport("", sellReport);
    }

    function testFuzz_OnReportRevokeAgentPermission(address agent) external {
        vm.assume(agent != address(0));

        _setAgentPermission(alice, agent, AGENT_ACTION_MINT, 100e6, uint64(block.timestamp + 1 days));
        
        (bool enabledBefore,,,) = router.agentPermissions(alice, agent);
        assertTrue(enabledBefore);

        bytes memory revokeReport = abi.encode("routerAgentRevokePermission", abi.encode(alice, agent));
        vm.prank(forwarder);
        router.onReport("", revokeReport);

        (bool enabledAfter, uint64 expiresAt, uint128 maxAmount, uint32 actionMask) = router.agentPermissions(alice, agent);
        assertFalse(enabledAfter);
        assertEq(expiresAt, 0);
        assertEq(maxAmount, 0);
        assertEq(actionMask, 0);
    }

    function testFuzz_RiskExposureCalculation(uint256 mintAmount) external {
        uint256 dynamicCap =
            (LIQUIDITY_PARAM * MarketConstants.MAX_EXPOSURE_BPS) / MarketConstants.MAX_EXPOSURE_PRECISION;
        mintAmount = bound(mintAmount, MarketConstants.MINIMUM_AMOUNT, dynamicCap);

        vm.prank(alice);
        router.depositCollateral(mintAmount);

        vm.prank(alice);
        router.mintCompleteSets(address(market), mintAmount);

        assertLe(router.userRiskExposure(alice), dynamicCap);
    }

    function testFuzz_RiskExemptBypassesExposureCheck(uint256 mintAmount) external {
        uint256 dynamicCap =
            (LIQUIDITY_PARAM * MarketConstants.MAX_EXPOSURE_BPS) / MarketConstants.MAX_EXPOSURE_PRECISION;
        mintAmount = bound(mintAmount, MarketConstants.MINIMUM_AMOUNT, dynamicCap * 2);

        vm.prank(owner);
        router.setRiskExempt(alice, true);
        market.setRiskExempt(alice, true);

        vm.prank(alice);
        router.depositCollateral(mintAmount);

        vm.prank(alice);
        router.mintCompleteSets(address(market), mintAmount);

        assertEq(router.userRiskExposure(alice), 0);
    }

    function testFuzz_MultipleDepositsAndWithdrawals(uint256[] memory amounts) external {
        vm.assume(amounts.length > 0 && amounts.length <= 10);
        for (uint256 i = 0; i < amounts.length; i++) {
            amounts[i] = bound(amounts[i], 1, 100e6);
        }

        uint256 totalDeposited;
        for (uint256 i = 0; i < amounts.length; i++) {
            vm.prank(alice);
            router.depositCollateral(amounts[i]);
            totalDeposited += amounts[i];
        }

        assertEq(router.collateralCredits(alice), totalDeposited);

        for (uint256 i = 0; i < amounts.length; i++) {
            vm.prank(alice);
            router.withdrawCollateral(amounts[i]);
            totalDeposited -= amounts[i];
            assertEq(router.collateralCredits(alice), totalDeposited);
        }
    }

    function testFuzz_ReentrancyGuardDeposit(uint256 amount) external {
        amount = bound(amount, 1, 100e6);

        vm.prank(alice);
        router.depositCollateral(amount);
    }

    function testFuzz_ReentrancyGuardWithdraw(uint256 amount) external {
        amount = bound(amount, 1, 100e6);

        vm.prank(alice);
        router.depositCollateral(amount);

        vm.prank(alice);
        router.withdrawCollateral(amount);
    }

    function testFuzz_DisputeProposedResolution(uint8 proposedOutcome) external {
        vm.assume(proposedOutcome == 1 || proposedOutcome == 2);

        vm.warp(block.timestamp + 3 days);
        market.resolve(Resolution(proposedOutcome), "ipfs://proof");

        vm.prank(alice);
        router.disputeProposedResolution(address(market), proposedOutcome);
    }

    function testFuzz_AgentDisputeProposedResolution(uint8 proposedOutcome, uint32 actionMask) external {
        vm.assume(proposedOutcome == 1 || proposedOutcome == 2);
        vm.assume(actionMask & AGENT_ACTION_DISPUTE != 0);

        vm.warp(block.timestamp + 3 days);
        market.resolve(Resolution(proposedOutcome), "ipfs://proof");

        vm.prank(alice);
        router.setAgentPermission(bob, actionMask, 1, uint64(block.timestamp + 1 days));

        vm.prank(bob);
        router.disputeProposedResolutionFor(alice, address(market), proposedOutcome);
    }

    function testFuzz_AgentDisputeRevertsWithoutPermission(uint8 proposedOutcome) external {
        vm.assume(proposedOutcome == 1 || proposedOutcome == 2);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSignature("Router__AgentNotAuthorized()"));
        router.disputeProposedResolutionFor(alice, address(market), proposedOutcome);
    }

    uint32 internal constant AGENT_ACTION_MINT = 1 << 0;
    uint32 internal constant AGENT_ACTION_REDEEM_COMPLETE_SETS = 1 << 1;
    uint32 internal constant AGENT_ACTION_REDEEM_WINNINGS = 1 << 2;
    uint32 internal constant AGENT_ACTION_DISPUTE = 1 << 3;
    uint32 internal constant AGENT_ACTION_BUY = 1 << 4;
    uint32 internal constant AGENT_ACTION_SELL = 1 << 5;
}
