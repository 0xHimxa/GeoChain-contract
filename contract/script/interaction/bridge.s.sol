// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PredictionMarketBridge} from "src/Bridge/PredictionMarketBridge.sol";
import {PredictionMarket} from "src/predictionMarket/PredictionMarket.sol";

contract BridgeToken  is Script {

address bridgeAddr = 0xa604Ae032711761B9c0750Cc7Fb45D947063610a;
    address trader = 0xA85926f9598AA43A2D8f24246B5e7886C4A5FeEc;
    uint256 bridgeAmount = 100e6;
    address marketAddr = 0x4dDDaD21375c21824D98ca14e1d3cB241a403456;
        PredictionMarket market = PredictionMarket(marketAddr);

  
    function run() external {
        vm.startBroadcast(trader);
        PredictionMarketBridge bridge = PredictionMarketBridge(bridgeAddr);
            IERC20(market.yesToken()).approve(bridgeAddr, bridgeAmount);
      
         bridge.lockAndBridgeClaim(2,true,bridgeAmount,10344971235874465080,trader);


vm.stopBroadcast();
    }




}