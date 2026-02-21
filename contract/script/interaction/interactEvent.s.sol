// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Script,console} from "forge-std/Script.sol";
import {PredictionMarket} from "src/PredictionMarket.sol";

import {State, Resolution, MarketConstants, MarketEvents, MarketErrors} from "src/libraries/MarketTypes.sol";


contract InteractWithEvent is Script {

address evnentAddress = 0x04FFA2af594836FB3f2538d1C4ac2c4e2634a0B8;
address event2Address =0x7a042d3e3054563389c13bDaae132C1C6cc472F8;
address owner = 0xA85926f9598AA43A2D8f24246B5e7886C4A5FeEc;
function run() external{
string memory proof = "https://github.com/";

vm.startBroadcast(owner);

string memory question = PredictionMarket(event2Address).s_question();
uint256 closeTime = PredictionMarket(event2Address).closeTime();
uint256 resolutionTime = PredictionMarket(event2Address).resolutionTime();
uint256 myshare = PredictionMarket(event2Address).lpShares(0x7c7fe235fC63509969E329E5D660E073EeFa5d39);
bool readyReslolve = PredictionMarket(event2Address).checkResolutionTime();
console.log("ready to resolve",readyReslolve);

PredictionMarket(event2Address).resolve( Resolution.Yes, proof);

vm.stopBroadcast();

bool eventClosed = closeTime < block.timestamp;


console.log("new event question",question);
console.log("event closed",eventClosed);
console.log(closeTime,resolutionTime);
console.log(myshare);





}



}