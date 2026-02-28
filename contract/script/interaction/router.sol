// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Script,console} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import{ PredictionMarketRouterVault} from "src/router/PredictionMarketRouterVault.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";



contract Router is Script {

    address owner = 0xA85926f9598AA43A2D8f24246B5e7886C4A5FeEc;
    address router = 0xAD51b51Ea9347CBaB070311f07d2C7659d8D8c78;
    address collateral = 0x8eaE35b8DC918BE54b2fAA57c9Bb0D4E13B9C9CB;
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