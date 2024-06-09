// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {FullMath} from "v4-core/src/libraries/FullMath.sol";

library LiquidityPoints {
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
}
