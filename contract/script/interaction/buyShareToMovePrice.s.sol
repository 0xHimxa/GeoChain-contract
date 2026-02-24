// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PredictionMarket} from "../../src/predictionMarket/PredictionMarket.sol";
import {PredictionMarketBase} from "../../src/predictionMarket/PredictionMarketBase.sol";

/// @notice Test helper script to move market price by buying YES or NO exposure.
/// @dev Direction:
///      SIDE=YES => swaps NO->YES (pushes YES price up)
///      SIDE=NO  => swaps YES->NO (pushes NO price up)
contract BuyShareToMovePrice is Script {
    function run() external {
        // --- Configuration ---
        address trader = 0xA85926f9598AA43A2D8f24246B5e7886C4A5FeEc;
        address marketAddr = 0xc529791a9f33d57b9EaE0835094E6d211E0A2727;
        bool isBuyYes = true; // Set to false for NO
        
        uint256 targetSwapIn = isBuyYes ? 5_000_000 : 50_000_000;
        uint256 collateralIn = vm.envOr("COLLATERAL_IN", (targetSwapIn * 10_000) / 9_700);

        PredictionMarket market = PredictionMarket(marketAddr);

        // --- Pre-Trade Logs ---
        console2.log("--- BEFORE ---");
        _logMarketState(market);

        vm.startBroadcast(trader);

        // 1. Minting
        IERC20(market.i_collateral()).approve(marketAddr, collateralIn);
        market.mintCompleteSets(collateralIn);

        // 2. Swapping
        if (isBuyYes) {
            IERC20(market.noToken()).approve(marketAddr, targetSwapIn);
            market.swapNoForYes(targetSwapIn, 0);
        } else {
            IERC20(market.yesToken()).approve(marketAddr, targetSwapIn);
            market.swapYesForNo(targetSwapIn, 0);
        }

        vm.stopBroadcast();

        // --- Post-Trade Logs ---
        console2.log("--- AFTER ---");
        _logMarketState(market);
    }

    /// @dev Helper to print state without clogging the run() function stack
    function _logMarketState(PredictionMarket market) internal view {
        (PredictionMarketBase.DeviationBand band, uint256 dev, , , , ) = market.getDeviationStatus();
        console2.log("YES Price:", market.getYesPriceProbability());
        console2.log("NO Price :", market.getNoPriceProbability());
        console2.log("Band/Dev :", uint8(band), dev);
    }
}
