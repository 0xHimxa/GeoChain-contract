// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Script,console} from "forge-std/Script.sol";
import {MarketFactory} from "../../src/marketFactory/MarketFactory.sol";
import {PredictionMarketBridge} from "../../src/Bridge/PredictionMarketBridge.sol";


contract SetCCIPconfig is Script {
address owner = 0xA85926f9598AA43A2D8f24246B5e7886C4A5FeEc;
address router = :0x2bE604A2052a6C5e246094151d8962B2E98D8f7c ;
address link =0xE4aB69C077896252FAFBD49EFD26B5D171A32410;

function run() external{


vm.startBroadcast(owner);
MarketFactory(0x73f6A1a5B211E39AcE6F6AF108d7c6e0F77e3B92).setCcipConfig(router, link, false);

vm.stopBroadcast();

}


}


contract SetRemoteChainSelector is Script {
address owner = 0xA85926f9598AA43A2D8f24246B5e7886C4A5FeEc;
address  marketFactory =0x73f6A1a5B211E39AcE6F6AF108d7c6e0F77e3B92;
address bridge = 0x915E3Ee1A09b08038e216B0eCbe736164a246aA3;

address arbMarketFactory =0x1dAf6Ecab082971aCF99E50B517cf297B51B6e5C;
address arbBridge = 0xcb55019591457b2Ea6fbCd779cAF087a6890a06A;

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