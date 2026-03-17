// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {PredictionMarket} from "../../src/predictionMarket/PredictionMarket.sol";
import {OutcomeToken} from "../../src/token/OutcomeToken.sol";
import {MarketConstants} from "../../src/libraries/MarketTypes.sol";
import {FeeLib} from "../../src/libraries/FeeLib.sol";
import {IReceiver} from "../../script/interfaces/IReceiver.sol";
import {LMSRTestMath} from "../utils/LMSRTestMath.sol";

contract PredictionMarketHandler is Test {
    PredictionMarket public market;
    OutcomeToken public collateral;
    address public forwarder;

    address[] internal actors;

    constructor(PredictionMarket _market, OutcomeToken _collateral, address _forwarder, address ownerActor) {
        market = _market;
        collateral = _collateral;
        forwarder = _forwarder;

        actors.push(ownerActor);
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

    function _ensureApprovals(address actor) internal {
        vm.startPrank(actor);
        collateral.approve(address(market), type(uint256).max);
        market.yesToken().approve(address(market), type(uint256).max);
        market.noToken().approve(address(market), type(uint256).max);
        vm.stopPrank();
    }

    function mintCompleteSets(uint256 actorSeed, uint256 amountRaw) external {
        address actor = _actor(actorSeed);
        uint256 amount = bound(amountRaw, MarketConstants.MINIMUM_AMOUNT, 2_000e6);

        collateral.mint(actor, amount);
        _ensureApprovals(actor);

        vm.startPrank(actor);
        (bool ok,) = address(market).call(abi.encodeWithSelector(PredictionMarket.mintCompleteSets.selector, amount));
        ok;
        vm.stopPrank();
    }

    function redeemCompleteSets(uint256 actorSeed, uint256 amountRaw) external {
        address actor = _actor(actorSeed);
        uint256 yesBal = market.yesToken().balanceOf(actor);
        uint256 noBal = market.noToken().balanceOf(actor);
        uint256 maxAmount = yesBal < noBal ? yesBal : noBal;

        if (maxAmount < MarketConstants.MINIMUM_AMOUNT) return;

        uint256 amount = bound(amountRaw, MarketConstants.MINIMUM_AMOUNT, maxAmount);
        _ensureApprovals(actor);

        vm.startPrank(actor);
        (bool ok,) = address(market).call(abi.encodeWithSelector(PredictionMarket.redeemCompleteSets.selector, amount));
        ok;
        vm.stopPrank();
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

        if (!market.isRiskExempt(actor)) {
            uint256 fee = FeeLib.calculateFee(
                costDelta,
                MarketConstants.LMSR_TRADE_FEE_BPS,
                MarketConstants.FEE_PRECISION_BPS
            );
            uint256 actualCost = costDelta - fee;
            // Market enforces exposure with costDelta (pre-fee), so mirror that here
            uint256 dynamicCap =
                (market.liquidityParam() * MarketConstants.MAX_EXPOSURE_BPS) / MarketConstants.MAX_EXPOSURE_PRECISION;
            if (market.userRiskExposure(actor) + actualCost > dynamicCap) {
                return;
            }
        }

        collateral.mint(actor, costDelta);
        _ensureApprovals(actor);

        uint64 nonce = market.tradeNonce();
        bytes memory report = abi.encode(
            "LMSRBuy",
            abi.encode(actor, outcomeIndex, sharesDelta, costDelta, yesPriceE6, noPriceE6, nonce)
        );

        vm.prank(forwarder);
        IReceiver(address(market)).onReport("", report);
    }

    function lmsrSell(uint256 actorSeed, uint256 outcomeSeed, uint256 sharesRaw, uint256) external {
        address actor = _actor(actorSeed);
        uint8 outcomeIndex = uint8(bound(outcomeSeed, 0, 1));

        uint256 tokenBal = outcomeIndex == 0 ? market.yesToken().balanceOf(actor) : market.noToken().balanceOf(actor);
        if (tokenBal < MarketConstants.MINIMUM_LMSR_TRADE_AMOUNT) return;

        uint256 sharesDelta = bound(sharesRaw, MarketConstants.MINIMUM_LMSR_TRADE_AMOUNT, tokenBal);

        uint256 qYes = market.yesSharesOutstanding();
        uint256 qNo = market.noSharesOutstanding();
        uint256 b = market.liquidityParam();

        uint256 costBefore = LMSRTestMath.cost(qYes, qNo, b);
        uint256 qYesNew = outcomeIndex == 0 ? qYes - sharesDelta : qYes;
        uint256 qNoNew = outcomeIndex == 1 ? qNo - sharesDelta : qNo;
        uint256 costAfter = LMSRTestMath.cost(qYesNew, qNoNew, b);
        if (costBefore <= costAfter) return;
        uint256 refundDelta = costBefore - costAfter;
        if (refundDelta < MarketConstants.MINIMUM_LMSR_TRADE_AMOUNT) return;

        uint256 marketBal = collateral.balanceOf(address(market));
       // if (marketBal < MarketConstants.MINIMUM_LMSR_TRADE_AMOUNT) return;
        if (refundDelta > marketBal) refundDelta = marketBal;

        uint256 yesPriceE6 = LMSRTestMath.yesPriceE6(qYesNew, qNoNew, b);
        uint256 noPriceE6 = 1_000_000 - yesPriceE6;

        uint64 nonce = market.tradeNonce();
        bytes memory report = abi.encode(
            "LMSRSell",
            abi.encode(actor, outcomeIndex, sharesDelta, refundDelta, yesPriceE6, noPriceE6, nonce)
        );

        vm.prank(forwarder);
        IReceiver(address(market)).onReport("", report);
    }
}
