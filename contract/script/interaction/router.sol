// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Script,console} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import{ PredictionMarketRouterVault} from "src/router/PredictionMarketRouterVault.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";



contract Router is Script {

    address owner = 0xA85926f9598AA43A2D8f24246B5e7886C4A5FeEc;
    address router =  0x3E6206fa635C74288C807ee3ba90C603a82B94A8
;
    address collateral =  0x28dF0b4CD6d0627134b708CCAfcF230bC272a663
;
    uint256 amount = 500e6;
    address market = 0x2eFa683a02Ebb28615b44912cf14D7e73c2c57e6;
    uint256 useAmount = 40e6;

    function run() external {
    vm.startBroadcast(owner);
 IERC20(collateral).approve(router, amount);
    PredictionMarketRouterVault route =  PredictionMarketRouterVault(payable(router));
  uint256 userBalanceB4 = route.collateralCredits(owner);
  
  route.redeemCompleteSets(market, 30e6);
  uint256 userBalanceAfter = route.collateralCredits(owner);
 



    vm.stopBroadcast();
console.log("user Balance before:",  userBalanceB4);
console.log("user Balance after:" , userBalanceAfter);
    



    }

}