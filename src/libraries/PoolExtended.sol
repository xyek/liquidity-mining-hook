// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {FixedPoint128} from "v4-core/src/libraries/FixedPoint128.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";

import {TickExtended} from "./TickExtended.sol";
import {PositionExtended} from "./PositionExtended.sol";
import {Stream} from "./Stream.sol";

library PoolExtended {
    using StateLibrary for IPoolManager;
    using TickExtended for *;

    struct Info {
        uint48 lastBlockTimestamp;
        uint176 secondsPerLiquidityGlobalX128;
        mapping(int24 tick => TickExtended.Info) ticks;
        mapping(bytes32 positionKey => PositionExtended.Info) positions;
        mapping(bytes32 streamKey => Stream.Info) streams;
    }

    /// @notice Updates the global state of the pool
    /// @param id The pool id
    /// @param poolManager The pool manager
    /// @return pool The pool extended state
    function update(mapping(PoolId => PoolExtended.Info) storage self, PoolId id, IPoolManager poolManager)
        internal
        returns (PoolExtended.Info storage pool)
    {
        pool = self[id];
        uint128 liquidity = poolManager.getLiquidity(id);
        if (liquidity != 0) {
            uint160 secondsPerLiquidityX128 =
                uint160(FullMath.mulDiv(block.timestamp - pool.lastBlockTimestamp, FixedPoint128.Q128, liquidity));
            pool.secondsPerLiquidityGlobalX128 += secondsPerLiquidityX128;
        }
        pool.lastBlockTimestamp = uint48(block.timestamp);
    }

    /// @notice Updates the tick state
    /// @param self The pool ptr
    /// @param tickLower The lower tick
    /// @param tickUpper The upper tick
    /// @param poolId The pool id
    /// @param poolManager The pool manager
    function updateTicks(
        PoolExtended.Info storage self,
        int24 tickLower,
        int24 tickUpper,
        PoolId poolId,
        IPoolManager poolManager
    ) internal {
        (, int24 tickCurrent,,) = poolManager.getSlot0(poolId);
        self.ticks.update(tickLower, tickCurrent, self.secondsPerLiquidityGlobalX128, poolId, poolManager);
        self.ticks.update(tickUpper, tickCurrent, self.secondsPerLiquidityGlobalX128, poolId, poolManager);
    }

    /// @notice Computes the number of seconds price spent inside the tick range
    /// @param id The pool id
    /// @param tickLower The lower tick of the range
    /// @param tickUpper The upper tick of the range
    /// @return secondsInside The number of seconds price spent inside the tick range
    function getSecondsInside(
        PoolExtended.Info storage pool,
        PoolId id,
        int24 tickLower,
        int24 tickUpper,
        IPoolManager poolManager
    ) internal view returns (uint48 secondsInside) {
        uint48 lowerSecondsOutside = pool.ticks[tickLower].secondsOutside;
        uint48 upperSecondsOutside = pool.ticks[tickUpper].secondsOutside;

        (, int24 tickCurrent,,) = poolManager.getSlot0(id);

        unchecked {
            if (tickCurrent < tickLower) {
                secondsInside = lowerSecondsOutside - upperSecondsOutside;
            } else if (tickCurrent >= tickUpper) {
                secondsInside = upperSecondsOutside - lowerSecondsOutside;
            } else {
                secondsInside = uint48(block.timestamp - lowerSecondsOutside - upperSecondsOutside);
            }
        }
    }

    /// @notice Computes the amount of seconds per liquidity inside the tick range
    /// @param pool The pool storage ref
    /// @param id The pool id
    /// @param tickLower The lower tick of the range
    /// @param tickUpper The upper tick of the range
    /// @return secondsPerLiquidityInsideX128 The amount of seconds per liquidity inside the tick range
    function getSecondsPerLiquidityInsideX128(
        PoolExtended.Info storage pool,
        PoolId id,
        int24 tickLower,
        int24 tickUpper,
        IPoolManager poolManager
    ) internal view returns (uint176 secondsPerLiquidityInsideX128) {
        uint176 lowerSecondsPerLiquidityOutsideX128 = pool.ticks[tickLower].secondsPerLiquidityOutsideX128;
        uint176 upperSecondsPerLiquidityOutsideX128 = pool.ticks[tickUpper].secondsPerLiquidityOutsideX128;

        (, int24 tickCurrent,,) = poolManager.getSlot0(id);

        unchecked {
            if (tickCurrent < tickLower) {
                secondsPerLiquidityInsideX128 =
                    lowerSecondsPerLiquidityOutsideX128 - upperSecondsPerLiquidityOutsideX128;
            } else if (tickCurrent >= tickUpper) {
                secondsPerLiquidityInsideX128 =
                    upperSecondsPerLiquidityOutsideX128 - lowerSecondsPerLiquidityOutsideX128;
            } else {
                uint256 lastBlockTimestamp = pool.lastBlockTimestamp;
                uint176 secondsPerLiquidityGlobalX128 = pool.secondsPerLiquidityGlobalX128;

                // adjusting the global seconds per liquidity to the current block
                if (block.timestamp > lastBlockTimestamp) {
                    uint256 liquidity = poolManager.getLiquidity(id);
                    uint160 secondsPerLiquidityX128 = uint160(
                        FullMath.mulDiv(block.timestamp - pool.lastBlockTimestamp, FixedPoint128.Q128, liquidity)
                    );
                    secondsPerLiquidityGlobalX128 += secondsPerLiquidityX128;
                }

                secondsPerLiquidityInsideX128 = secondsPerLiquidityGlobalX128 - lowerSecondsPerLiquidityOutsideX128
                    - upperSecondsPerLiquidityOutsideX128;
            }
        }
    }
}
