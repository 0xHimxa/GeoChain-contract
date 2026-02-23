// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title CcipWrappedClaimToken
 * @notice Wrapped claim token minted on destination chain when claims are locked on source.
 * @dev Owned by PredictionMarketBridge, which is the only minter/burner.
 */
contract CcipWrappedClaimToken is ERC20, Ownable {
    error CcipWrappedClaimToken__ZeroAddress();

    constructor(string memory name_, string memory symbol_, address bridgeOwner) ERC20(name_, symbol_) Ownable(bridgeOwner) {
        if (bridgeOwner == address(0)) revert CcipWrappedClaimToken__ZeroAddress();
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }

    function burn(uint256 amount) external onlyOwner {
        _burn(address(this), amount);
    }
}
