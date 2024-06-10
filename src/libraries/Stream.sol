// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {SafeTransferLib, ERC20} from "solmate/utils/SafeTransferLib.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";

import {PositionExtended} from "./PositionExtended.sol";

library Stream {
    using Stream for *;
    using SafeTransferLib for ERC20;

    error RateMustBeNonZero();

    error StreamAlreadyExpired(uint256 expiry, uint256 blockTimestamp);

    event StreamCreated(
        PoolId indexed poolId,
        bytes32 indexed streamKey,
        address indexed creator,
        int24 tickLower,
        int24 tickUpper,
        ERC20 rewardToken,
        uint256 rate,
        uint48 duration
    );

    event StreamTerminated(PoolId indexed poolId, bytes32 indexed streamKey, uint256 unstreamedTokens);

    event StreamWithdraw(uint256 indexed positionId, bytes32 indexed streamKey, uint256 streamTokenAmount);

    // TODO
    // bool killable;
    // uint256 claimedSeconds;
    struct Info {
        uint48 start;
        uint48 expiry;
    }

    // TODO take the creator in the key as well
    function key(address creator, int24 tickLower, int24 tickUpper, ERC20 rewardToken, uint256 rate)
        internal
        pure
        returns (bytes32 hashed)
    {
        assembly {
            tickLower := and(tickLower, 0xffffff)
            tickUpper := and(tickUpper, 0xffffff)
            let packed := or(or(shl(184, tickLower), shl(160, tickUpper)), creator)
            let fmp := mload(0x40)
            mstore(fmp, packed)
            mstore(add(fmp, 0x20), rewardToken)
            mstore(add(fmp, 0x40), rate)
            hashed := keccak256(fmp, 0x60)
        }
    }

    function create(
        mapping(bytes32 streamKey => Stream.Info) storage self,
        address creator,
        int24 tickLower,
        int24 tickUpper,
        ERC20 streamToken,
        uint256 rate,
        uint48 duration,
        PoolId poolId
    ) internal {
        if (rate == 0) revert RateMustBeNonZero();
        bytes32 streamKey = Stream.key(creator, tickLower, tickUpper, streamToken, rate);
        Stream.Info storage info = self[streamKey];
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
        streamToken.safeTransferFrom(msg.sender, address(this), rate * duration);
        emit StreamCreated(poolId, streamKey, creator, tickLower, tickUpper, streamToken, rate, duration);
    }

    function calculate(
        mapping(bytes32 streamKey => Stream.Info) storage self,
        PositionExtended.Info storage position,
        bytes32 streamKey,
        uint256 rate,
        uint256 totalSecondsInside
    ) internal view returns (uint256 tokens) {
        uint256 duration;
        {
            uint256 start = self[streamKey].start;
            uint256 expiry = self[streamKey].expiry;
            if (totalSecondsInside == 0) {
                return 0;
            }
            if (expiry < block.timestamp) {
                duration = expiry - start;
            } else {
                duration = block.timestamp - start;
            }
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
        uint256 rate,
        PoolId poolId
    ) internal {
        bytes32 streamKey = Stream.key(caller, tickLower, tickUpper, streamToken, rate);
        Stream.Info storage info = self[streamKey];

        uint256 expiry = info.expiry;
        if (expiry <= block.timestamp) {
            revert StreamAlreadyExpired(expiry, block.timestamp);
        }
        info.expiry = uint48(block.timestamp);

        uint256 unspentDuration = expiry - block.timestamp;
        uint256 unstreamedTokens = unspentDuration * rate;
        if (unstreamedTokens > 0) {
            streamToken.safeTransfer(msg.sender, unstreamedTokens);
        }
        emit StreamTerminated(poolId, streamKey, unstreamedTokens);
    }

    function withdraw(
        mapping(bytes32 streamKey => Stream.Info) storage stream,
        PositionExtended.Info storage position,
        bytes calldata hookData,
        int24 tickLower,
        int24 tickUpper,
        uint256 secondsInside
    ) internal {
        ERC20 streamToken;
        uint256 rate;
        bytes32 streamKey;
        {
            address creator;
            (creator, streamToken, rate,) = abi.decode(hookData, (address, ERC20, uint256, address));
            streamKey = Stream.key(creator, tickLower, tickUpper, streamToken, rate);
        }
        uint256 totalPositionStream = stream.calculate(position, streamKey, rate, secondsInside);
        uint256 streamTokenAmount = totalPositionStream - position.claimed[streamToken][rate];

        if (streamTokenAmount > 0) {
            (,,, address beneficiary) = abi.decode(hookData, (address, ERC20, uint256, address));
            position.claimed[streamToken][rate] = totalPositionStream;
            streamToken.safeTransfer(beneficiary, streamTokenAmount);
        }
        uint256 positionId;
        assembly {
            positionId := position.slot
        }
        emit StreamWithdraw(positionId, streamKey, streamTokenAmount);
    }

    // TODO add kill
}
