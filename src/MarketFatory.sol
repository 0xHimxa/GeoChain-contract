// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {PredictionMarket} from "./PredictionMarket.sol";

contract MarketFactory is Ownable {
    using SafeERC20 for IERC20;
    IERC20 public immutable collateral; // USDC

    uint256 public marketCount;
    mapping(uint256 => address) public markets;

    event MarketCreated(
        uint256 indexed marketId,
        address market,
        string question,
        uint256 closeTime,
        uint256 resolutionTime,
        uint256 initialLiquidity
    );

    constructor(address _collateral) Ownable(msg.sender) {
        collateral = IERC20(_collateral);
    }

    function createMarket(
        string calldata question,
        uint256 closeTime,
        uint256 resolutionTime,
        uint256 feeBps,
        uint256 initialLiquidity
    ) external onlyOwner returns (address market) {
        require(initialLiquidity > 0, "Zero liquidity");

        PredictionMarket m = new PredictionMarket(
            question, address(collateral), closeTime, resolutionTime, feeBps, address(this)
        );

        // seed liquidity in the new market, then hand ownership to the creator
        collateral.safeTransferFrom(msg.sender, address(m), initialLiquidity);
        m.seedLiquidity(initialLiquidity);
        m.transferShares(msg.sender, initialLiquidity);
        m.transferOwnership(msg.sender);

        marketCount++;
        markets[marketCount] = address(m);

        emit MarketCreated(marketCount, address(m), question, closeTime, resolutionTime, initialLiquidity);

        return address(m);
    }
}
