// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {MarketFactory} from "src/MarketFactory.sol";
import {PredictionMarket} from "src/PredictionMarket.sol";
import {PredictionMarketBase} from "src/predictionMarket/PredictionMarketBase.sol";

/// @notice Runs factory arbitrage only when market price deviation is Unsafe.
contract BuyIfPriceDiff is Script {
    uint256 internal constant DEFAULT_MAX_SPEND_COLLATERAL = 200_000_000; // 200 USDC (6 decimals)
    uint256 internal constant DEFAULT_MIN_IMPROVEMENT_BPS = 10; // 0.10%

    function run() external {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address factoryAddress = vm.envAddress("MARKET_FACTORY");
        uint256 marketId = vm.envUint("MARKET_ID");
        uint256 maxSpendCollateral = vm.envOr("ARB_MAX_SPEND_COLLATERAL", DEFAULT_MAX_SPEND_COLLATERAL);
        uint256 minDeviationImprovementBps = vm.envOr("ARB_MIN_DEVIATION_IMPROVEMENT_BPS", DEFAULT_MIN_IMPROVEMENT_BPS);

        MarketFactory factory = MarketFactory(factoryAddress);
        address marketAddress = factory.marketById(marketId);
        require(marketAddress != address(0), "invalid marketId");

        (
            PredictionMarketBase.DeviationBand band,
            uint256 deviationBps,
            uint256 effectiveFeeBps,
            uint256 maxOutBps,
            bool allowYesForNo,
            bool allowNoForYes
        ) = PredictionMarket(marketAddress).getDeviationStatus();

        console2.log("Market:", marketAddress);
        console2.log("band:", uint8(band));
        console2.log("deviationBps:", deviationBps);
        console2.log("effectiveFeeBps:", effectiveFeeBps);
        console2.log("maxOutBps:", maxOutBps);
        console2.log("allowYesForNo:", allowYesForNo);
        console2.log("allowNoForYes:", allowNoForYes);

        // DeviationBand.Unsafe = 2
        if (uint8(band) != 2) {
            console2.log("Price difference is not unsafe. Skip buy/arbitrage.");
            return;
        }

        vm.startBroadcast(privateKey);
        factory.arbitrateUnsafeMarket(marketId, maxSpendCollateral, minDeviationImprovementBps);
        vm.stopBroadcast();

        console2.log("Arbitrage tx sent for marketId:", marketId);
    }
}
