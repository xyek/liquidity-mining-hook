// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {FixedPoint128} from "v4-core/src/libraries/FixedPoint128.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {LiquidityMath} from "v4-core/src/libraries/LiquidityMath.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {Pool} from "v4-core/src/libraries/Pool.sol";
import {ProtocolFeeLibrary} from "v4-core/src/libraries/ProtocolFeeLibrary.sol";
import {SafeCast} from "v4-core/src/libraries//SafeCast.sol";
import {SwapMath} from "v4-core/src/libraries/SwapMath.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {CustomRevert} from "v4-core/src/libraries/CustomRevert.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {BalanceDelta, BalanceDeltaLibrary, toBalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Slot0} from "v4-core/src/types/Slot0.sol";

import {TickBitmapModified} from "./TickBitmapModified.sol";

library Simulate {
    using CustomRevert for bytes4;
    using LPFeeLibrary for uint24;
    using ProtocolFeeLibrary for uint24;
    using SafeCast for *;
    using StateLibrary for IPoolManager;

    /// @notice Executes a swap against the state, and returns the amount deltas of the pool
    /// @dev PoolManager checks that the pool is initialized before calling
    function swap(
        IPoolManager poolManager,
        PoolId poolId,
        Pool.SwapParams memory params,
        function(PoolId, Pool.StepComputations memory,Pool.SwapState memory) swapStepHandler
    ) internal returns (BalanceDelta result) {
        uint24 swapFee;
        Pool.SwapState memory state;
        StateLibrary.PoolStateView memory globalState = poolManager.getPoolState(poolId);
        bool zeroForOne = params.zeroForOne;
        bool exactInput = params.amountSpecified < 0;
        uint256 protocolFee;
        {
            Slot0 slot0Start = globalState.slot0;

            uint128 liquidityStart = globalState.liquidity;
            protocolFee =
                zeroForOne ? slot0Start.protocolFee().getZeroForOneFee() : slot0Start.protocolFee().getOneForZeroFee();

            state.amountSpecifiedRemaining = params.amountSpecified;
            state.amountCalculated = 0;
            state.sqrtPriceX96 = slot0Start.sqrtPriceX96();
            state.tick = slot0Start.tick();
            {
                state.feeGrowthGlobalX128 =
                    zeroForOne ? globalState.feeGrowthGlobal0X128 : globalState.feeGrowthGlobal1X128;
            }
            state.liquidity = liquidityStart;

            // if the beforeSwap hook returned a valid fee override, use that as the LP fee, otherwise load from storage
            {
                uint24 lpFee = params.lpFeeOverride.isOverride()
                    ? params.lpFeeOverride.removeOverrideFlagAndValidate()
                    : slot0Start.lpFee();

                swapFee = protocolFee == 0 ? lpFee : uint24(protocolFee).calculateSwapFee(lpFee);
            }

            if (!exactInput && (swapFee == LPFeeLibrary.MAX_LP_FEE)) {
                Pool.InvalidFeeForExactOut.selector.revertWith();
            }

            if (params.amountSpecified == 0) return BalanceDeltaLibrary.ZERO_DELTA;

            if (zeroForOne) {
                if (params.sqrtPriceLimitX96 >= slot0Start.sqrtPriceX96()) {
                    Pool.PriceLimitAlreadyExceeded.selector.revertWith(
                        slot0Start.sqrtPriceX96(), params.sqrtPriceLimitX96
                    );
                }
                if (params.sqrtPriceLimitX96 <= TickMath.MIN_SQRT_PRICE) {
                    Pool.PriceLimitOutOfBounds.selector.revertWith(params.sqrtPriceLimitX96);
                }
            } else {
                if (params.sqrtPriceLimitX96 <= slot0Start.sqrtPriceX96()) {
                    Pool.PriceLimitAlreadyExceeded.selector.revertWith(
                        slot0Start.sqrtPriceX96(), params.sqrtPriceLimitX96
                    );
                }
                if (params.sqrtPriceLimitX96 >= TickMath.MAX_SQRT_PRICE) {
                    Pool.PriceLimitOutOfBounds.selector.revertWith(params.sqrtPriceLimitX96);
                }
            }
        }
        Pool.StepComputations memory step;

        // continue swapping as long as we haven't used the entire input/output and haven't reached the price limit
        while (!(state.amountSpecifiedRemaining == 0 || state.sqrtPriceX96 == params.sqrtPriceLimitX96)) {
            step.sqrtPriceStartX96 = state.sqrtPriceX96;

            (step.tickNext, step.initialized) = TickBitmapModified.nextInitializedTickWithinOneWord(
                poolManager, poolId, state.tick, params.tickSpacing, zeroForOne
            );

            // ensure that we do not overshoot the min/max tick, as the tick bitmap is not aware of these bounds
            if (step.tickNext <= TickMath.MIN_TICK) {
                step.tickNext = TickMath.MIN_TICK;
            }
            if (step.tickNext >= TickMath.MAX_TICK) {
                step.tickNext = TickMath.MAX_TICK;
            }

            // get the price for the next tick
            step.sqrtPriceNextX96 = TickMath.getSqrtPriceAtTick(step.tickNext);

            // compute values to swap to the target tick, price limit, or point where input/output amount is exhausted
            (state.sqrtPriceX96, step.amountIn, step.amountOut, step.feeAmount) = SwapMath.computeSwapStep(
                state.sqrtPriceX96,
                SwapMath.getSqrtPriceTarget(zeroForOne, step.sqrtPriceNextX96, params.sqrtPriceLimitX96),
                state.liquidity,
                state.amountSpecifiedRemaining,
                swapFee
            );

            if (!exactInput) {
                unchecked {
                    state.amountSpecifiedRemaining -= step.amountOut.toInt256();
                }
                state.amountCalculated = state.amountCalculated - (step.amountIn + step.feeAmount).toInt256();
            } else {
                // safe because we test that amountSpecified > amountIn + feeAmount in SwapMath
                unchecked {
                    state.amountSpecifiedRemaining += (step.amountIn + step.feeAmount).toInt256();
                }
                state.amountCalculated = state.amountCalculated + step.amountOut.toInt256();
            }

            // if the protocol fee is on, calculate how much is owed, decrement feeAmount, and increment protocolFee
            if (protocolFee > 0) {
                unchecked {
                    // step.amountIn does not include the swap fee, as it's already been taken from it,
                    // so add it back to get the total amountIn and use that to calculate the amount of fees owed to the protocol
                    uint256 delta = (step.amountIn + step.feeAmount) * protocolFee / ProtocolFeeLibrary.PIPS_DENOMINATOR;
                    // subtract it from the total fee and add it to the protocol fee
                    step.feeAmount -= delta;
                }
            }

            swapStepHandler(poolId, step, state);

            // shift tick if we reached the next price
            if (state.sqrtPriceX96 == step.sqrtPriceNextX96) {
                // if the tick is initialized, run the tick transition
                if (step.initialized) {
                    (, int128 liquidityNet) = poolManager.getTickLiquidity(poolId, step.tickNext);
                    // if we're moving leftward, we interpret liquidityNet as the opposite sign
                    // safe because liquidityNet cannot be type(int128).min
                    unchecked {
                        if (zeroForOne) liquidityNet = -liquidityNet;
                    }

                    state.liquidity = LiquidityMath.addDelta(state.liquidity, liquidityNet);
                }

                // Equivalent to `state.tick = zeroForOne ? step.tickNext - 1 : step.tickNext;`
                unchecked {
                    // cannot cast a bool to an int24 in Solidity
                    int24 _zeroForOne;
                    assembly {
                        _zeroForOne := zeroForOne
                    }
                    state.tick = step.tickNext - _zeroForOne;
                }
            } else if (state.sqrtPriceX96 != step.sqrtPriceStartX96) {
                // recompute unless we're on a lower tick boundary (i.e. already transitioned ticks), and haven't moved
                state.tick = TickMath.getTickAtSqrtPrice(state.sqrtPriceX96);
            }
        }

        unchecked {
            if (zeroForOne != exactInput) {
                result = toBalanceDelta(
                    state.amountCalculated.toInt128(),
                    (params.amountSpecified - state.amountSpecifiedRemaining).toInt128()
                );
            } else {
                result = toBalanceDelta(
                    (params.amountSpecified - state.amountSpecifiedRemaining).toInt128(),
                    state.amountCalculated.toInt128()
                );
            }
        }
    }
}
