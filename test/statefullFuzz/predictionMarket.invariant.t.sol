// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {PredictionMarket} from "src/PredictionMarket.sol";
import {OutcomeToken} from "src/OutcomeToken.sol";
import {PredictionMarketHandler} from "test/statefullFuzz/PredictionMarketHandler.t.sol";

contract MockMarketFactoryInvariant {
    function removeResolvedMarket(address) external {}
}

contract PredictionMarketInvariantTest is StdInvariant, Test {
    PredictionMarket internal market;
    OutcomeToken internal collateral;
    PredictionMarketHandler internal handler;

    uint256 internal constant INITIAL_LIQUIDITY = 10_000e6;
    address internal constant FORWARDER = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8;

    function setUp() external {
        collateral = new OutcomeToken("USDC", "USDC", address(this));

        market = new PredictionMarket(
            "Will ETH close above 5k?",
            address(collateral),
            block.timestamp + 1 days,
            block.timestamp + 2 days,
            address(new MockMarketFactoryInvariant()),
            FORWARDER
        );

        collateral.mint(address(market), INITIAL_LIQUIDITY);
        market.seedLiquidity(INITIAL_LIQUIDITY);

        handler = new PredictionMarketHandler(market, collateral, address(this));

        // Let the handler mint collateral for actor accounts in fuzz actions.
        collateral.transferOwnership(address(handler));

        // Move initial LP shares to the handler-owned actor set for exact share accounting.
        market.transferShares(address(handler), INITIAL_LIQUIDITY);

        targetContract(address(handler));

        bytes4[] memory selectors = new bytes4[](7);
        selectors[0] = PredictionMarketHandler.mintCompleteSets.selector;
        selectors[1] = PredictionMarketHandler.redeemCompleteSets.selector;
        selectors[2] = PredictionMarketHandler.addLiquidity.selector;
        selectors[3] = PredictionMarketHandler.removeLiquidity.selector;
        selectors[4] = PredictionMarketHandler.swapYesForNo.selector;
        selectors[5] = PredictionMarketHandler.swapNoForYes.selector;
        selectors[6] = PredictionMarketHandler.transferShares.selector;

        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function invariant_reservesMatchPoolBalances() external view {
        assertEq(market.yesReserve(), market.yesToken().balanceOf(address(market)));
        assertEq(market.noReserve(), market.noToken().balanceOf(address(market)));
    }

    function invariant_totalSharesEqualsTrackedLpShares() external view {
        address[] memory actors = handler.getActors();
        uint256 sum;
        for (uint256 i = 0; i < actors.length; i++) {
            sum += market.lpShares(actors[i]);
        }
        assertEq(market.totalShares(), sum);
    }

    function invariant_seededRemainsTrue() external view {
        assertTrue(market.seeded());
    }
}
