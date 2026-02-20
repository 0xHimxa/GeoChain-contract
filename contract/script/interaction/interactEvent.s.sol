// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Script,console} from "forge-std/Script.sol";
import {PredictionMarket} from "src/PredictionMarket.sol";



contract InteractWithEvent is Script {

address evnentAddress = 0x04FFA2af594836FB3f2538d1C4ac2c4e2634a0B8;
address owner = 0xA85926f9598AA43A2D8f24246B5e7886C4A5FeEc;
function run() external{

vm.startBroadcast(owner);

string memory question = PredictionMarket(evnentAddress).s_question();
uint256 closeTime = PredictionMarket(evnentAddress).closeTime();
uint256 resolutionTime = PredictionMarket(evnentAddress).resolutionTime();
uint256 myshare = PredictionMarket(evnentAddress).lpShares(0x7c7fe235fC63509969E329E5D660E073EeFa5d39);
bool readyReslolve = PredictionMarket(evnentAddress).checkResolutionTime();
console.log("ready to resolve",readyReslolve);


vm.stopBroadcast();

bool eventClosed = closeTime < block.timestamp;


console.log("new event question",question);
console.log("event closed",eventClosed);
console.log(closeTime,resolutionTime);
console.log(myshare);





}



}