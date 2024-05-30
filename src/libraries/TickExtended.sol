// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

library TickExtended {
    using TickExtended for *;

    struct Info {
        uint256 secondsOutside;
        // the seconds per unit of liquidity on the _other_ side of this tick (relative to the current tick)
        // only has relative meaning, not absolute — the value depends on when the tick is initialized
        uint256 secondsPerLiquidityOutsideX128;
    }

    function crossTick(
        mapping(int24 tick => TickExtended.Info) storage self,
        int24 tick,
        uint256 secondsPerLiquidityGlobalX128
    ) internal {
        unchecked {
            TickExtended.Info storage info = self[tick];
            info.secondsPerLiquidityOutsideX128 = secondsPerLiquidityGlobalX128 - info.secondsPerLiquidityOutsideX128;
        }
    }

    // function getTickInfo(uint160 tick) internal pure returns (Info memory) {
    //     return Info({secondsPerLiquidityOutsideX128: tick});
    // }

    // function fn3in(uint a, uint b, uint c) internal pure {}
    // function fn2in(uint a, uint b) internal pure {}

    // function fnfinp(function (uint,uint) pure val) internal {}

    // function fnmain(uint a, uint b, uint c) internal {
    //     // fnfinp(fn2in);
    //     uint x;
    //     x.fn2in(3);
    //     fnfinp(x.fn2in);
    // }

    // function temp(uint)
}
