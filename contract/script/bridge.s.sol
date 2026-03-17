// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PredictionMarketBridge} from "src/Bridge/PredictionMarketBridge.sol";
import {PredictionMarket} from "src/predictionMarket/PredictionMarket.sol";

contract BridgeToken  is Script {

address bridgeAddr = 0xc90E272314115fe79B42741E439a8fD8A58a8aEF;
    address trader = 0xA85926f9598AA43A2D8f24246B5e7886C4A5FeEc;
    uint256 bridgeAmount = 100e6;
    address marketAddr = 0xbb17e48A88c8c5A2e4C335eA9E1bD364Cc71B9b1;
        PredictionMarket market = PredictionMarket(marketAddr);

  
    function run() external {
        vm.startBroadcast(trader);
        PredictionMarketBridge bridge = PredictionMarketBridge(bridgeAddr);
            IERC20(market.yesToken()).approve(bridgeAddr, bridgeAmount);
      
         bridge.lockAndBridgeClaim(3,true,bridgeAmount,10344971235874465080,trader);


vm.stopBroadcast();
    }




}