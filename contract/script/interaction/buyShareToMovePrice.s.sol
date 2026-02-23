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
    uint256 private constant SWAP_IN_TO_UNSAFE_BUY_NO =  50000000; //1_904_149_496; // YES->NO input target
    uint256 private constant SWAP_IN_TO_UNSAFE_BUY_YES = 5000000; // NO->YES input target

    function _ceilDiv(uint256 a, uint256 b) private pure returns (uint256) {
        return a == 0 ? 0 : (a - 1) / b + 1;
    }

    function run() external {
        
        address trader = 0xA85926f9598AA43A2D8f24246B5e7886C4A5FeEc;
        address marketAddress = 0xc529791a9f33d57b9EaE0835094E6d211E0A2727;
        string memory side = "NO";

        PredictionMarket market = PredictionMarket(marketAddress);
        IERC20 collateral = IERC20(address(market.i_collateral()));
        bytes32 sideHash = keccak256(bytes(side));
        require(sideHash == keccak256("YES") || sideHash == keccak256("NO"), "SIDE must be YES or NO");
        uint256 targetSwapIn = sideHash == keccak256("YES") ? SWAP_IN_TO_UNSAFE_BUY_YES : SWAP_IN_TO_UNSAFE_BUY_NO;
        uint256 collateralIn = vm.envOr("COLLATERAL_IN", _ceilDiv(targetSwapIn * 10_000, 9_700));

        uint256 yesBefore = market.getYesPriceProbability();
        uint256 noBefore = market.getNoPriceProbability();
        (
            PredictionMarket.DeviationBand bandBefore,
            uint256 deviationBpsBefore,
            ,
            ,
            ,
            
        ) = market.getDeviationStatus();

        vm.startBroadcast(trader);

        collateral.approve(marketAddress, collateralIn);
        uint256 yesBalBefore = IERC20(address(market.yesToken())).balanceOf(trader);
        uint256 noBalBefore = IERC20(address(market.noToken())).balanceOf(trader);
        market.mintCompleteSets(collateralIn);
        IERC20(address(market.yesToken())).approve(address(market), type(uint256).max);
        IERC20(address(market.noToken())).approve(address(market), type(uint256).max);

        uint256 mintedYes = IERC20(address(market.yesToken())).balanceOf(trader) - yesBalBefore;
        uint256 mintedNo = IERC20(address(market.noToken())).balanceOf(trader) - noBalBefore;

        if (sideHash == keccak256("YES")) {
            // Buy YES exposure by swapping NO for YES, which increases YES probability.
            require(mintedNo >= targetSwapIn, "insufficient minted NO for target swap");
            market.swapNoForYes(targetSwapIn, 0);
            console2.log("Executed NO->YES swap (buy YES). in=", targetSwapIn);
        } else if (sideHash == keccak256("NO")) {
            // Buy NO exposure by swapping YES for NO, which increases NO probability.
            require(mintedYes >= targetSwapIn, "insufficient minted YES for target swap");
            market.swapYesForNo(targetSwapIn, 0);
            console2.log("Executed YES->NO swap (buy NO). in=", targetSwapIn);
        } else {
            revert("SIDE must be YES or NO");
        }

        vm.stopBroadcast();

        uint256 yesAfter = market.getYesPriceProbability();
        uint256 noAfter = market.getNoPriceProbability();
        (
            PredictionMarket.DeviationBand bandAfter,
            uint256 deviationBpsAfter,
            ,
            ,
            ,
            
        ) = market.getDeviationStatus();

        console2.log("Market:", marketAddress);
        console2.log("Side:", side);
        console2.log("Trader:", trader);
        console2.log("collateralIn:", collateralIn);
        console2.log("targetSwapIn:", targetSwapIn);
        console2.log("YES before:", yesBefore);
        console2.log("YES after :", yesAfter);
        console2.log("NO before :", noBefore);
        console2.log("NO after  :", noAfter);
        console2.log("Band before:", uint8(bandBefore));
        console2.log("Band after :", uint8(bandAfter));
        console2.log("Deviation bps before:", deviationBpsBefore);
        console2.log("Deviation bps after :", deviationBpsAfter);
    }
}
