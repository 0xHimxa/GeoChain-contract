// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Script,console} from "forge-std/Script.sol";
import {MarketFactory} from "../../src/marketFactory/MarketFactory.sol";
import {PredictionMarketBridge} from "../../src/Bridge/PredictionMarketBridge.sol";


contract SetCCIPconfig is Script {
address owner = 0xA85926f9598AA43A2D8f24246B5e7886C4A5FeEc;
address router = 0xef21B5c764186B9D3faD4D610564816fA7e461d4 ;
address link =0xE4aB69C077896252FAFBD49EFD26B5D171A32410;

function run() external{


vm.startBroadcast(owner);
MarketFactory(0xf04E1047F34507C7Cf60fDc811116Bc7b0E923f3).setCcipConfig(router, link, false);

vm.stopBroadcast();

}


}


contract SetRemoteChainSelector is Script {
address owner = 0xA85926f9598AA43A2D8f24246B5e7886C4A5FeEc;
address  marketFactory =0xf04E1047F34507C7Cf60fDc811116Bc7b0E923f3;
address bridge = 0x9fBF4e8fc717aa2E39af897D8508ABB9f2DD4157;

address arbMarketFactory =0xA33Ac22e58d34712928d1D1E4CD5201349DCD023;
address arbBridge = 0xcCF1BDb1725E8C12c7d59401155A5c805cb50AdB;

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