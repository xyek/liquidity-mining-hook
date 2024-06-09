// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {SafeTransferLib, ERC20} from "solmate/utils/SafeTransferLib.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";

import {PositionExtended} from "./PositionExtended.sol";

library Stream {
    using Stream for *;
    using SafeTransferLib for ERC20;

    // TODO
    // bool killable;
    // uint256 claimedSeconds;
    struct Info {
        uint48 start;
        uint48 expiry;
        address creator;
    }

    // TODO take the creator in the key as well
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

    function create(
        mapping(bytes32 streamKey => Stream.Info) storage self,
        address creator,
        int24 tickLower,
        int24 tickUpper,
        ERC20 streamToken,
        uint256 rate,
        uint48 duration
    ) internal {
        bytes32 streamKey = Stream.key(tickLower, tickUpper, address(streamToken), rate);
        Stream.Info memory info = self[streamKey];
        if (info.creator != address(0)) {
            require(info.creator == creator, "LiquidityMiningHook: stream already provided");
        } else {
            info.creator = creator;
        }
        if (info.start == 0) {
            // fresh start
            info.start = uint48(block.timestamp);
            info.expiry = uint48(block.timestamp + duration);
        } else if (info.expiry < block.timestamp) {
            // old stream expired
            info.start = uint48(block.timestamp);
            info.expiry = uint48(block.timestamp + duration);
        } else {
            // stream extend
            info.expiry = uint48(info.expiry + duration);
        }
        self[streamKey] = info;

        streamToken.safeTransferFrom(msg.sender, address(this), rate * duration);
    }

    function calculate(
        mapping(bytes32 streamKey => Stream.Info) storage self,
        PositionExtended.Info storage position,
        int24 tickLower,
        int24 tickUpper,
        ERC20 streamToken,
        uint256 rate,
        uint256 totalSecondsInside
    ) internal view returns (uint256 tokens) {
        bytes32 streamKey = Stream.key(tickLower, tickUpper, address(streamToken), rate);
        uint256 start = self[streamKey].start;
        uint256 expiry = self[streamKey].expiry;
        if (totalSecondsInside == 0) {
            return 0;
        }
        uint256 duration;
        if (expiry < block.timestamp) {
            duration = expiry - start;
        } else {
            duration = block.timestamp - start;
        }
        uint256 totalTokens = duration * rate;
        return FullMath.mulDiv(position.relativeSecondsCumulativeX32, totalTokens, totalSecondsInside << 32);
    }

    function terminate(
        mapping(bytes32 streamKey => Stream.Info) storage self,
        address caller,
        int24 tickLower,
        int24 tickUpper,
        ERC20 streamToken,
        uint256 rate
    ) internal {
        bytes32 streamKey = Stream.key(tickLower, tickUpper, address(streamToken), rate);
        Stream.Info storage info = self[streamKey];
        require(info.creator == caller, "LiquidityMiningHook: not creator");

        uint256 expiry = info.expiry;
        require(expiry > block.timestamp, "LiquidityMiningHook: stream already expired");
        info.expiry = uint48(block.timestamp);

        uint256 unspentDuration = expiry - block.timestamp;
        uint256 unstreamedTokens = unspentDuration * rate;
        if (unstreamedTokens > 0) {
            streamToken.safeTransfer(msg.sender, unstreamedTokens);
        }
    }

    function withdraw(
        mapping(bytes32 streamKey => Stream.Info) storage self,
        PositionExtended.Info storage position,
        int24 tickLower,
        int24 tickUpper,
        ERC20 streamToken,
        uint256 rate,
        address beneficiary,
        uint256 secondsInside
    ) internal {
        uint256 totalPositionStream = self.calculate(position, tickLower, tickUpper, streamToken, rate, secondsInside);
        uint256 streamTokenAmount = totalPositionStream - position.claimed[streamToken][rate];
        if (streamTokenAmount > 0 && beneficiary != address(0)) {
            position.claimed[streamToken][rate] = totalPositionStream;
            streamToken.safeTransfer(beneficiary, streamTokenAmount);
        }
    }

    // TODO add kill
}
