// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {PredictionMarketRouterVault} from "../../src/router/PredictionMarketRouterVault.sol";
import {PredictionMarket} from "../../src/predictionMarket/PredictionMarket.sol";
import {MarketDeployer} from "../../src/marketFactory/event-deployer/MarketDeployer.sol";
import {OutcomeToken} from "../../src/token/OutcomeToken.sol";
import {MarketConstants} from "../../src/libraries/MarketTypes.sol";
import {PredictionMarketRouterVaultHandler} from "./PredictionMarketRouterVaultHandler.t.sol";

contract MockMarketFactoryRouterInvariant {
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

contract PredictionMarketRouterVaultInvariantTest is StdInvariant, Test {
    PredictionMarketRouterVault internal router;
    PredictionMarket internal market;
    OutcomeToken internal collateral;
    MarketDeployer internal marketDeployer;
    MockMarketFactoryRouterInvariant internal mockFactory;
    PredictionMarketRouterVaultHandler internal handler;

    address internal owner = makeAddr("owner");
    address internal forwarder = makeAddr("forwarder");
    address internal marketFactory = makeAddr("marketFactory");

    uint256 internal constant LIQUIDITY_PARAM = 10_000e6;

    function setUp() external {
        collateral = new OutcomeToken("USDC", "USDC", address(this));

        PredictionMarketRouterVault routerImplementation = new PredictionMarketRouterVault();
        bytes memory initData = abi.encodeCall(
            PredictionMarketRouterVault.initialize, (address(collateral), forwarder, owner, marketFactory)
        );
        ERC1967Proxy routerProxy = new ERC1967Proxy(address(routerImplementation), initData);
        router = PredictionMarketRouterVault(payable(address(routerProxy)));

        mockFactory = new MockMarketFactoryRouterInvariant();
        PredictionMarket implementation = new PredictionMarket();
        marketDeployer = new MarketDeployer(address(implementation), address(mockFactory));

        market = PredictionMarket(
            mockFactory.deployMarket(
                marketDeployer,
                "Will ETH close above 5k?",
                address(collateral),
                block.timestamp + 1 days,
                block.timestamp + 2 days,
                forwarder
            )
        );

        vm.prank(address(mockFactory));
        market.transferOwnership(address(this));

        collateral.mint(address(market), LIQUIDITY_PARAM);
        market.initializeMarket(LIQUIDITY_PARAM);
        market.setRouterVault(address(router));
        market.setRiskExempt(address(router), true);

        vm.prank(owner);
        router.setMarketAllowed(address(market), true);

        handler = new PredictionMarketRouterVaultHandler(router, market, collateral, forwarder, owner);
        collateral.transferOwnership(address(handler));

        targetContract(address(handler));

        bytes4[] memory selectors = new bytes4[](7);
        selectors[0] = PredictionMarketRouterVaultHandler.depositCollateral.selector;
        selectors[1] = PredictionMarketRouterVaultHandler.withdrawCollateral.selector;
        selectors[2] = PredictionMarketRouterVaultHandler.mintCompleteSets.selector;
        selectors[3] = PredictionMarketRouterVaultHandler.redeemCompleteSets.selector;
        selectors[4] = PredictionMarketRouterVaultHandler.lmsrBuy.selector;
        selectors[5] = PredictionMarketRouterVaultHandler.lmsrSell.selector;
        selectors[6] = PredictionMarketRouterVaultHandler.setRiskExempt.selector;

        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function invariant_totalCollateralCreditsBacked() external view {
        assertLe(router.totalCollateralCredits(), collateral.balanceOf(address(router)));
    }

    function invariant_sumCreditsMatchesTotal() external view {
        address[] memory actors = handler.getActors();
        uint256 sum;
        for (uint256 i = 0; i < actors.length; i++) {
            sum += router.collateralCredits(actors[i]);
        }
        assertEq(sum, router.totalCollateralCredits());
    }

    function invariant_tokenCreditsBackedByBalances() external view {
        address[] memory actors = handler.getActors();
        address yes = address(market.yesToken());
        address no = address(market.noToken());
        uint256 sumYes;
        uint256 sumNo;
        for (uint256 i = 0; i < actors.length; i++) {
            sumYes += router.tokenCredits(actors[i], yes);
            sumNo += router.tokenCredits(actors[i], no);
        }
        assertLe(sumYes, OutcomeToken(yes).balanceOf(address(router)));
        assertLe(sumNo, OutcomeToken(no).balanceOf(address(router)));
    }

    function invariant_ammBoughtSharesWithinCredits() external view {
        address[] memory actors = handler.getActors();
        address yes = address(market.yesToken());
        address no = address(market.noToken());
        for (uint256 i = 0; i < actors.length; i++) {
            uint256 yesBought = router.userAMMBoughtShares(actors[i], address(market), 0);
            uint256 noBought = router.userAMMBoughtShares(actors[i], address(market), 1);
            assertLe(yesBought, router.tokenCredits(actors[i], yes));
            assertLe(noBought, router.tokenCredits(actors[i], no));
        }
    }

    function invariant_riskExposureWithinDynamicCap() external view {
        address[] memory actors = handler.getActors();
        uint256 dynamicCap =
            (market.liquidityParam() * MarketConstants.MAX_EXPOSURE_BPS) / MarketConstants.MAX_EXPOSURE_PRECISION;
        for (uint256 i = 0; i < actors.length; i++) {
            if (!router.isRiskExempt(actors[i])) {
                assertLe(router.userRiskExposure(actors[i]), dynamicCap);
            }
        }
    }
}
