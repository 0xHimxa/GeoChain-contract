// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {PredictionMarket} from "../../src/predictionMarket/PredictionMarket.sol";
import {OutcomeToken} from "../../src/token/OutcomeToken.sol";
import {MarketConstants} from "../../src/libraries/MarketTypes.sol";
import {FeeLib} from "../../src/libraries/FeeLib.sol";
import {IReceiver} from "../../script/interfaces/IReceiver.sol";

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

    function lmsrBuy(uint256 actorSeed, uint256 outcomeSeed, uint256 sharesRaw, uint256 costRaw) external {
        address actor = _actor(actorSeed);
        uint8 outcomeIndex = uint8(bound(outcomeSeed, 0, 1));
        uint256 sharesDelta = bound(sharesRaw, MarketConstants.MINIMUM_LMSR_TRADE_AMOUNT, 50_000e6);
        uint256 dynamicCap =
            (market.liquidityParam() * MarketConstants.MAX_EXPOSURE_BPS) / MarketConstants.MAX_EXPOSURE_PRECISION;
        uint256 costDelta = bound(costRaw, MarketConstants.MINIMUM_LMSR_TRADE_AMOUNT, dynamicCap);

        if (!market.isRiskExempt(actor)) {
            uint256 fee = FeeLib.calculateFee(
                costDelta,
                MarketConstants.LMSR_TRADE_FEE_BPS,
                MarketConstants.FEE_PRECISION_BPS
            );
            uint256 actualCost = costDelta - fee;
            if (market.userRiskExposure(actor) + actualCost > dynamicCap) {
                return;
            }
        }

        collateral.mint(actor, costDelta);
        _ensureApprovals(actor);

        uint64 nonce = market.tradeNonce();
        bytes memory report = abi.encode(
            "LMSRBuy",
            abi.encode(actor, outcomeIndex, sharesDelta, costDelta, 500_000, 500_000, nonce)
        );

        vm.prank(forwarder);
        IReceiver(address(market)).onReport("", report);
    }

    function lmsrSell(uint256 actorSeed, uint256 outcomeSeed, uint256 sharesRaw, uint256 refundRaw) external {
        address actor = _actor(actorSeed);
        uint8 outcomeIndex = uint8(bound(outcomeSeed, 0, 1));

        uint256 available = outcomeIndex == 0 ? market.userBoughtYesShares(actor) : market.userBoughtNoShares(actor);
        if (available < MarketConstants.MINIMUM_LMSR_TRADE_AMOUNT) return;

        uint256 sharesDelta = bound(sharesRaw, MarketConstants.MINIMUM_LMSR_TRADE_AMOUNT, available);
        uint256 refundDelta = bound(refundRaw, MarketConstants.MINIMUM_LMSR_TRADE_AMOUNT, 200_000e6);

        uint64 nonce = market.tradeNonce();
        bytes memory report = abi.encode(
            "LMSRSell",
            abi.encode(actor, outcomeIndex, sharesDelta, refundDelta, 500_000, 500_000, nonce)
        );

        vm.prank(forwarder);
        IReceiver(address(market)).onReport("", report);
    }
}
