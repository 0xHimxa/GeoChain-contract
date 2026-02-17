// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Client} from "./Client.sol";

interface IRouterClient {
    function getFee(uint64 destinationChainSelector, Client.EVM2AnyMessage calldata message)
        external
        view
        returns (uint256 fee);

    function ccipSend(uint64 destinationChainSelector, Client.EVM2AnyMessage calldata message)
        external
        payable
        returns (bytes32 messageId);
}
