// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

library ByteHasher {
    /// @dev This hashes a bytes value to a field element compatible with the BN254 curve used by World ID.
    /// @param value The bytes value to hash.
    /// @return The hashed value as a uint256.
    function hashToField(bytes memory value) internal pure returns (uint256) {
        return uint256(keccak256(value)) >> 8;
    }
}