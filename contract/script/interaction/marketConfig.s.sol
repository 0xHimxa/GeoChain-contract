// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Script,console} from "forge-std/Script.sol";
import {MarketFactory} from "../../src/marketFactory/MarketFactory.sol";
import {PredictionMarketBridge} from "../../src/Bridge/PredictionMarketBridge.sol";


contract SetCCIPconfig is Script {
address owner = 0xA85926f9598AA43A2D8f24246B5e7886C4A5FeEc;
address router = 0xD3b06cEbF099CE7DA4AcCf578aaebFDBd6e88a93;
address link =0xE4aB69C077896252FAFBD49EFD26B5D171A32410;

function run() external{


vm.startBroadcast(owner);
MarketFactory(0x02b0E40A0D3E6A0fb27aBBb5FA4f39B40e131bd3).setCcipConfig(router, link, false);

vm.stopBroadcast();

}


}


contract SetRemoteChainSelector is Script {
address owner = 0xA85926f9598AA43A2D8f24246B5e7886C4A5FeEc;
address  marketFactory = 0xa11dE127E008aC5489D28C4130792981DB047654;
address bridge = 0x1Ee45f7A1bF406AC5cE3A1577090230E5E41f32E;

address arbMarketFactory =  0x50045D38580b7f0c326E371c45f9ca22a0768fa7;
address arbBridge = 0x87441a6257b1d29d746a37cab028C94f33425e66;

uint64 chainSelector = 10344971235874465080;
uint64 arbChainSelector = 3478487238524512106;
//base: selector, 10344971235874465080
function run() external{


vm.startBroadcast(owner);

MarketFactory(marketFactory).setTrustedRemote(arbChainSelector,arbMarketFactory);
PredictionMarketBridge(bridge).setTrustedRemote(arbChainSelector,arbBridge);
vm.stopBroadcast();

}




}