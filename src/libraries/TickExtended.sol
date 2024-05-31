// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

library TickExtended {
    using TickExtended for *;

    struct Info {
        uint256 secondsOutside;
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
}
