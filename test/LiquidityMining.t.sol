// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {HookHelpers} from "v4-periphery/libraries/HookHelpers.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {CurrencyLibrary, Currency} from "v4-core/src/types/Currency.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {Deployers} from "v4-core/test/utils/Deployers.sol";
import {LiquidityMiningHook, hookPermissions} from "../src/LiquidityMiningHook.sol";
import {HookMiner} from "./utils/HookMiner.sol";

contract LiquidityMiningTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using HookHelpers for Hooks.Permissions;

    LiquidityMiningHook hook;
    PoolId poolId;

    function setUp() public {
        // creates the pool manager, utility routers, and test tokens
        Deployers.deployFreshManagerAndRouters();
        Deployers.deployMintAndApprove2Currencies();

        // Deploy the hook to an address with the correct flags
        uint160 flags = hookPermissions().flags();
        (address hookAddress, bytes32 salt) =
            HookMiner.find(address(this), flags, type(LiquidityMiningHook).creationCode, abi.encode(address(manager)));
        hook = new LiquidityMiningHook{salt: salt}(IPoolManager(address(manager)));
        require(address(hook) == hookAddress, "CounterTest: hook address mismatch");

        // Create the pool
        key = PoolKey(currency0, currency1, 3000, 60, IHooks(address(hook)));
        poolId = key.toId();
        manager.initialize(key, SQRT_PRICE_1_1, ZERO_BYTES);

        // Provide liquidity to the pool
        modifyLiquidityRouter.modifyLiquidity(key, IPoolManager.ModifyLiquidityParams(-60, 60, 10 ether, 0), ZERO_BYTES);
        modifyLiquidityRouter.modifyLiquidity(
            key, IPoolManager.ModifyLiquidityParams(-120, 120, 10 ether, 0), ZERO_BYTES
        );
        modifyLiquidityRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams(TickMath.minUsableTick(60), TickMath.maxUsableTick(60), 10 ether, 0),
            ZERO_BYTES
        );
    }

    struct Temp {
        uint256 hey;
    }

    struct Temp2 {
        bytes32 hey;
    }

    function cast(Temp memory a) internal returns (Temp2 memory b) {
        assembly {
            a := b
        }
    }

    function logFmp() public {
        uint256 fmp;
        assembly {
            fmp := mload(0x40)
        }
        console.log(fmp);
    }

    function testCounterHooks() public {
        // positions were created in setup()
        // assertEq(hook.beforeAddLiquidityCount(poolId), 3);
        // assertEq(hook.beforeRemoveLiquidityCount(poolId), 0);

        // assertEq(hook.beforeSwapCount(poolId), 0);
        // assertEq(hook.afterSwapCount(poolId), 0);

        // Perform a test swap //
        bool zeroForOne = true;
        int256 amountSpecified = -1e18; // negative number indicates exact input swap!
        BalanceDelta swapDelta = swap(key, zeroForOne, amountSpecified, ZERO_BYTES);
        // ------------------- //

        assertEq(int256(swapDelta.amount0()), amountSpecified);

        // assertEq(hook.beforeSwapCount(poolId), 1);
        // assertEq(hook.afterSwapCount(poolId), 1);
    }

    function testLiquidityHooks() public {
        // positions were created in setup()
        // assertEq(hook.beforeAddLiquidityCount(poolId), 3);
        // assertEq(hook.beforeRemoveLiquidityCount(poolId), 0);

        // remove liquidity
        int256 liquidityDelta = -1e18;
        modifyLiquidityRouter.modifyLiquidity(
            key, IPoolManager.ModifyLiquidityParams(-60, 60, liquidityDelta, 0), ZERO_BYTES
        );

        // assertEq(hook.beforeAddLiquidityCount(poolId), 3);
        // assertEq(hook.beforeRemoveLiquidityCount(poolId), 1);
    }
}
