// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {PredictionMarketRouterVault} from "../../src/router/PredictionMarketRouterVault.sol";
import {PredictionMarket} from "../../src/predictionMarket/PredictionMarket.sol";
import {OutcomeToken} from "../../src/token/OutcomeToken.sol";
import {MarketConstants} from "../../src/libraries/MarketTypes.sol";
import {FeeLib} from "../../src/libraries/FeeLib.sol";
import {IReceiver} from "../../script/interfaces/IReceiver.sol";
import {LMSRTestMath} from "../utils/LMSRTestMath.sol";

interface IRouterVault {
    function mintCompleteSets(address market, uint256 amount) external;
    function redeemCompleteSets(address market, uint256 amount) external;
}

contract PredictionMarketRouterVaultHandler is Test {
    PredictionMarketRouterVault public router;
    PredictionMarket public market;
    OutcomeToken public collateral;
    address public forwarder;
    address public owner;

    address[] internal actors;

    constructor(
        PredictionMarketRouterVault _router,
        PredictionMarket _market,
        OutcomeToken _collateral,
        address _forwarder,
        address _owner
    ) {
        router = _router;
        market = _market;
        collateral = _collateral;
        forwarder = _forwarder;
        owner = _owner;

        actors.push(owner);
        actors.push(address(this));
        actors.push(makeAddr("alice"));
        actors.push(makeAddr("bob"));
        actors.push(makeAddr("charlie"));
    }

    function getActors() external view returns (address[] memory) {
        return actors;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[bound(seed, 0, actors.length - 1)];
    }

    function _ensureApproval(address actor) internal {
        vm.startPrank(actor);
        collateral.approve(address(router), type(uint256).max);
        vm.stopPrank();
    }

    function _depositIfNeeded(address actor, uint256 amount) internal {
        uint256 credits = router.collateralCredits(actor);
        if (credits >= amount) return;

        uint256 delta = amount - credits;
        collateral.mint(actor, delta);
        _ensureApproval(actor);
        vm.prank(actor);
        router.depositCollateral(delta);
    }

    function depositCollateral(uint256 actorSeed, uint256 amountRaw) external {
        address actor = _actor(actorSeed);
        uint256 amount = bound(amountRaw, 1, 200_000e6);
        collateral.mint(actor, amount);
        _ensureApproval(actor);
        vm.prank(actor);
        router.depositCollateral(amount);
    }

    function withdrawCollateral(uint256 actorSeed, uint256 amountRaw) external {
        address actor = _actor(actorSeed);
        uint256 credits = router.collateralCredits(actor);
        if (credits == 0) return;

        uint256 amount = bound(amountRaw, 1, credits);
        vm.prank(actor);
        router.withdrawCollateral(amount);
    }

    function mintCompleteSets(uint256 actorSeed, uint256 amountRaw) external {
        address actor = _actor(actorSeed);
        uint256 amount = bound(amountRaw, MarketConstants.MINIMUM_AMOUNT, 100_000e6);
        _depositIfNeeded(actor, amount);

        vm.prank(actor);
        (bool ok,) = address(router).call(abi.encodeCall(IRouterVault.mintCompleteSets, (address(market), amount)));
        ok;
    }

    function redeemCompleteSets(uint256 actorSeed, uint256 amountRaw) external {
        address actor = _actor(actorSeed);
        address yesToken = address(market.yesToken());
        address noToken = address(market.noToken());
        uint256 yesCredits = router.tokenCredits(actor, yesToken);
        uint256 noCredits = router.tokenCredits(actor, noToken);
        uint256 maxAmount = yesCredits < noCredits ? yesCredits : noCredits;

        if (maxAmount < MarketConstants.MINIMUM_AMOUNT) return;

        uint256 amount = bound(amountRaw, MarketConstants.MINIMUM_AMOUNT, maxAmount);
        vm.prank(actor);
        (bool ok,) = address(router).call(abi.encodeCall(IRouterVault.redeemCompleteSets, (address(market), amount)));
        ok;
    }

    function lmsrBuy(uint256 actorSeed, uint256 outcomeSeed, uint256 sharesRaw, uint256) external {
        address actor = _actor(actorSeed);
        uint8 outcomeIndex = uint8(bound(outcomeSeed, 0, 1));
        uint256 maxShares = market.liquidityParam() / 10; // keep q/b small for test math stability
        if (maxShares < MarketConstants.MINIMUM_LMSR_TRADE_AMOUNT) {
            maxShares = MarketConstants.MINIMUM_LMSR_TRADE_AMOUNT;
        }
        uint256 sharesDelta = bound(sharesRaw, MarketConstants.MINIMUM_LMSR_TRADE_AMOUNT, maxShares);

        uint256 qYes = market.yesSharesOutstanding();
        uint256 qNo = market.noSharesOutstanding();
        uint256 b = market.liquidityParam();

        uint256 costBefore = LMSRTestMath.cost(qYes, qNo, b);
        uint256 qYesNew = outcomeIndex == 0 ? qYes + sharesDelta : qYes;
        uint256 qNoNew = outcomeIndex == 1 ? qNo + sharesDelta : qNo;
        uint256 costAfter = LMSRTestMath.cost(qYesNew, qNoNew, b);
        if (costAfter <= costBefore) return;
        uint256 costDelta = costAfter - costBefore;
        if (costDelta < MarketConstants.MINIMUM_LMSR_TRADE_AMOUNT) return;

        uint256 yesPriceE6 = LMSRTestMath.yesPriceE6(qYesNew, qNoNew, b);
        uint256 noPriceE6 = 1_000_000 - yesPriceE6;

        if (!router.isRiskExempt(actor)) {
            uint256 fee = FeeLib.calculateFee(
                costDelta,
                MarketConstants.LMSR_TRADE_FEE_BPS,
                MarketConstants.FEE_PRECISION_BPS
            );
            uint256 actualCost = costDelta - fee;
            uint256 dynamicCap =
                (market.liquidityParam() * MarketConstants.MAX_EXPOSURE_BPS) / MarketConstants.MAX_EXPOSURE_PRECISION;
            if (router.userRiskExposure(actor) + actualCost > dynamicCap) {
                return;
            }
        }

        _depositIfNeeded(actor, costDelta);

        bytes memory report = abi.encode(
            "routerBuy",
            abi.encode(
                actor,
                address(market),
                outcomeIndex,
                sharesDelta,
                costDelta,
                yesPriceE6,
                noPriceE6,
                market.tradeNonce()
            )
        );

        vm.prank(forwarder);
        IReceiver(address(router)).onReport("", report);
    }

    function lmsrSell(uint256 actorSeed, uint256 outcomeSeed, uint256 sharesRaw, uint256) external {
        address actor = _actor(actorSeed);
        uint8 outcomeIndex = uint8(bound(outcomeSeed, 0, 1));
        address token = outcomeIndex == 0 ? address(market.yesToken()) : address(market.noToken());
        uint256 credits = router.tokenCredits(actor, token);
        uint256 bought = router.userAMMBoughtShares(actor, address(market), outcomeIndex);
        uint256 available = credits < bought ? credits : bought;
        if (available < MarketConstants.MINIMUM_LMSR_TRADE_AMOUNT) return;

        uint256 sharesDelta = bound(sharesRaw, MarketConstants.MINIMUM_LMSR_TRADE_AMOUNT, available);

        uint256 qYes = market.yesSharesOutstanding();
        uint256 qNo = market.noSharesOutstanding();
        uint256 b = market.liquidityParam();

        uint256 costBefore = LMSRTestMath.cost(qYes, qNo, b);
        if (outcomeIndex == 0 && sharesDelta > qYes) return;
        if (outcomeIndex == 1 && sharesDelta > qNo) return;
        uint256 qYesNew = outcomeIndex == 0 ? qYes - sharesDelta : qYes;
        uint256 qNoNew = outcomeIndex == 1 ? qNo - sharesDelta : qNo;
        uint256 costAfter = LMSRTestMath.cost(qYesNew, qNoNew, b);
        if (costBefore <= costAfter) return;
        uint256 refundDelta = costBefore - costAfter;
        if (refundDelta < MarketConstants.MINIMUM_LMSR_TRADE_AMOUNT) return;

        uint256 routerBal = collateral.balanceOf(address(router));
        if (routerBal < MarketConstants.MINIMUM_LMSR_TRADE_AMOUNT) return;
        if (refundDelta > routerBal) refundDelta = routerBal;

        uint256 yesPriceE6 = LMSRTestMath.yesPriceE6(qYesNew, qNoNew, b);
        uint256 noPriceE6 = 1_000_000 - yesPriceE6;

        bytes memory report = abi.encode(
            "routerSell",
            abi.encode(
                actor,
                address(market),
                outcomeIndex,
                sharesDelta,
                refundDelta,
                yesPriceE6,
                noPriceE6,
                market.tradeNonce()
            )
        );

        vm.prank(forwarder);
        IReceiver(address(router)).onReport("", report);
    }

    function setRiskExempt(uint256 actorSeed, bool exempt) external {
        address actor = _actor(actorSeed);
        vm.prank(owner);
        router.setRiskExempt(actor, exempt);
    }
}
