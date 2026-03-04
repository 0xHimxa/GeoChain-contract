// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Script,console} from "forge-std/Script.sol";
import {MarketFactory} from "../../src/marketFactory/MarketFactory.sol";
import {PredictionMarketBridge} from "../../src/Bridge/PredictionMarketBridge.sol";


contract SetCCIPconfig is Script {
address owner = 0xA85926f9598AA43A2D8f24246B5e7886C4A5FeEc;
address router = 0x7D60126CEE3D751913EAA299Ab3FFef480A39ee4;
address link =0xE4aB69C077896252FAFBD49EFD26B5D171A32410;

function run() external{


vm.startBroadcast(owner);
MarketFactory(0xf2992507E9589307Ea5f02225C5439Ee451d13EC).setCcipConfig(router, link, false);

vm.stopBroadcast();

}


}


contract SetRemoteChainSelector is Script {
address owner = 0xA85926f9598AA43A2D8f24246B5e7886C4A5FeEc;
address  marketFactory = 0xf2992507E9589307Ea5f02225C5439Ee451d13EC;
address bridge =0x4B74B7092a8CAb9194e29b7DB04D87e12E5bA852;

address arbMarketFactory =0xbC44067d3bbDC4cb4231fD91b2Fe3Bf7027E7c77;
address arbBridge = 0x51Fd315523900e94Ff99b41B22DE93D0DeBdFa5C;

uint64 chainSelector = 10344971235874465080;
uint64 arbChainSelector = 3478487238524512106;
//base: selector, 10344971235874465080
function run() external{


vm.startBroadcast(owner);

MarketFactory(arbMarketFactory).setTrustedRemote(chainSelector,marketFactory);
PredictionMarketBridge(arbBridge).setTrustedRemote(chainSelector,bridge);
vm.stopBroadcast();

}




}