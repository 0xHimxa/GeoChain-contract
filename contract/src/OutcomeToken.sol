// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title OutcomeToken
 * @author 0xHimxa
 * @notice ERC20 token representing a specific outcome (YES or NO) in a prediction market
 * @dev This token can only be minted and burned by the associated prediction market contract
 *      It uses 6 decimals to match USDC standard and maintain 1:1 collateral ratio
 *
 * Token Lifecycle:
 * - Tokens are minted when users buy complete sets or via AMM swaps
 * - Tokens are burned when users redeem complete sets or after market resolution
 * - Only the market contract has mint/burn privileges for security
 */
contract OutcomeToken is ERC20, Ownable {
    // ========================================
    // STATE VARIABLES
    // ========================================

    // ========================================
    // ERRORS
    // ========================================

    /// @notice Thrown when caller is not the authorized market contract
    error OutcomeToken__OnlyMarket();

    /// @notice Thrown when market address is zero in constructor
    error OutcomeToken__InvalidMarketAddress();

    // ========================================
    // CONSTRUCTOR
    // ========================================

    /**
     * @notice Initializes the outcome token
     * @param name_ Token name (e.g., "YES" or "NO")
     * @param symbol_ Token symbol (e.g., "YES" or "NO")
     * @param market_ Address of the prediction market contract
     * @dev The market address is immutable and cannot be changed after deployment
     */
    constructor(string memory name_, string memory symbol_, address market_) ERC20(name_, symbol_) Ownable(market_) {
        if (market_ == address(0)) revert OutcomeToken__InvalidMarketAddress();
    }

    // ========================================
    // PUBLIC FUNCTIONS
    // ========================================

    /**
     * @notice Returns the number of decimals for this token
     * @return Number of decimals (6, matching USDC)
     * @dev Overrides ERC20 default of 18 decimals to match USDC collateral
     */
    function decimals() public pure override returns (uint8) {
        return 6;
    }

    /**
     * @notice Mints new tokens to a specified address
     * @param to Address to receive the minted tokens
     * @param amount Number of tokens to mint
     * @dev Can only be called by the market contract
     *      Used when users mint complete sets or via AMM operations
     */
    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }

    /**
     * @notice Burns tokens from a specified address
     * @param from Address to burn tokens from
     * @param amount Number of tokens to burn
     * @dev Can only be called by the market contract
     *      Used when users redeem complete sets or after market resolution
     */
    function burn(address from, uint256 amount) external onlyOwner {
        _burn(from, amount);
    }
}
