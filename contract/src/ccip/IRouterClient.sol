// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Client} from "./Client.sol";

interface IRouterClient {
    /// @notice Returns fee quote for a given destination and outbound message envelope.
    function getFee(uint64 destinationChainSelector, Client.EVM2AnyMessage calldata message)
        external
        view
        returns (uint256 fee);

    /// @notice Sends outbound CCIP message and returns router-assigned message id.
    function ccipSend(uint64 destinationChainSelector, Client.EVM2AnyMessage calldata message)
        external
        payable
        returns (bytes32 messageId);
}
