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
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {FixedPoint128} from "v4-core/src/libraries/FixedPoint128.sol";
import {ERC20} from "solmate/utils/SafeTransferLib.sol";

contract LiquidityMiningTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using HookHelpers for Hooks.Permissions;
    using StateLibrary for IPoolManager;

    uint256 constant Q32 = 1 << 32;

    LiquidityMiningHook hook;
    PoolId poolId;
    RewardToken rewardToken;

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

        rewardToken = new RewardToken();
    }

    function testSecondsInside() public {
        //  Liquidity Distribution
        //
        //                                     price
        //  -3000  ----- -1500  --- -1200 -----  0  -----  1200  -----  3000
        //                             ======================
        //                                                   ==============
        //    ===============
        //                     < gap >
        //
        addLiquidity({tickLower: -1200, tickUpper: 1200});
        addLiquidity({tickLower: 1200, tickUpper: 3000});
        addLiquidity({tickLower: -3000, tickUpper: -1500});

        assertEq(hook.getSecondsInside(poolId, -1200, 1200), 0, "check11");
        assertEq(hook.getSecondsInside(poolId, 1200, 3000), 0, "check12");
        assertEq(hook.getSecondsInside(poolId, -3000, -1500), 0, "check13");
        assertEq(hook.getSecondsInside(poolId, -1500, -1200), 0, "check14");
        assertEq(hook.getSecondsInside(poolId, -1500, 3000), 0, "check15");
        assertEq(hook.getSecondsInside(poolId, -3000, 3000), 0, "check16");

        advanceTime(100 seconds);

        assertEq(hook.getSecondsInside(poolId, -1200, 1200), 100 seconds, "check21");
        assertEq(hook.getSecondsInside(poolId, 1200, 3000), 0, "check22");
        assertEq(hook.getSecondsInside(poolId, -3000, -1500), 0, "check23");
        assertEq(hook.getSecondsInside(poolId, -1500, -1200), 0, "check24");
        assertEq(hook.getSecondsInside(poolId, -1500, 3000), 100 seconds, "check25");
        assertEq(hook.getSecondsInside(poolId, -3000, 3000), 100 seconds, "check26");

        swap(key, false, 0.09 ether, ZERO_BYTES);
        assertEq(currentTick(), 1886); // <===== current tick is updated by swap

        assertEq(hook.getSecondsInside(poolId, -1200, 1200), 100 seconds, "check31");
        assertEq(hook.getSecondsInside(poolId, 1200, 3000), 0, "check32");
        assertEq(hook.getSecondsInside(poolId, -3000, -1500), 0, "check33");
        assertEq(hook.getSecondsInside(poolId, -1500, -1200), 0, "check34");
        assertEq(hook.getSecondsInside(poolId, -1500, 3000), 100 seconds, "check35");
        assertEq(hook.getSecondsInside(poolId, -3000, 3000), 100 seconds, "check36");

        advanceTime(150 seconds);

        assertEq(hook.getSecondsInside(poolId, -1200, 1200), 100 seconds, "check41");
        assertEq(hook.getSecondsInside(poolId, 1200, 3000), 150 seconds, "check42");
        assertEq(hook.getSecondsInside(poolId, -3000, -1500), 0, "check43");
        assertEq(hook.getSecondsInside(poolId, -1500, -1200), 0, "check44");
        assertEq(hook.getSecondsInside(poolId, -1500, 3000), 250 seconds, "check45");
        assertEq(hook.getSecondsInside(poolId, -3000, 3000), 250 seconds, "check46");

        swap(key, true, 0.17 ether, ZERO_BYTES);
        assertEq(currentTick(), -1780); // <===== current tick is updated by swap

        assertEq(hook.getSecondsInside(poolId, -1200, 1200), 100 seconds, "check51");
        assertEq(hook.getSecondsInside(poolId, 1200, 3000), 150 seconds, "check52");
        assertEq(hook.getSecondsInside(poolId, -3000, -1500), 0, "check53");
        assertEq(hook.getSecondsInside(poolId, -1500, -1200), 0, "check54");
        assertEq(hook.getSecondsInside(poolId, -1500, 3000), 250 seconds, "check55");
        assertEq(hook.getSecondsInside(poolId, -3000, 3000), 250 seconds, "check56");

        advanceTime(25 seconds);

        assertEq(hook.getSecondsInside(poolId, -1200, 1200), 100 seconds, "check61");
        assertEq(hook.getSecondsInside(poolId, 1200, 3000), 150 seconds, "check62");
        assertEq(hook.getSecondsInside(poolId, -3000, -1500), 25 seconds, "check63");
        assertEq(hook.getSecondsInside(poolId, -1500, -1200), 0, "check64");
        assertEq(hook.getSecondsInside(poolId, -1500, 3000), 250 seconds, "check65");
        assertEq(hook.getSecondsInside(poolId, -3000, 3000), 275 seconds, "check66");
    }

    function testSecondsPerLiquidityInside() public {
        //  Liquidity Distribution
        //
        //                                     price
        //  -3000  ----- -1500  --- -1200 -----  0  -----  1200  -----  3000
        //                             ======================
        //                                                   ==============
        //    ===============
        //                     < gap >
        //
        addLiquidity({tickLower: -1200, tickUpper: 1200});
        addLiquidity({tickLower: 1200, tickUpper: 3000});
        addLiquidity({tickLower: -3000, tickUpper: -1500});

        assertEq(hook.getSecondsPerLiquidityInsideX128(poolId, -1200, 1200), 0, "check11");
        assertEq(hook.getSecondsPerLiquidityInsideX128(poolId, 1200, 3000), 0, "check12");
        assertEq(hook.getSecondsPerLiquidityInsideX128(poolId, -3000, -1500), 0, "check13");
        assertEq(hook.getSecondsPerLiquidityInsideX128(poolId, -1500, -1200), 0, "check14");
        assertEq(hook.getSecondsPerLiquidityInsideX128(poolId, -1500, 3000), 0, "check15");
        assertEq(hook.getSecondsPerLiquidityInsideX128(poolId, -3000, 3000), 0, "check16");

        advanceTime(100 seconds);

        assertEq(hook.getSecondsPerLiquidityInsideX128(poolId, -1200, 1200), perLiquidity(100 seconds), "check21");
        assertEq(hook.getSecondsPerLiquidityInsideX128(poolId, 1200, 3000), 0, "check22");
        assertEq(hook.getSecondsPerLiquidityInsideX128(poolId, -3000, -1500), 0, "check23");
        assertEq(hook.getSecondsPerLiquidityInsideX128(poolId, -1500, -1200), 0, "check24");
        assertEq(hook.getSecondsPerLiquidityInsideX128(poolId, -1500, 3000), perLiquidity(100 seconds), "check25");
        assertEq(hook.getSecondsPerLiquidityInsideX128(poolId, -3000, 3000), perLiquidity(100 seconds), "check26");

        swap(key, false, 0.09 ether, ZERO_BYTES);
        assertEq(currentTick(), 1886); // <===== current tick is updated by swap

        assertEq(hook.getSecondsPerLiquidityInsideX128(poolId, -1200, 1200), perLiquidity(100 seconds), "check31");
        assertEq(hook.getSecondsPerLiquidityInsideX128(poolId, 1200, 3000), 0, "check32");
        assertEq(hook.getSecondsPerLiquidityInsideX128(poolId, -3000, -1500), 0, "check33");
        assertEq(hook.getSecondsPerLiquidityInsideX128(poolId, -1500, -1200), 0, "check34");
        assertEq(hook.getSecondsPerLiquidityInsideX128(poolId, -1500, 3000), perLiquidity(100 seconds), "check35");
        assertEq(hook.getSecondsPerLiquidityInsideX128(poolId, -3000, 3000), perLiquidity(100 seconds), "check36");

        advanceTime(150 seconds);

        assertEq(hook.getSecondsPerLiquidityInsideX128(poolId, -1200, 1200), perLiquidity(100 seconds), "check41");
        assertEq(hook.getSecondsPerLiquidityInsideX128(poolId, 1200, 3000), perLiquidity(150 seconds), "check42");
        assertEq(hook.getSecondsPerLiquidityInsideX128(poolId, -3000, -1500), 0, "check43");
        assertEq(hook.getSecondsPerLiquidityInsideX128(poolId, -1500, -1200), 0, "check44");
        assertEq(hook.getSecondsPerLiquidityInsideX128(poolId, -1500, 3000), perLiquidity(250 seconds), "check45");
        assertEq(hook.getSecondsPerLiquidityInsideX128(poolId, -3000, 3000), perLiquidity(250 seconds), "check46");

        swap(key, true, 0.17 ether, ZERO_BYTES);
        assertEq(currentTick(), -1780); // <===== current tick is updated by swap

        assertEq(hook.getSecondsPerLiquidityInsideX128(poolId, -1200, 1200), perLiquidity(100 seconds), "check51");
        assertEq(hook.getSecondsPerLiquidityInsideX128(poolId, 1200, 3000), perLiquidity(150 seconds), "check52");
        assertEq(hook.getSecondsPerLiquidityInsideX128(poolId, -3000, -1500), 0, "check53");
        assertEq(hook.getSecondsPerLiquidityInsideX128(poolId, -1500, -1200), 0, "check54");
        assertEq(hook.getSecondsPerLiquidityInsideX128(poolId, -1500, 3000), perLiquidity(250 seconds), "check55");
        assertEq(hook.getSecondsPerLiquidityInsideX128(poolId, -3000, 3000), perLiquidity(250 seconds), "check56");

        advanceTime(25 seconds);

        assertEq(hook.getSecondsPerLiquidityInsideX128(poolId, -1200, 1200), perLiquidity(100 seconds), "check61");
        assertEq(hook.getSecondsPerLiquidityInsideX128(poolId, 1200, 3000), perLiquidity(150 seconds), "check62");
        assertEq(hook.getSecondsPerLiquidityInsideX128(poolId, -3000, -1500), perLiquidity(25 seconds), "check63");
        assertEq(hook.getSecondsPerLiquidityInsideX128(poolId, -1500, -1200), 0, "check64");
        assertEq(hook.getSecondsPerLiquidityInsideX128(poolId, -1500, 3000), perLiquidity(250 seconds), "check65");
        assertEq(perLiquidity(275 seconds), 93577650903258077452428);
        assertEq(perLiquidity(25) + perLiquidity(100) + perLiquidity(150), 93577650903258077452427);
        assertEq(
            hook.getSecondsPerLiquidityInsideX128(poolId, -3000, 3000),
            perLiquidity(25) + perLiquidity(100) + perLiquidity(150),
            "check66"
        );
    }

    function testSingleLpLiquidityPoints() external {
        PositionRef memory p1 = addLiquidity(-1200, 1200);

        assertEq(getLiquidityPoints(p1), 0, "check1");
        advanceTime(100 seconds);
        assertEq(getLiquidityPoints(p1), (100 seconds << 32) - 1, "check2");
    }

    function testTwoLpLiquidityPoints_1() external {
        PositionRef memory p1 = addLiquidity(1e18, -1200, 1200, keccak256("1"));
        PositionRef memory p2 = addLiquidity(3e18, -1200, 1200, keccak256("2"));

        assertEq(getLiquidityPoints(p1), 0, "check11");
        assertEq(getLiquidityPoints(p2), 0, "check12");

        advanceTime(100 seconds);

        assertEq(getLiquidityPoints(p1), (25 seconds << 32) - 1, "check21");
        assertEq(getLiquidityPoints(p2), (75 seconds << 32) - 1, "check22");
    }

    function testTwoLpLiquidityPoints_2() external {
        PositionRef memory p1 = addLiquidity(1e18, -1200, 1200, keccak256("1"));
        PositionRef memory p2 = addLiquidity(3e18, -1200, 1200, keccak256("2"));

        assertEq(getLiquidityPoints(p1), 0, "check11");
        assertEq(getLiquidityPoints(p2), 0, "check12");

        advanceTime(100 seconds);

        assertEq(getLiquidityPoints(p1), (25 seconds << 32) - 1, "check21");
        assertEq(getLiquidityPoints(p2), (75 seconds << 32) - 1, "check22");

        PositionRef memory p3 = addLiquidity(4e18, -1200, 1200, keccak256("3"));

        assertEq(getLiquidityPoints(p1), (25 seconds << 32) - 1, "check31");
        assertEq(getLiquidityPoints(p2), (75 seconds << 32) - 1, "check32");
        assertEq(getLiquidityPoints(p3), 0, "check33");

        advanceTime(200 seconds);

        assertEq(getLiquidityPoints(p1), (25 seconds << 32) - 1 + (25 seconds << 32) - 1, "check41");
        assertEq(getLiquidityPoints(p2), (75 seconds << 32) - 1 + (75 seconds << 32) - 1, "check42");
        assertEq(getLiquidityPoints(p3), (100 seconds << 32) - 1, "check43");
    }

    function testThreeLpLiquidityPoints_3() external {
        //  Liquidity Distribution
        //                                  price
        //  -2400  ------ -1200 --- -600 ---  0  ------  1200
        //
        //                   ==============================
        //     ========================
        //     ========================
        //
        PositionRef memory p1 = addLiquidity(1e18, -1200, 1200, keccak256("1"));
        PositionRef memory p2 = addLiquidity(2e18, -2400, -600, keccak256("2"));
        PositionRef memory p3 = addLiquidity(1e18, -2400, -600, keccak256("3"));

        assertEq(getLiquidityPoints(p1), 0, "check11");
        assertEq(getLiquidityPoints(p2), 0, "check12");
        assertEq(getLiquidityPoints(p3), 0, "check13");

        advanceTime(100 seconds);

        // only p1 should get points, p2 p3 should not get any points because price wasnt there
        assertEq(getLiquidityPoints(p1), (100 seconds << 32) - 1, "check21");
        assertEq(getLiquidityPoints(p2), 0, "check22");
        assertEq(getLiquidityPoints(p3), 0, "check23");

        swap(key, true, 0.05 ether, ZERO_BYTES);
        assertEq(currentTick(), -706); // <===== current tick is updated by swap

        assertEq(getLiquidityPoints(p1), (100 seconds << 32) - 1, "check31");
        assertEq(getLiquidityPoints(p2), 0, "check32");
        assertEq(getLiquidityPoints(p3), 0, "check33");

        advanceTime(100 seconds);

        // once tick moves between -1200 and -600, both positions should get points
        // since p2 has higher L value, it should get more points
        assertEq(getLiquidityPoints(p1), (100 seconds << 32) - 1 + (25 seconds << 32) - 1, "check41");
        assertEq(getLiquidityPoints(p2), (50 seconds << 32) - 1, "check42");
        assertEq(getLiquidityPoints(p3), (25 seconds << 32) - 1, "check43");

        swap(key, true, 0.1 ether, ZERO_BYTES);
        assertEq(currentTick(), -1241); // <===== current tick is updated by swap

        assertEq(getLiquidityPoints(p1), (100 seconds << 32) - 1 + (25 seconds << 32) - 1, "check51");
        assertEq(getLiquidityPoints(p2), (50 seconds << 32) - 1, "check52");
        assertEq(getLiquidityPoints(p3), (25 seconds << 32) - 1, "check53");

        advanceTime(303 seconds);

        // p2 p3 gets the points proportionally
        assertEq(getLiquidityPoints(p1), (100 seconds << 32) - 1 + (25 seconds << 32) - 1, "check61");
        assertEq(getLiquidityPoints(p2), (50 seconds << 32) - 1 + (202 seconds << 32) - 1, "check62");
        assertEq(getLiquidityPoints(p3), (25 seconds << 32) - 1 + (101 seconds << 32) - 1, "check63");
    }

    function testTwoLpRewards_1() external {
        PositionRef memory p1 = addLiquidity(1e18, -1200, 1200, keccak256("1"));
        PositionRef memory p2 = addLiquidity(3e18, -1200, 1200, keccak256("2"));

        streamReward(-1200, 1200, rate = 1 ether, 100 seconds);

        assertEq(getRewards(p1), 0, "check11");
        assertEq(getRewards(p2), 0, "check12");

        advanceTime(20 seconds);

        assertEqWithError({actual: getRewards(p1), expected: 5 ether, maxError: Q32, m: "check21"});
        assertEqWithError({actual: getRewards(p2), expected: 15 ether, maxError: Q32, m: "check22"});

        PositionRef memory p3 = addLiquidity(4e18, -1200, 1200, keccak256("3"));

        assertEqWithError({actual: getRewards(p1), expected: 5 ether, maxError: Q32, m: "check31"});
        assertEqWithError({actual: getRewards(p2), expected: 15 ether, maxError: Q32, m: "check32"});
        assertEq(getRewards(p3), 0, "check33");

        advanceTime(20 seconds);

        assertEqWithError({actual: getRewards(p1), expected: 5 ether + 2.5 ether, maxError: Q32, m: "check41"});
        assertEqWithError({actual: getRewards(p2), expected: 15 ether + 7.5 ether, maxError: Q32, m: "check42"});
        assertEqWithError({actual: getRewards(p3), expected: 10 ether, maxError: Q32, m: "check43"});

        withdrawRewards(p1, address(1111));
        assertEqWithError({
            actual: rewardToken.balanceOf(address(1111)),
            expected: 7.5 ether,
            maxError: Q32,
            m: "check51"
        });

        withdrawRewards(p2, address(2222));
        assertEqWithError({
            actual: rewardToken.balanceOf(address(2222)),
            expected: 22.5 ether,
            maxError: Q32,
            m: "check52"
        });

        withdrawRewards(p3, address(3333));
        assertEqWithError({
            actual: rewardToken.balanceOf(address(3333)),
            expected: 10 ether,
            maxError: Q32,
            m: "check53"
        });
    }

    function currentTick() internal view returns (int24 tickCurrent) {
        PoolId id = key.toId();
        (, tickCurrent,,) = manager.getSlot0(id);
    }

    function logTick() internal view {
        console.logInt(int256(currentTick()));
    }

    function advanceTime(uint256 seconds_) internal {
        vm.warp(block.timestamp + seconds_);
    }

    struct PositionRef {
        address owner;
        int24 tickLower;
        int24 tickUpper;
        bytes32 salt;
    }

    function addLiquidity(int24 tickLower, int24 tickUpper) internal returns (PositionRef memory) {
        return addLiquidity(1e18, tickLower, tickUpper, bytes32(0));
    }

    function addLiquidity(int256 liquidityDelta, int24 tickLower, int24 tickUpper, bytes32 salt)
        internal
        returns (PositionRef memory)
    {
        // add liquidity
        modifyLiquidityRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidityDelta: liquidityDelta,
                salt: salt
            }),
            ZERO_BYTES
        );

        return PositionRef(address(modifyLiquidityRouter), tickLower, tickUpper, salt);
    }

    function withdrawRewards(PositionRef memory p, address beneficiary) internal {
        // add liquidity
        modifyLiquidityRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: p.tickLower,
                tickUpper: p.tickUpper,
                liquidityDelta: 0,
                salt: p.salt
            }),
            abi.encode(rewardToken, rate, beneficiary)
        );
    }

    function getLiquidityPoints(PositionRef memory p) internal returns (uint256 liquidityPoints) {
        vm.prank(address(0));
        (liquidityPoints,,) = hook.getUpdatedPosition(key.toId(), p.owner, p.tickLower, p.tickUpper, p.salt, "");
    }

    function streamReward(int24 tickLower, int24 tickUpper, uint256 streamRate, uint48 duration) internal {
        rewardToken.mint(streamRate * duration);
        rewardToken.approve(address(hook), streamRate * duration);
        hook.streamReward(key.toId(), tickLower, tickUpper, rewardToken, streamRate, duration);
    }

    uint256 rate;

    function getRewards(PositionRef memory p) internal returns (uint256 rewards) {
        vm.prank(address(0));
        (,, rewards) = hook.getUpdatedPosition(
            key.toId(), p.owner, p.tickLower, p.tickUpper, p.salt, abi.encode(rewardToken, rate, address(0))
        );
    }

    function perLiquidity(uint256 secs) internal pure returns (uint160) {
        return uint160(FixedPoint128.Q128 * secs / 1e18);
    }

    function assertEqWithError(uint256 actual, uint256 expected, uint256 maxError, string memory m) internal {
        uint256 diff = actual < expected ? expected - actual : actual - expected;
        if (diff > maxError) {
            assertEq(actual, expected, m);
        }
    }
}

contract RewardToken is ERC20("RewardToken", "REWARD", 18) {
    function mint(uint256 amount) public virtual {
        _mint(msg.sender, amount);
    }
}
