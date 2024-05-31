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
        uint48 secondsOutside;
        uint160 secondsPerLiquidityOutsideX128;
    }

    // TODO add position extension state
    // TODO add tokens fund state
    struct PoolExtendedState {
        uint48 lastBlockTimestamp;
        uint160 secondsPerLiquidityGlobalX128;
        mapping(int24 tick => TickExtendedInfo) ticks;
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
        address,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        bytes calldata
    ) external override returns (bytes4) {
        PoolId id = key.toId();
        PoolExtendedState storage pool = _updateGlobalState(id);

        (, int24 tick,,) = poolManager.getSlot0(id);
        _updateTick(id, params.tickLower, tick, pool.secondsPerLiquidityGlobalX128);
        _updateTick(id, params.tickUpper, tick, pool.secondsPerLiquidityGlobalX128);

        return BaseHook.beforeAddLiquidity.selector;
    }

    function _updateGlobalState(PoolId id) internal returns (PoolExtendedState storage pool) {
        pool = pools[id];
        uint128 liquidity = poolManager.getLiquidity(id);
        if (liquidity != 0) {
            uint160 secondsPerLiquidityX128 =
                uint160(FullMath.mulDiv(block.timestamp - pool.lastBlockTimestamp, FixedPoint128.Q128, liquidity));
            pool.secondsPerLiquidityGlobalX128 += secondsPerLiquidityX128;
            console.log("incrementd", secondsPerLiquidityX128);
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

    function _updateTick(PoolId id, int24 tickIdx, int24 tickCurrent, uint160 secondsPerLiquidityCumulativeX128)
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
        returns (uint160 secondsPerLiquidityInsideX128)
    {
        PoolExtendedState storage pool = pools[id];
        uint160 lowerSecondsPerLiquidityOutsideX128 = pool.ticks[tickLower].secondsPerLiquidityOutsideX128;
        uint160 upperSecondsPerLiquidityOutsideX128 = pool.ticks[tickUpper].secondsPerLiquidityOutsideX128;

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
                uint160 secondsPerLiquidityGlobalX128 = pool.secondsPerLiquidityGlobalX128;

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
