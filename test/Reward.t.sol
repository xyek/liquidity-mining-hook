// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {Reward} from "src/libraries/Reward.sol";

contract RewardTest is Test {
    function testRewardKey(int24 tickLower, int24 tickUpper, address rewardToken, uint256 rate) public {
        bytes32 hashed = keccak256(abi.encodePacked(uint48(0), tickLower, tickUpper, rewardToken, rate));
        assertEq(Reward.key(tickLower, tickUpper, rewardToken, rate), hashed);
    }
}
