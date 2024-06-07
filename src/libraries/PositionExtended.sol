// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {SafeTransferLib, ERC20} from "solmate/utils/SafeTransferLib.sol";

library PositionExtended {
    using PositionExtended for *;

    struct Info {
        // liquidity points awarded for this position, updated on each position modification
        uint80 relativeSecondsCumulativeX32;
        // snapshot of getSecondsPerLiquidityInsideX128 for which liquidity points are already awarded
        uint176 secondsPerLiquidityInsideLastX128;
        mapping(ERC20 streamToken => mapping(uint256 rate => uint256)) claimed;
    }
}
