// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Script,console} from "forge-std/Script.sol";
import {MarketFactory} from "../../src/marketFactory/MarketFactory.sol";
import {PredictionMarketBridge} from "../../src/Bridge/PredictionMarketBridge.sol";


contract SetCCIPconfig is Script {
address owner = 0xA85926f9598AA43A2D8f24246B5e7886C4A5FeEc;
address router = 0x29D4d09493e507E6b31ffD18f28AC647EE56916a;
address link =0xE4aB69C077896252FAFBD49EFD26B5D171A32410;

function run() external{


vm.startBroadcast(owner);
MarketFactory(0x82dB8e8d6CC0E1fc7C305905140822e0EB57557f).setCcipConfig(router, link, false);

vm.stopBroadcast();

}


}


contract SetRemoteChainSelector is Script {
address owner = 0xA85926f9598AA43A2D8f24246B5e7886C4A5FeEc;
address  marketFactory = 0x82dB8e8d6CC0E1fc7C305905140822e0EB57557f;
address bridge =0xCDFf4223DF721593d8300e80379197AaFa6134d6;

address arbMarketFactory = 0x093a5F31A845FCadAbd55AB3915A6300B4cbCB47;
address arbBridge = 0x0152047B15D7312DE9315B6df818987a7B9bDDe0;

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