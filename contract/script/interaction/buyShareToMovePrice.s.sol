// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Script,console} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PredictionMarket} from "../../src/predictionMarket/PredictionMarket.sol";
import {PredictionMarketBase} from "../../src/predictionMarket/PredictionMarketBase.sol";
import {Resolution} from "../../src/libraries/MarketTypes.sol";
import {PredictionMarketRouterVaultOperations} from "../../src/router/PredictionMarketRouterVaultOperations.sol";
import { PredictionMarketResolution} from "../../src/predictionMarket/PredictionMarketResolution.sol";

/// @notice Test helper script to move market price by buying YES or NO exposure.
/// @dev Direction:
///      SIDE=YES => swaps NO->YES (pushes YES price up)
///      SIDE=NO  => swaps YES->NO (pushes NO price up)
contract BuyShareToMovePrice is Script {
    function run() external {
        // --- Configuration ---
        address trader = 0xA85926f9598AA43A2D8f24246B5e7886C4A5FeEc;
        address marketAddr = 0x9A9A72e6138181B74Fb03541d406966835FdA80f;
        bool isBuyYes = true; // Set to false for NO
    Resolution outcome;

        
        uint256 targetSwapIn = isBuyYes ? 300_000_000 : 300_000_000;
        uint256 collateralIn = vm.envOr("COLLATERAL_IN", (targetSwapIn * 10_000) / 9_700);

        PredictionMarket market = PredictionMarket(marketAddr);


        // --- Pre-Trade Logs ---
        // console2.log("--- BEFORE ---");
        // _logMarketState(market);

         vm.startBroadcast(trader);
    // market.manualResolveMarket( Resolution.Yes , "http://localhost:3000");
   // IERC20(0xe34742D957708d2c91CA8827F758b3843d681b3e).approve(0xEeD3dc1B401ebd6C22E00641Cc6663FfC20f40b5, 800e6);
    PredictionMarketResolution(marketAddr).setDisputeWindow(10 minutes);
  //  PredictionMarketResolution(marketAddr).proposedResolution( );

//PredictionMarketRouterVaultOperations(payable(0xEeD3dc1B401ebd6C22E00641Cc6663FfC20f40b5)).depositCollateral(200e6);
//PredictionMarketRouterVaultOperations(payable(0xEeD3dc1B401ebd6C22E00641Cc6663FfC20f40b5)).depositFor( 0x2De856163308221EB58C1280fFeA2C0eDABb7818,200e6);

        // // 1. Minting
        // IERC20(market.i_collateral()).approve(marketAddr, collateralIn);
        //  market.mintCompleteSets(collateralIn);

        // // // 2. Swapping
        //  if (isBuyYes) {
        //     IERC20(market.noToken()).approve(marketAddr, targetSwapIn);
        //     market.swapNoForYes(targetSwapIn, 0);
        // } else {
        //    IERC20(market.yesToken()).approve(marketAddr, targetSwapIn);
        //     market.swapYesForNo(targetSwapIn, 0);
        //  }
       // console.log("Outcome:", outcome);

        vm.stopBroadcast();

        // --- Post-Trade Logs ---
        console2.log("--- AFTER ---", uint8(outcome));
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
