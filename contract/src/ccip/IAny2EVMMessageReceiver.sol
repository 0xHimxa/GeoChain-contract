// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Client} from "./Client.sol";

interface IAny2EVMMessageReceiver {
    /// @notice CCIP router callback for inbound Any2EVM messages.
    /// @dev Implementers are expected to authenticate router/sender and enforce replay protection.
    function ccipReceive(Client.Any2EVMMessage calldata any2EvmMessage) external;
}
