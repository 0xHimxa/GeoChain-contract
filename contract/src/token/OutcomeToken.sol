// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title OutcomeToken
/// @notice ERC20 claim token used by a market for one side of the outcome (YES or NO).
/// @dev The owning `PredictionMarket` contract is the only account allowed to mint and burn.
contract OutcomeToken is ERC20, ERC20Permit, Ownable {
    error OutcomeToken__InvalidMarketAddress();

    /// @param name_ Token name, usually `YES` or `NO`.
    /// @param symbol_ Token symbol, usually `YES` or `NO`.
    /// @param market_ Prediction market address that becomes token owner.
    constructor(string memory name_, string memory symbol_, address market_)
        ERC20(name_, symbol_)
        ERC20Permit(name_)
        Ownable(market_)
    {
        if (market_ == address(0)) revert OutcomeToken__InvalidMarketAddress();
    }

    /// @notice Uses 6 decimals so claim-token units align with collateral units.
    /// @dev This keeps complete-set mint/redeem math intuitive and avoids cross-decimal conversion.
    function decimals() public pure override returns (uint8) {
        return 6;
    }

    /// @notice Mints outcome tokens to an account.
    /// @param to Receiver of the new tokens.
    /// @param amount Amount to mint.
    /// @dev Called by market contract during flows like complete-set minting or pool bootstrap.
    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }

    /// @notice Burns outcome tokens from an account.
    /// @param from Address tokens are burned from.
    /// @param amount Amount to burn.
    /// @dev Called by market contract during redeem, liquidity settlement, and resolution flows.
    function burn(address from, uint256 amount) external onlyOwner {
        _burn(from, amount);
    }
}
