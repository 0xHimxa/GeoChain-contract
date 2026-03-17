// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title CcipWrappedClaimToken
/// @notice Wrapped claim token minted on destination chains by `PredictionMarketBridge`.
/// @dev This token is non-upgradeable, per-claim-key, and fully bridge-administered:
/// bridge mints when source claims are locked and burns when unwrap/buyback occurs.
contract CcipWrappedClaimToken is ERC20, Ownable {
    error CcipWrappedClaimToken__ZeroAddress();

    /// @param name_ ERC20 name.
    /// @param symbol_ ERC20 symbol.
    /// @param bridgeOwner Bridge contract that owns mint/burn rights.
    constructor(string memory name_, string memory symbol_, address bridgeOwner) ERC20(name_, symbol_) Ownable(bridgeOwner) {
        if (bridgeOwner == address(0)) revert CcipWrappedClaimToken__ZeroAddress();
    }

    /// @notice Uses 6 decimals to match underlying claim token precision.
    function decimals() public pure override returns (uint8) {
        return 6;
    }

    /// @notice Mints wrapped claims to a receiver.
    /// @dev Called only by owning bridge after verified inbound mint message.
    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }

    /// @notice Burns wrapped claims from bridge-owned balance.
    /// @dev Bridge first pulls tokens from user, then calls this to finalize burn.
    function burn(uint256 amount) external onlyOwner {
        _burn(msg.sender, amount);
    }
}
