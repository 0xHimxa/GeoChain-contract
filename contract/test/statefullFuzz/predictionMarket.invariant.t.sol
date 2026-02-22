// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {PredictionMarket} from "src/PredictionMarket.sol";
import {MarketDeployer} from "src/MarketDeployer.sol";
import {OutcomeToken} from "src/OutcomeToken.sol";
import {MarketConstants} from "src/libraries/MarketTypes.sol";
import {PredictionMarketHandler} from "test/statefullFuzz/PredictionMarketHandler.t.sol";

contract MockMarketFactoryInvariant {
    function removeResolvedMarket(address) external {}

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

contract PredictionMarketInvariantTest is StdInvariant, Test {
    PredictionMarket internal market;
    PredictionMarket internal implementation;
    MarketDeployer internal marketDeployer;
    OutcomeToken internal collateral;
    PredictionMarketHandler internal handler;
    MockMarketFactoryInvariant internal mockFactory;

    uint256 internal constant INITIAL_LIQUIDITY = 10_000e6;
    address internal constant FORWARDER = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8;

    function setUp() external {
        collateral = new OutcomeToken("USDC", "USDC", address(this));

        mockFactory = new MockMarketFactoryInvariant();
        implementation = new PredictionMarket();
        marketDeployer = new MarketDeployer(address(implementation));

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

        collateral.mint(address(market), INITIAL_LIQUIDITY);
        market.seedLiquidity(INITIAL_LIQUIDITY);

        handler = new PredictionMarketHandler(market, collateral, address(this));

        // Let the handler mint collateral for actor accounts in fuzz actions.
        collateral.transferOwnership(address(handler));

        // Move initial LP shares to the handler-owned actor set for exact share accounting.
        market.transferShares(address(handler), INITIAL_LIQUIDITY);

        targetContract(address(handler));

        bytes4[] memory selectors = new bytes4[](8);
        selectors[0] = PredictionMarketHandler.mintCompleteSets.selector;
        selectors[1] = PredictionMarketHandler.redeemCompleteSets.selector;
        selectors[2] = PredictionMarketHandler.addLiquidity.selector;
        selectors[3] = PredictionMarketHandler.removeLiquidity.selector;
        selectors[4] = PredictionMarketHandler.removeLiquidityAndRedeemCollateral.selector;
        selectors[5] = PredictionMarketHandler.swapYesForNo.selector;
        selectors[6] = PredictionMarketHandler.swapNoForYes.selector;
        selectors[7] = PredictionMarketHandler.transferShares.selector;

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

    function invariant_protocolFeesBackedByCollateral() external view {
        assertLe(market.protocolCollateralFees(), collateral.balanceOf(address(market)));
    }

    function invariant_yesAndNoSuppliesStayEqualInOpenState() external view {
        assertEq(market.yesToken().totalSupply(), market.noToken().totalSupply());
    }

    function invariant_poolReservesCannotExceedOutcomeSupply() external view {
        assertLe(market.yesReserve(), market.yesToken().totalSupply());
        assertLe(market.noReserve(), market.noToken().totalSupply());
    }

    function invariant_actorRiskExposureNeverExceedsCap() external view {
        address[] memory actors = handler.getActors();
        for (uint256 i = 0; i < actors.length; i++) {
            assertLe(market.userRiskExposure(actors[i]), MarketConstants.MAX_RISK_EXPOSURE);
        }
    }
}
