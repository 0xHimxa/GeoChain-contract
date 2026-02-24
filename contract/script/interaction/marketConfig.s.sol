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
address  marketFactory = 0x89D7F9aA690cDCB2265351FcA0fD260Ed0c7608E;
address bridge = 0xBA08Ffb458fBb7F6E05E32Eb681564A0F881200F;

address arbMarketFactory = 0xA8735c76fA6E04f705204100FbE56582f0e420eD;
address arbBridge = 0xa604Ae032711761B9c0750Cc7Fb45D947063610a;

uint64 chainSelector = 10344971235874465080;
uint64 arbChainSelector = 3478487238524512106;
//base: selector, 10344971235874465080
function run() external{


vm.startBroadcast(owner);
       PredictionMarketBridge(arbBridge).setSupportedChainSelector(chainSelector, true);

MarketFactory(arbMarketFactory).setTrustedRemote(chainSelector,marketFactory);
PredictionMarketBridge(arbBridge).setTrustedRemote(chainSelector,bridge);
vm.stopBroadcast();

}




}