// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

library TickExtended {
    using TickExtended for *;

    struct Info {
        // the timestamp when the tick was last outside the tick range
        uint48 secondsOutside;
        // the cumulative seconds per liquidity outside the tick range
        uint176 secondsPerLiquidityOutsideX128;
    }

    function cross(
        mapping(int24 tick => TickExtended.Info) storage self,
        int24 tick,
        uint176 secondsPerLiquidityGlobalX128
    ) internal {
        Info storage info = self[tick];
        info.secondsOutside = uint48(block.timestamp - info.secondsOutside);
        info.secondsPerLiquidityOutsideX128 = secondsPerLiquidityGlobalX128 - info.secondsPerLiquidityOutsideX128;
    }
}
