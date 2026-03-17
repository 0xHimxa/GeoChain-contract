// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

library Client {
    /// @dev Tag used by CCIP router when decoding V1 extra args payload.
    bytes4 public constant EVM_EXTRA_ARGS_V1_TAG = bytes4(keccak256("CCIP EVMExtraArgsV1"));
    /// @dev Tag used by CCIP router when decoding V2 EVM extra args payload.
    bytes4 public constant EVM_EXTRA_ARGS_V2_TAG = bytes4(keccak256("CCIP EVMExtraArgsV2"));
    /// @dev Tag used by CCIP router when decoding generic V2 extra args payload.
    bytes4 public constant GENERIC_EXTRA_ARGS_V2_TAG = bytes4(keccak256("CCIP GenericExtraArgsV2"));

    /// @dev Token transfer tuple included in CCIP message envelopes.
    struct EVMTokenAmount {
        address token;
        uint256 amount;
    }

    /// @dev Legacy EVM extra args with gas limit only.
    struct EVMExtraArgsV1 {
        uint256 gasLimit;
    }

    /// @dev Current EVM extra args with gas and execution-order preference.
    struct EVMExtraArgsV2 {
        uint256 gasLimit;
        bool allowOutOfOrderExecution;
    }

    /// @dev Generic variant of V2 extra args used by non-EVM flows.
    struct GenericExtraArgsV2 {
        uint256 gasLimit;
        bool allowOutOfOrderExecution;
    }

    /// @dev Outbound message envelope sent through `IRouterClient.ccipSend`.
    struct EVM2AnyMessage {
        bytes receiver;
        bytes data;
        EVMTokenAmount[] tokenAmounts;
        address feeToken;
        bytes extraArgs;
    }

    /// @dev Inbound message envelope delivered to receiver contracts.
    struct Any2EVMMessage {
        bytes32 messageId;
        uint64 sourceChainSelector;
        bytes sender;
        bytes data;
        EVMTokenAmount[] destTokenAmounts;
    }

    /// @dev Encodes V1 extra args with CCIP selector tag prefix.
    function _argsToBytes(EVMExtraArgsV1 memory extraArgs) internal pure returns (bytes memory bts) {
        return abi.encodeWithSelector(EVM_EXTRA_ARGS_V1_TAG, extraArgs);
    }

    /// @dev Encodes V2 EVM extra args with CCIP selector tag prefix.
    function _argsToBytes(EVMExtraArgsV2 memory extraArgs) internal pure returns (bytes memory bts) {
        return abi.encodeWithSelector(EVM_EXTRA_ARGS_V2_TAG, extraArgs);
    }

    /// @dev Encodes generic V2 extra args with CCIP selector tag prefix.
    function _argsToBytes(GenericExtraArgsV2 memory extraArgs) internal pure returns (bytes memory bts) {
        return abi.encodeWithSelector(GENERIC_EXTRA_ARGS_V2_TAG, extraArgs);
    }
}
