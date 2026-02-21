// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Script,console} from "forge-std/Script.sol";
import {MarketFactory} from "src/MarketFactory.sol";



contract SetCCIPconfig is Script {
address owner = 0xA85926f9598AA43A2D8f24246B5e7886C4A5FeEc;
address router = 0x2a9C5afB0d0e4BAb2BCdaE109EC4b0c4Be15a165;
address link = 0xb1D4538B4571d411F07960EF2838Ce337FE1E80E;

function run() external{


vm.startBroadcast(owner);
MarketFactory(0x015a4e609ED01012ff4B9401a274BE84C89052E6).setCcipConfig(router, link, false);

vm.stopBroadcast();

}


}


contract SetRemoteChainSelector is Script {
address owner = 0xA85926f9598AA43A2D8f24246B5e7886C4A5FeEc;

function run() external{


vm.startBroadcast(owner);
MarketFactory(0x015a4e609ED01012ff4B9401a274BE84C89052E6).setTrustedRemote(16015286601757825753,0x7c7fe235fC63509969E329E5D660E073EeFa5d39 );
vm.stopBroadcast();

}




}