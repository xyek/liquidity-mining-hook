// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

library Reward {
    function key(int24 tickLower, int24 tickUpper, address rewardToken, uint256 rate)
        internal
        pure
        returns (bytes32 hashed)
    {
        assembly {
            tickLower := and(tickLower, 0xffffff)
            tickUpper := and(tickUpper, 0xffffff)
            let packed := or(or(shl(184, tickLower), shl(160, tickUpper)), rewardToken)
            mstore(0, packed)
            mstore(32, rate)
            hashed := keccak256(0, 64)
        }
    }
}
