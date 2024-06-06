// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseHook} from "v4-periphery/BaseHook.sol";

import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {FixedPoint128} from "v4-core/src/libraries/FixedPoint128.sol";
import {LiquidityMath} from "v4-core/src/libraries/LiquidityMath.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {Pool} from "v4-core/src/libraries/Pool.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";

import {Simulate} from "./libraries/SimulateSwap.sol";

import {console} from "forge-std/console.sol";

function hookPermissions() pure returns (Hooks.Permissions memory) {
    return Hooks.Permissions({
        beforeInitialize: false,
        afterInitialize: false,
        beforeAddLiquidity: true,
        afterAddLiquidity: false,
        beforeRemoveLiquidity: false,
        afterRemoveLiquidity: false,
        beforeSwap: true,
        afterSwap: true,
        beforeDonate: false,
        afterDonate: false,
        beforeSwapReturnDelta: false,
        afterSwapReturnDelta: false,
        afterAddLiquidityReturnDelta: false,
        afterRemoveLiquidityReturnDelta: false
    });
}

contract LiquidityMiningHook is BaseHook {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    struct TickExtendedInfo {
        // the timestamp when the tick was last outside the tick range
        uint48 secondsOutside;
        // the cumulative seconds per liquidity outside the tick range
        uint176 secondsPerLiquidityOutsideX128;
    }

    struct PositionExtendedInfo {
        // liquidity points awarded for this position, updated on each position modification
        uint80 relativeSecondsCumulativeX32;
        // snapshot of getSecondsPerLiquidityInsideX128 for which liquidity points are already awarded
        uint176 secondsPerLiquidityInsideLastX128;
    }

    // TODO add tokens fund state
    struct PoolExtendedState {
        uint48 lastBlockTimestamp;
        uint176 secondsPerLiquidityGlobalX128;
        mapping(int24 tick => TickExtendedInfo) ticks;
        mapping(bytes32 => PositionExtendedInfo) positions;
    }

    mapping(PoolId => PoolExtendedState) public pools;

    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {}

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return hookPermissions();
    }

    function beforeSwap(address, PoolKey calldata key, IPoolManager.SwapParams calldata swapParams, bytes calldata)
        external
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId id = key.toId();
        _updateGlobalState(id);

        // simulate the swap and update the tick states
        BalanceDelta simulatedSwapDelta = Simulate.swap(
            poolManager,
            id,
            Pool.SwapParams({
                tickSpacing: key.tickSpacing,
                zeroForOne: swapParams.zeroForOne,
                amountSpecified: swapParams.amountSpecified,
                sqrtPriceLimitX96: swapParams.sqrtPriceLimitX96,
                lpFeeOverride: 0
            }),
            _swapStepHandler
        );
        assembly {
            // store the simulated swap delta to check against it in afterSwap
            tstore(id, simulatedSwapDelta)
        }
        // we returning the simulated swap delta to check it in after swap
        return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    function afterSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata,
        BalanceDelta swapDelta,
        bytes calldata
    ) external view override returns (bytes4, int128) {
        PoolId id = key.toId();
        BalanceDelta simulatedSwapDelta;
        assembly {
            // store the simulated swap delta to check against it in afterSwap
            simulatedSwapDelta := tload(id)
        }
        assert(swapDelta == simulatedSwapDelta);
        return (BaseHook.afterSwap.selector, 0);
    }

    function beforeAddLiquidity(
        address owner,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        bytes calldata
    ) external override returns (bytes4) {
        updatePosition(key.toId(), owner, params.tickLower, params.tickUpper, params.salt);
        return BaseHook.beforeAddLiquidity.selector;
    }

    function beforeRemoveLiquidity(
        address owner,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        bytes calldata
    ) external override returns (bytes4) {
        updatePosition(key.toId(), owner, params.tickLower, params.tickUpper, params.salt);
        return BaseHook.beforeRemoveLiquidity.selector;
    }

    function updatePosition(PoolId id, address owner, int24 tickLower, int24 tickUpper, bytes32 salt) public {
        (, int24 tick,,) = poolManager.getSlot0(id);

        // PoolState updates
        PoolExtendedState storage pool = _updateGlobalState(id);
        _updateTick(id, tickLower, tick, pool.secondsPerLiquidityGlobalX128);
        _updateTick(id, tickUpper, tick, pool.secondsPerLiquidityGlobalX128);

        // UserPositionState updates
        uint128 liquidityLast = poolManager.getPositionLiquidity(id, owner, tickLower, tickUpper, salt);
        PositionExtendedInfo storage position = _getPositionPtr(id, owner, tickLower, tickUpper, salt);
        uint176 secondsPerLiquidityInsideX128 = getSecondsPerLiquidityInsideX128(id, tickLower, tickUpper);
        position.relativeSecondsCumulativeX32 +=
            computeSecondsX32(liquidityLast, secondsPerLiquidityInsideX128, position.secondsPerLiquidityInsideLastX128);
        position.secondsPerLiquidityInsideLastX128 = secondsPerLiquidityInsideX128;
    }

    /// @notice Computes the liquidity points for a user
    ///     Liquidity points are fractional seconds inside based on user vs global liquidity.
    /// @param userLiquidity The liquidity of the user
    /// @param secondsPerLiquidityInsideUpdatedX128 The seconds per liquidity inside the tick range after the update
    /// @param secondsPerLiquidityInsideLastX128 The seconds per liquidity inside the tick range during last position modification
    /// @return secondsX32 The liquidity points to award to the user
    function computeSecondsX32(
        uint128 userLiquidity,
        uint176 secondsPerLiquidityInsideUpdatedX128,
        uint176 secondsPerLiquidityInsideLastX128
    ) internal pure returns (uint80 secondsX32) {
        // TLDR: Fractional seconds inside quantity is scaled up by a factor of 2^32 to preserve precision.
        //
        // Bit Analysis
        // Global liquidity bits -> 128(partial)
        // User liquidity bits -> 128(partial, but it's <= global liquidity)
        // Seconds bits -> 48
        // Seconds per global liquidity X128 bits -> 48 - 128(partial) + 128(full) : max 176 and min 48 bits
        // Liquidity points -> Seconds per global liq times user liq bits:
        //     48 - 128(partial global) + 128(partial user) -> max 48 bits and min 0 bits (if user's liq is too small).
        //     Hence, to preserve precision in the seconds, we want to scale to 80 bits.
        //     factor -> 80(target) - 48(current) = 32

        secondsX32 = uint80(
            FullMath.mulDiv(
                userLiquidity,
                secondsPerLiquidityInsideUpdatedX128 - secondsPerLiquidityInsideLastX128,
                1 << 96 // 128 - 32
            )
        );
    }

    function _updateGlobalState(PoolId id) internal returns (PoolExtendedState storage pool) {
        pool = pools[id];
        uint128 liquidity = poolManager.getLiquidity(id);
        if (liquidity != 0) {
            uint160 secondsPerLiquidityX128 =
                uint160(FullMath.mulDiv(block.timestamp - pool.lastBlockTimestamp, FixedPoint128.Q128, liquidity));
            pool.secondsPerLiquidityGlobalX128 += secondsPerLiquidityX128;
        }
        pool.lastBlockTimestamp = uint48(block.timestamp);
    }

    function _swapStepHandler(PoolId id, Pool.StepComputations memory step, Pool.SwapState memory state) internal {
        if (state.sqrtPriceX96 == step.sqrtPriceNextX96 && step.initialized) {
            PoolExtendedState storage pool = pools[id];
            TickExtendedInfo storage tick = pool.ticks[step.tickNext];
            tick.secondsOutside = uint48(block.timestamp - tick.secondsOutside);
            tick.secondsPerLiquidityOutsideX128 =
                pool.secondsPerLiquidityGlobalX128 - tick.secondsPerLiquidityOutsideX128;
        }
    }

    function _updateTick(PoolId id, int24 tickIdx, int24 tickCurrent, uint176 secondsPerLiquidityCumulativeX128)
        internal
    {
        (uint128 liquidityGrossBefore,) = poolManager.getTickLiquidity(id, tickIdx);
        if (liquidityGrossBefore == 0) {
            TickExtendedInfo storage tick = pools[id].ticks[tickIdx];
            if (tickIdx <= tickCurrent) {
                tick.secondsPerLiquidityOutsideX128 = secondsPerLiquidityCumulativeX128;
                tick.secondsOutside = uint48(block.timestamp);
            }
        }
    }

    function getSecondsInside(PoolId id, int24 tickLower, int24 tickUpper) public view returns (uint48 secondsInside) {
        PoolExtendedState storage pool = pools[id];
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

    function getSecondsPerLiquidityInsideX128(PoolId id, int24 tickLower, int24 tickUpper)
        public
        view
        returns (uint176 secondsPerLiquidityInsideX128)
    {
        PoolExtendedState storage pool = pools[id];
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

    function getPositionExtended(PoolId id, address owner, int24 tickLower, int24 tickUpper, bytes32 salt)
        public
        returns (PositionExtendedInfo memory)
    {
        updatePosition(id, owner, tickLower, tickUpper, salt);
        return _getPositionPtr(id, owner, tickLower, tickUpper, salt);
    }

    function _getPositionPtr(PoolId id, address owner, int24 tickLower, int24 tickUpper, bytes32 salt)
        internal
        view
        returns (PositionExtendedInfo storage position)
    {
        // positionKey = keccak256(abi.encodePacked(owner, tickLower, tickUpper, salt))
        bytes32 positionKey;

        /// @solidity memory-safe-assembly
        assembly {
            mstore(0x26, salt) // [0x26, 0x46)
            mstore(0x06, tickUpper) // [0x23, 0x26)
            mstore(0x03, tickLower) // [0x20, 0x23)
            mstore(0, owner) // [0x0c, 0x20)
            positionKey := keccak256(0x0c, 0x3a) // len is 58 bytes
            mstore(0x26, 0) // rewrite 0x26 to 0
        }

        position = pools[id].positions[positionKey];
    }
}
