// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {PredictionMarket} from "../../src/predictionMarket/PredictionMarket.sol";
import {MarketDeployer} from "../../src/marketFactory/event-deployer/MarketDeployer.sol";
import {OutcomeToken} from "../../src/token/OutcomeToken.sol";
import {MarketConstants} from "../../src/libraries/MarketTypes.sol";
import {LMSRLib} from "../../src/libraries/LMSRLib.sol";
import {PredictionMarketHandler} from "./PredictionMarketHandler.t.sol";

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
    uint256 internal constant LIQUIDITY_PARAM = 10_000e6;
    address internal constant FORWARDER = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8;

    function setUp() external {
        collateral = new OutcomeToken("USDC", "USDC", address(this));

        mockFactory = new MockMarketFactoryInvariant();
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

        collateral.mint(address(market), INITIAL_LIQUIDITY);
        market.initializeMarket(LIQUIDITY_PARAM);

        handler = new PredictionMarketHandler(market, collateral, FORWARDER, address(this));

        // Let the handler mint collateral for actor accounts in fuzz actions.
        collateral.transferOwnership(address(handler));

        targetContract(address(handler));

        bytes4[] memory selectors = new bytes4[](4);
        selectors[0] = PredictionMarketHandler.mintCompleteSets.selector;
        selectors[1] = PredictionMarketHandler.redeemCompleteSets.selector;
        selectors[2] = PredictionMarketHandler.lmsrBuy.selector;
        selectors[3] = PredictionMarketHandler.lmsrSell.selector;

        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function invariant_initializedRemainsTrue() external view {
        assertTrue(market.initialized());
    }

    function invariant_protocolFeesBackedByCollateral() external view {
        assertLe(market.protocolCollateralFees(), collateral.balanceOf(address(market)));
    }

    function invariant_pricesRemainValid() external view {
        assertTrue(LMSRLib.validatePriceSum(market.lastYesPriceE6(), market.lastNoPriceE6()));
    }

    function invariant_outstandingSharesBoundedBySupply() external view {
        assertLe(market.yesSharesOutstanding(), market.yesToken().totalSupply());
        assertLe(market.noSharesOutstanding(), market.noToken().totalSupply());
    }

    function invariant_actorRiskExposureNeverExceedsCap() external view {
        address[] memory actors = handler.getActors();
        uint256 dynamicCap =
            (market.liquidityParam() * MarketConstants.MAX_EXPOSURE_BPS) / MarketConstants.MAX_EXPOSURE_PRECISION;
        for (uint256 i = 0; i < actors.length; i++) {
            if (!market.isRiskExempt(actors[i])) {
                assertLe(market.userRiskExposure(actors[i]), dynamicCap);
            }
        }
    }
}
