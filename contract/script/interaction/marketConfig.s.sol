// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Script,console} from "forge-std/Script.sol";
import {MarketFactory} from "src/MarketFactory.sol";



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
//base: selector, 10344971235874465080
function run() external{


vm.startBroadcast(owner);
MarketFactory(0x1C3001d02cF7a8E40cc761c3B46926623D67FC56).setTrustedRemote(10344971235874465080,0xb9Fb07CB48564127675C6Bba08e89FB40D350DA0);
vm.stopBroadcast();

}




}