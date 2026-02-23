// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PredictionMarket} from "src/PredictionMarket.sol";

/// @notice Test helper script to move market price by buying YES or NO exposure.
/// @dev Direction:
///      SIDE=YES => swaps NO->YES (pushes YES price up)
///      SIDE=NO  => swaps YES->NO (pushes NO price up)
contract BuyShareToMovePrice is Script {
    function run() external {
        address trader = 0xA85926f9598AA43A2D8f24246B5e7886C4A5FeEc;
        address marketAddress = 0x72F3B6E9aA3735103d1c1eAFDd87A0078b04eB79;
        uint256 collateralIn = 200_000_000;
        string memory side = "NO";

        PredictionMarket market = PredictionMarket(marketAddress);
        IERC20 collateral = IERC20(address(market.i_collateral()));

        uint256 yesBefore = market.getYesPriceProbability();
        uint256 noBefore = market.getNoPriceProbability();

        vm.startBroadcast(trader);

        collateral.approve(marketAddress, collateralIn);
        uint256 yesBalBefore = IERC20(address(market.yesToken())).balanceOf(trader);
        uint256 noBalBefore = IERC20(address(market.noToken())).balanceOf(trader);
        market.mintCompleteSets(collateralIn);
// 3. ADD THESE LINES: Approve the market to spend your outcome tokens
 IERC20(address(market.yesToken())).approve(address(market), 194e6);

        uint256 mintedYes = IERC20(address(market.yesToken())).balanceOf(trader) - yesBalBefore;
        uint256 mintedNo = IERC20(address(market.noToken())).balanceOf(trader) - noBalBefore;

        bytes32 sideHash = keccak256(bytes(side));
        if (sideHash == keccak256("YES")) {
            // Buy YES exposure by swapping NO for YES, which increases YES probability.
            market.swapNoForYes(mintedNo, 0);
            console2.log("Executed NO->YES swap (buy YES). in=", mintedNo);
        } else if (sideHash == keccak256("NO")) {
            // Buy NO exposure by swapping YES for NO, which increases NO probability.
            market.swapYesForNo(mintedYes, 0);
            console2.log("Executed YES->NO swap (buy NO). in=", mintedYes);
        } else {
            revert("SIDE must be YES or NO");
        }

        vm.stopBroadcast();

        uint256 yesAfter = market.getYesPriceProbability();
        uint256 noAfter = market.getNoPriceProbability();

        console2.log("Market:", marketAddress);
        console2.log("Side:", side);
        console2.log("YES before:", yesBefore);
        console2.log("YES after :", yesAfter);
        console2.log("NO before :", noBefore);
        console2.log("NO after  :", noAfter);
    }
}
