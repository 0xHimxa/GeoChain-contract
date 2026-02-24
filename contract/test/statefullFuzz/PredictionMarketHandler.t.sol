// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {PredictionMarket} from "../../src/predictionMarket/PredictionMarket.sol";
import {OutcomeToken} from "../../src/token/OutcomeToken.sol";
import {MarketConstants} from "../../src/libraries/MarketTypes.sol";

contract PredictionMarketHandler is Test {
    PredictionMarket public market;
    OutcomeToken public collateral;

    address[] internal actors;

    constructor(PredictionMarket _market, OutcomeToken _collateral, address ownerActor) {
        market = _market;
        collateral = _collateral;

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

    function addLiquidity(uint256 actorSeed, uint256 yesRaw, uint256 noRaw) external {
        address actor = _actor(actorSeed);
        uint256 yesBal = market.yesToken().balanceOf(actor);
        uint256 noBal = market.noToken().balanceOf(actor);

        if (yesBal < MarketConstants.MINIMUM_ADD_LIQUIDITY_SHARE || noBal < MarketConstants.MINIMUM_ADD_LIQUIDITY_SHARE) {
            return;
        }

        uint256 yesAmount = bound(yesRaw, MarketConstants.MINIMUM_ADD_LIQUIDITY_SHARE, yesBal);
        uint256 noAmount = bound(noRaw, MarketConstants.MINIMUM_ADD_LIQUIDITY_SHARE, noBal);
        _ensureApprovals(actor);

        vm.startPrank(actor);
        (bool ok,) =
            address(market).call(abi.encodeWithSelector(PredictionMarket.addLiquidity.selector, yesAmount, noAmount, 0));
        ok;
        vm.stopPrank();
    }

    function removeLiquidity(uint256 actorSeed, uint256 sharesRaw) external {
        address actor = _actor(actorSeed);
        uint256 sharesBal = market.lpShares(actor);
        if (sharesBal == 0) return;

        uint256 shares = bound(sharesRaw, 1, sharesBal);

        vm.startPrank(actor);
        (bool ok,) = address(market).call(abi.encodeWithSelector(PredictionMarket.removeLiquidity.selector, shares, 0, 0));
        ok;
        vm.stopPrank();
    }

    function removeLiquidityAndRedeemCollateral(uint256 actorSeed, uint256 sharesRaw) external {
        address actor = _actor(actorSeed);
        uint256 sharesBal = market.lpShares(actor);
        if (sharesBal == 0) return;

        uint256 shares = bound(sharesRaw, 1, sharesBal);

        vm.startPrank(actor);
        (bool ok,) =
            address(market).call(abi.encodeWithSelector(PredictionMarket.removeLiquidityAndRedeemCollateral.selector, shares, 0));
        ok;
        vm.stopPrank();
    }

    function swapYesForNo(uint256 actorSeed, uint256 amountRaw) external {
        address actor = _actor(actorSeed);
        uint256 yesBal = market.yesToken().balanceOf(actor);
        if (yesBal < MarketConstants.MINIMUM_SWAP_AMOUNT) return;

        uint256 yesIn = bound(amountRaw, MarketConstants.MINIMUM_SWAP_AMOUNT, yesBal);
        _ensureApprovals(actor);

        vm.startPrank(actor);
        (bool ok,) = address(market).call(abi.encodeWithSelector(PredictionMarket.swapYesForNo.selector, yesIn, 0));
        ok;
        vm.stopPrank();
    }

    function swapNoForYes(uint256 actorSeed, uint256 amountRaw) external {
        address actor = _actor(actorSeed);
        uint256 noBal = market.noToken().balanceOf(actor);
        if (noBal < MarketConstants.MINIMUM_SWAP_AMOUNT) return;

        uint256 noIn = bound(amountRaw, MarketConstants.MINIMUM_SWAP_AMOUNT, noBal);
        _ensureApprovals(actor);

        vm.startPrank(actor);
        (bool ok,) = address(market).call(abi.encodeWithSelector(PredictionMarket.swapNoForYes.selector, noIn, 0));
        ok;
        vm.stopPrank();
    }

    function transferShares(uint256 fromSeed, uint256 toSeed, uint256 sharesRaw) external {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        if (from == to) return;

        uint256 sharesBal = market.lpShares(from);
        if (sharesBal == 0) return;

        uint256 shares = bound(sharesRaw, 1, sharesBal);

        vm.startPrank(from);
        (bool ok,) = address(market).call(abi.encodeWithSelector(PredictionMarket.transferShares.selector, to, shares));
        ok;
        vm.stopPrank();
    }
}
