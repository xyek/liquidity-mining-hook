// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {TickBitmap} from "v4-core/src/libraries/TickBitmap.sol";
import {StateLibrary, IPoolManager, PoolId} from "v4-core/src/libraries/StateLibrary.sol";
import {Pool} from "v4-core/src/libraries/Pool.sol";

library PoolStateRead {
    function tickLiquidityGetter(IPoolManager pm, PoolId poolId)
        internal
        returns (function(int24) view returns (uint128, int128))
    {
        assembly {
            tstore(100, pm)
            tstore(101, poolId)
        }
        return tickLiquidity;
    }

    function tickLiquidity(int24 tick) internal view returns (uint128 liquidityGross, int128 liquidityNet) {
        IPoolManager pm;
        PoolId poolId;
        assembly {
            pm := tload(100)
            poolId := tload(101)
        }
        return StateLibrary.getTickLiquidity(pm, poolId, tick);
    }

    function tickBitmapGetter(IPoolManager poolManager, PoolId poolId)
        internal
        returns (function(int16) view returns (uint256))
    {
        assembly {
            tstore(100, poolManager)
            tstore(101, poolId)
        }
        return tickBitmap;
    }

    // access poolid => struct => mapping(int16 => uint256) tickBitmap;
    function tickBitmap(int16 tick) internal view returns (uint256) {
        IPoolManager pm;
        PoolId poolId;
        assembly {
            pm := tload(100)
            poolId := tload(101)
        }
        return StateLibrary.getTickBitmap(pm, poolId, tick);
    }
}
