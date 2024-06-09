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
import {ERC20} from "solmate/tokens/ERC20.sol";

import {Simulate} from "./libraries/SimulateSwap.sol";
import {Stream} from "./libraries/Stream.sol";
import {PositionExtended} from "./libraries/PositionExtended.sol";
import {PoolExtended} from "./libraries/PoolExtended.sol";
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
    using PoolExtended for *;
    using PositionExtended for *;
    using PoolExtended for *;
    using TickExtended for *;
    using Stream for *;

    mapping(PoolId => PoolExtended.Info) public pools;

    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {}

    modifier ethCallOnly() {
        require(msg.sender == address(0), "LiquidityMiningHook: view-only method");
        _;
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return hookPermissions();
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
    }

    /// @notice Allows the provider to terminate the stream and claim the unstreamed tokens
    /// @param id The pool id
    /// @param tickLower The lower tick of the range
    /// @param tickUpper The upper tick of the range
    /// @param streamToken The token to stream
    /// @param rate The per second stream rate of the token
    function terminateStream(PoolId id, int24 tickLower, int24 tickUpper, ERC20 streamToken, uint256 rate) external {
        pools[id].streams.terminate(msg.sender, tickLower, tickUpper, streamToken, rate);
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
        pools.update(id, poolManager);

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
            _swapStepHook
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
        PoolId id = key.toId();
        (PoolExtended.Info storage pool, PositionExtended.Info storage position) =
            _updateState(id, owner, params.tickLower, params.tickUpper, params.salt);
        if (hookData.length > 0) {
            _processHookData(hookData, pool, id, position, params);
        }
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
        PoolId id = key.toId();
        (PoolExtended.Info storage pool, PositionExtended.Info storage position) =
            _updateState(id, owner, params.tickLower, params.tickUpper, params.salt);
        if (hookData.length > 0) {
            _processHookData(hookData, pool, id, position, params);
        }
        return BaseHook.beforeRemoveLiquidity.selector;
    }

    /**
     *  View Methods
     */

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
        (PoolExtended.Info storage pool, PositionExtended.Info storage position) =
            _updateState(id, owner, tickLower, tickUpper, salt);
        uint176 secondsInside = pool.getSecondsInside(id, tickLower, tickUpper, poolManager);
        uint256 totalPositionStream =
            pool.streams.calculate(position, tickLower, tickUpper, streamToken, rate, secondsInside);
        return (
            position.relativeSecondsCumulativeX32,
            position.secondsPerLiquidityInsideLastX128,
            totalPositionStream - position.claimed[streamToken][rate]
        );
    }

    /// @notice Computes the number of seconds price spent inside the tick range
    /// @param id The pool id
    /// @param tickLower The lower tick of the range
    /// @param tickUpper The upper tick of the range
    /// @return secondsInside The number of seconds price spent inside the tick range
    function getSecondsInside(PoolId id, int24 tickLower, int24 tickUpper) public view returns (uint48 secondsInside) {
        return pools[id].getSecondsInside(id, tickLower, tickUpper, poolManager);
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
        return pools[id].getSecondsPerLiquidityInsideX128(id, tickLower, tickUpper, poolManager);
    }

    /**
     *  Intenral Helpers
     */
    function _updateState(PoolId id, address owner, int24 tickLower, int24 tickUpper, bytes32 salt)
        internal
        returns (PoolExtended.Info storage pool, PositionExtended.Info storage position)
    {
        pool = pools.update(id, poolManager);
        pool.updateTicks(tickLower, tickUpper, id, poolManager);

        uint128 liquidityLast = poolManager.getPositionLiquidity(id, owner, tickLower, tickUpper, salt);
        uint176 secondsPerLiquidityInsideX128 =
            pool.getSecondsPerLiquidityInsideX128(id, tickLower, tickUpper, poolManager);
        position =
            pool.positions.update(owner, tickLower, tickUpper, salt, liquidityLast, secondsPerLiquidityInsideX128);
    }

    function _processHookData(
        bytes calldata hookData,
        PoolExtended.Info storage pool,
        PoolId id,
        PositionExtended.Info storage position,
        IPoolManager.ModifyLiquidityParams calldata params
    ) internal {
        (ERC20 streamToken, uint256 rate, address beneficiary) = abi.decode(hookData, (ERC20, uint256, address));
        uint176 secondsInside = pool.getSecondsInside(id, params.tickLower, params.tickUpper, poolManager);
        pool.streams.withdraw(
            position, params.tickLower, params.tickUpper, streamToken, rate, beneficiary, secondsInside
        );
    }

    /// @notice Handler for the swap steps, called on every tick cross
    /// @param id The pool id
    /// @param step The swap step computations
    /// @param state The swap state
    function _swapStepHook(PoolId id, Pool.StepComputations memory step, Pool.SwapState memory state) internal {
        if (state.sqrtPriceX96 == step.sqrtPriceNextX96 && step.initialized) {
            PoolExtended.Info storage pool = pools[id];
            pool.ticks.cross(step.tickNext, pool.secondsPerLiquidityGlobalX128);
        }
    }
}
