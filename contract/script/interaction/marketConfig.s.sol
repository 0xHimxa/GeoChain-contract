// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Script,console} from "forge-std/Script.sol";
import {MarketFactory} from "src/MarketFactory.sol";



contract SetCCIPconfig is Script {
address owner = 0xA85926f9598AA43A2D8f24246B5e7886C4A5FeEc;
address router = 0x0BF3dE8c5D3e8A2B34D2BEeB17ABfCeBaf363A59;
address link = 0x779877A7B0D9E8603169DdbD7836e478b4624789;
function run() external{


vm.startBroadcast(owner);
MarketFactory(0x7c7fe235fC63509969E329E5D660E073EeFa5d39).setCcipConfig(router, link, true);
vm.stopBroadcast();

}


}


contract SetRemoteChainSelector is Script {
address owner = 0xA85926f9598AA43A2D8f24246B5e7886C4A5FeEc;

function run() external{


vm.startBroadcast(owner);
MarketFactory(0x7c7fe235fC63509969E329E5D660E073EeFa5d39).setTrustedRemote(3478487238524512106,0x015a4e609ED01012ff4B9401a274BE84C89052E6 );
vm.stopBroadcast();

}




}