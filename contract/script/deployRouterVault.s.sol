// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import{ PredictionMarketRouterVault} from "src/router/PredictionMarketRouterVault.sol";



contract DeployRouter is Script {
    address owner = 0xA85926f9598AA43A2D8f24246B5e7886C4A5FeEc;

address collateral = 0xc9a8B668fAB0C2665b8316fc0ba026538c30e8FC;
address forwarder = 0xD41263567DdfeAd91504199b8c6c87371e83ca5d;
address marketFactory = address(0x0);

    function run() external{

  vm.startBroadcast(owner);
  PredictionMarketRouterVault router = new PredictionMarketRouterVault(collateral,forwarder,owner,marketFactory);
  
  vm.stopBroadcast();

    }
}