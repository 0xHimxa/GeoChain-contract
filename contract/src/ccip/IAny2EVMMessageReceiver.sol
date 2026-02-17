// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Client} from "./Client.sol";

interface IAny2EVMMessageReceiver {
    function ccipReceive(Client.Any2EVMMessage calldata any2EvmMessage) external;
}
