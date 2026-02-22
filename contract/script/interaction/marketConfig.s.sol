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
MarketFactory(0x7D47B241083a6627C6c23A4CF0deb3890163bf7b).setTrustedRemote(3478487238524512106,0xEc8C747069FE9066504211d7b57406CcFD89322E);
vm.stopBroadcast();

}




}