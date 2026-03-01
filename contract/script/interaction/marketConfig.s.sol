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
address  marketFactory = 0x54DDeC2F7420b3AF1BB53157f3c533F9Ad598651;
address bridge = 0xf898E8b44513F261a13EfF8387eC7b58baB4846e;

address arbMarketFactory = 0x145A8D0eD56fd02A8b29b2E81C09F5d66e1918Ec;
address arbBridge = 0x0043866570462b0495eC23d780D873aF1afA1711;

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