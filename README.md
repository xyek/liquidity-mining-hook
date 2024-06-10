# liquidity-mining-hook

This [hook](https://github.com/xyek/liquidity-hook/blob/main/src/LiquidityMiningHook.sol#L43) enables rewards for liquidity positions in any reward token based on the time spent by price in the tick range and liquidity amount. 

This is a hobby project built during [Hookathon C1](https://uniswap.atrium.academy/hackathons/hookathon-c1/portal/). If you are interested to tune it to your needs, feel free to contact me on discord @ xyek3165.

## Problem

In traditional liquidity mining, user has to perform additional action after addition of liquidity called "stake". Not only this requires multiple transactions and more gas fees but the user experience also degrades.

## Solution

This project is a hook for uniswap v4 pool.

When user is interacting with a v4 pool that uses this hook under the hood, user can simply add or remove the liquidity using standard v4 interface. And to claim the rewards for their previous liquidity positions users just require to pass a [`hookData`](https://github.com/xyek/liquidity-hook/blob/main/src/LiquidityMiningHook.sol#L169-L172) when they are removing liquidity (or they can also add liquidity of 0 value which would also trigger the rewards withdrawal).

## How does this work?

This hook contract extends the tick variables present in the V4. 

New tick variables are added are: [(source)](https://github.com/xyek/liquidity-hook/blob/main/src/libraries/TickExtended.sol#L14-L19). 
- `secondsOutside`
- `secondsPerLiquidityOutsideX128`

These tick variables are maintained using [SimulateSwap](https://github.com/xyek/liquidity-hook/blob/main/src/libraries/SimulateSwap.sol#L32) library that enables a [custom hook to the swap step](https://github.com/xyek/liquidity-hook/blob/main/src/LiquidityMiningHook.sol#L294-L300) for updating the state on tick cross.

This enables us to know how many seconds the price was present in the range and `secondsPerLiquidity` enables to factor in the liquidity to calculate the rewards.

## Disclaimer

Contracts contain bugs.