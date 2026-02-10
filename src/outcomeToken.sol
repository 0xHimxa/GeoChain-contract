// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract OutcomeToken is ERC20 {
    address public immutable market;

    modifier onlyMarket() {
        require(msg.sender == market, "Only market");
        _;
    }

    constructor(string memory name_, string memory symbol_, address market_) ERC20(name_, symbol_) {
        require(market_ != address(0), "Bad market");
        market = market_;
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external onlyMarket {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external onlyMarket {
        _burn(from, amount);
    }
}
