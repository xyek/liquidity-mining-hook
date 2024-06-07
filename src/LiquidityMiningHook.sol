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

import {SafeTransferLib, ERC20} from "solmate/utils/SafeTransferLib.sol";

import {Simulate} from "./libraries/SimulateSwap.sol";
import {Stream} from "./libraries/Stream.sol";
import {PositionExtended} from "./libraries/PositionExtended.sol";
import {TickExtended} from "./libraries/TickExtended.sol";

import {console} from "forge-std/console.sol";

function hookPermissions() pure returns (Hooks.Permissions memory) {
    return Hooks.Permissions({
        beforeInitialize: false,
        afterInitialize: false,
        beforeAddLiquidity: true,
        afterAddLiquidity: false,
        beforeRemoveLiquidity: true,
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
    using SafeTransferLib for ERC20;
    using PositionExtended for *;
    using TickExtended for *;
    using Stream for *;

    // TODO add tokens fund state
    struct PoolExtendedState {
        uint48 lastBlockTimestamp;
        uint176 secondsPerLiquidityGlobalX128;
        mapping(int24 tick => TickExtended.Info) ticks;
        mapping(bytes32 positionKey => PositionExtended.Info) positions;
        mapping(bytes32 streamKey => Stream.Info) streams;
    }

    mapping(PoolId => PoolExtendedState) public pools;

    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {}

    modifier ethCallOnly() {
        require(msg.sender == address(0), "LiquidityMiningHook: view-only method");
        _;
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return hookPermissions();
    }

    /**
     *  Hook implementations
     */

    /// @notice Hook called by PoolManager before a swap is executed
    /// @param key The pool key
    /// @param swapParams The swap parameters
    function beforeSwap(address, PoolKey calldata key, IPoolManager.SwapParams calldata swapParams, bytes calldata)
        external
        override
        poolManagerOnly
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

    /// @notice Hook called by PoolManager after a swap is executed
    /// @param key The pool key
    /// @param swapDelta The swap delta
    function afterSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata,
        BalanceDelta swapDelta,
        bytes calldata
    ) external view override poolManagerOnly returns (bytes4, int128) {
        PoolId id = key.toId();
        BalanceDelta simulatedSwapDelta;
        assembly {
            // store the simulated swap delta to check against it in afterSwap
            simulatedSwapDelta := tload(id)
        }
        assert(swapDelta == simulatedSwapDelta);
        return (BaseHook.afterSwap.selector, 0);
    }

    /// @notice Hook called by PoolManager before a liquidity addition
    /// @param key The pool key
    /// @param params The liquidity addition parameters
    /// @param hookData Data passed to for this hook to consume by the user
    function beforeAddLiquidity(
        address owner,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        bytes calldata hookData
    ) external override poolManagerOnly returns (bytes4) {
        _updatePositionState(key.toId(), owner, params.tickLower, params.tickUpper, params.salt, hookData);
        return BaseHook.beforeAddLiquidity.selector;
    }

    /// @notice Hook called by PoolManager before a liquidity removal
    /// @param key The pool key
    /// @param params The liquidity removal parameters
    /// @param hookData Data passed to for this hook to consume by the user
    function beforeRemoveLiquidity(
        address owner,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        bytes calldata hookData
    ) external override poolManagerOnly returns (bytes4) {
        _updatePositionState(key.toId(), owner, params.tickLower, params.tickUpper, params.salt, hookData);
        return BaseHook.beforeRemoveLiquidity.selector;
    }

    /**
     *  External Methods
     */

    /// @notice Allows any EA (Ethereum Account) to linearly stream tokens to all LPs of a specific range of a pool
    /// @param id The pool id
    /// @param tickLower The lower tick of the range
    /// @param tickUpper The upper tick of the range
    /// @param streamToken The token to stream
    /// @param rate The per second stream rate of the token
    /// @param duration The duration of the stream
    function createStream(PoolId id, int24 tickLower, int24 tickUpper, ERC20 streamToken, uint256 rate, uint48 duration)
        external
    {
        require(rate > 0, "LiquidityMiningHook: rate must be non-zero");

        pools[id].streams.create(msg.sender, tickLower, tickUpper, streamToken, rate, duration);

        streamToken.safeTransferFrom(msg.sender, address(this), rate * duration);
    }

    /// @notice Allows the provider to terminate the stream and claim the unstreamed tokens
    /// @param id The pool id
    /// @param tickLower The lower tick of the range
    /// @param tickUpper The upper tick of the range
    /// @param streamToken The token to stream
    /// @param rate The per second stream rate of the token
    function terminateStream(PoolId id, int24 tickLower, int24 tickUpper, ERC20 streamToken, uint256 rate) external {
        uint256 unstreamedTokens = pools[id].streams.terminate(msg.sender, tickLower, tickUpper, streamToken, rate);

        if (unstreamedTokens > 0) {
            streamToken.safeTransfer(msg.sender, unstreamedTokens);
        }
    }

    /// @notice Updates the global and then position state based on the block.timestamp
    /// @param id The pool id
    /// @param owner The owner of the position
    /// @param tickLower The lower tick of the position
    /// @param tickUpper The upper tick of the position
    /// @param salt The salt of the position
    /// @param hookData The data passed to the hook
    /// @return position The position storage pointer
    /// @return streamTokenAmount The calculated stream token amount, also sent to beneficiary address if provided
    function _updatePositionState(
        PoolId id,
        address owner,
        int24 tickLower,
        int24 tickUpper,
        bytes32 salt,
        bytes memory hookData
    ) internal returns (PositionExtended.Info storage position, uint256 streamTokenAmount) {
        PoolExtendedState storage pool = _updateGlobalState(id);

        {
            // PoolState updates
            (, int24 tick,,) = poolManager.getSlot0(id);
            _updateTick(id, tickLower, tick, pool.secondsPerLiquidityGlobalX128);
            _updateTick(id, tickUpper, tick, pool.secondsPerLiquidityGlobalX128);

            // UserPositionState updates
            uint128 liquidityLast = poolManager.getPositionLiquidity(id, owner, tickLower, tickUpper, salt);
            position = _getPositionPtr(id, owner, tickLower, tickUpper, salt);
            uint176 secondsPerLiquidityInsideX128 = getSecondsPerLiquidityInsideX128(id, tickLower, tickUpper);
            position.relativeSecondsCumulativeX32 += computeSecondsX32(
                liquidityLast, secondsPerLiquidityInsideX128, position.secondsPerLiquidityInsideLastX128
            );
            position.secondsPerLiquidityInsideLastX128 = secondsPerLiquidityInsideX128;
        }

        // claim streams if any
        if (hookData.length != 0) {
            (ERC20 streamToken, uint256 rate, address beneficiary) = abi.decode(hookData, (ERC20, uint256, address));
            uint256 secondsInside = getSecondsInside(id, tickLower, tickUpper);
            uint256 totalPositionStream =
                pool.streams.calculate(position, tickLower, tickUpper, streamToken, rate, secondsInside);
            streamTokenAmount = totalPositionStream - position.claimed[streamToken][rate];
            if (streamTokenAmount > 0 && beneficiary != address(0)) {
                position.claimed[streamToken][rate] = totalPositionStream;
                streamToken.safeTransfer(beneficiary, streamTokenAmount);
            }
        }
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

    /// @notice Updates the global state of the pool
    /// @param id The pool id
    /// @return pool The pool extended state
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

    /// @notice Handler for the swap steps, called on every tick cross
    /// @param id The pool id
    /// @param step The swap step computations
    /// @param state The swap state
    function _swapStepHandler(PoolId id, Pool.StepComputations memory step, Pool.SwapState memory state) internal {
        if (state.sqrtPriceX96 == step.sqrtPriceNextX96 && step.initialized) {
            PoolExtendedState storage pool = pools[id];
            pool.ticks.cross(step.tickNext, pool.secondsPerLiquidityGlobalX128);
        }
    }

    /// @notice Updates the tick state
    /// @param id The pool id
    /// @param tickIdx The tick index
    /// @param tickCurrent The current tick
    /// @param secondsPerLiquidityCumulativeX128 The cumulative seconds per liquidity
    function _updateTick(PoolId id, int24 tickIdx, int24 tickCurrent, uint176 secondsPerLiquidityCumulativeX128)
        internal
    {
        (uint128 liquidityGrossBefore,) = poolManager.getTickLiquidity(id, tickIdx);
        if (liquidityGrossBefore == 0) {
            TickExtended.Info storage tick = pools[id].ticks[tickIdx];
            if (tickIdx <= tickCurrent) {
                tick.secondsPerLiquidityOutsideX128 = secondsPerLiquidityCumulativeX128;
                tick.secondsOutside = uint48(block.timestamp);
            }
        }
    }

    /// @notice Computes the number of seconds price spent inside the tick range
    /// @param id The pool id
    /// @param tickLower The lower tick of the range
    /// @param tickUpper The upper tick of the range
    /// @return secondsInside The number of seconds price spent inside the tick range
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

    /// @notice Computes the amount of seconds per liquidity inside the tick range
    /// @param id The pool id
    /// @param tickLower The lower tick of the range
    /// @param tickUpper The upper tick of the range
    /// @return secondsPerLiquidityInsideX128 The amount of seconds per liquidity inside the tick range
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

    /// @notice Getter for the updated position state
    /// @dev This method is for UI convenience to query latest state using eth_call
    /// @param id The pool id
    /// @param owner The owner of the position
    /// @param tickLower The lower tick of the position
    /// @param tickUpper The upper tick of the position
    /// @param salt The salt of the position
    /// @param streamToken The token to stream
    /// @param rate The per second stream rate of the token
    /// @return relativeSecondsCumulativeX32 The relative seconds cumulative of the position
    /// @return secondsPerLiquidityInsideLastX128 The seconds per liquidity inside the tick range during last position modification
    /// @return unclaimedStreams The unclaimed stream tokens
    function getUpdatedPosition(
        PoolId id,
        address owner,
        int24 tickLower,
        int24 tickUpper,
        bytes32 salt,
        ERC20 streamToken,
        uint256 rate
    )
        external
        ethCallOnly
        returns (
            uint80 relativeSecondsCumulativeX32,
            uint176 secondsPerLiquidityInsideLastX128,
            uint256 unclaimedStreams
        )
    {
        PositionExtended.Info storage position;
        (position, unclaimedStreams) =
            _updatePositionState(id, owner, tickLower, tickUpper, salt, abi.encode(streamToken, rate, address(0)));
        return (position.relativeSecondsCumulativeX32, position.secondsPerLiquidityInsideLastX128, unclaimedStreams);
    }

    /// @notice Getter for the position state
    /// @param id The pool id
    /// @param owner The owner of the position
    /// @param tickLower The lower tick of the position
    /// @param tickUpper The upper tick of the position
    /// @param salt The salt of the position
    /// @return position The position storage pointer
    function _getPositionPtr(PoolId id, address owner, int24 tickLower, int24 tickUpper, bytes32 salt)
        internal
        view
        returns (PositionExtended.Info storage position)
    {
        // TODO use Position.key https://github.com/Uniswap/v4-core/pull/733
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
