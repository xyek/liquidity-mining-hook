// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {Stream} from "src/libraries/Stream.sol";

contract StreamTest is Test {
    function testStreamKey(address streamCreator, int24 tickLower, int24 tickUpper, address rewardToken, uint256 rate)
        public
    {
        bytes32 hashed = keccak256(
            abi.encodePacked(uint48(0), tickLower, tickUpper, streamCreator, uint256(uint160(rewardToken)), rate)
        );
        assertEq(Stream.key(streamCreator, tickLower, tickUpper, rewardToken, rate), hashed);
    }
}
