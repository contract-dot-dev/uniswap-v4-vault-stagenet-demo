// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.26;

import {FullMath} from "v4-core/libraries/FullMath.sol";
import {FixedPoint96} from "v4-core/libraries/FixedPoint96.sol";

// Liquidity amount helpers, ported from Uniswap V3-periphery / V4-core test
// utils. Provides the inverse functions (`getAmountsForLiquidity` etc.) that
// the V4 periphery library does not expose at runtime.
library LiquidityAmounts {
    function toUint128(uint256 x) private pure returns (uint128 y) {
        require((y = uint128(x)) == x, "liquidity overflow");
    }

    function getLiquidityForAmount0(
        uint160 sqrtPriceAX96,
        uint160 sqrtPriceBX96,
        uint256 amount0
    ) internal pure returns (uint128 liquidity) {
        if (sqrtPriceAX96 > sqrtPriceBX96)
            (sqrtPriceAX96, sqrtPriceBX96) = (sqrtPriceBX96, sqrtPriceAX96);
        uint256 intermediate = FullMath.mulDiv(
            sqrtPriceAX96,
            sqrtPriceBX96,
            FixedPoint96.Q96
        );
        return
            toUint128(
                FullMath.mulDiv(
                    amount0,
                    intermediate,
                    sqrtPriceBX96 - sqrtPriceAX96
                )
            );
    }

    function getLiquidityForAmount1(
        uint160 sqrtPriceAX96,
        uint160 sqrtPriceBX96,
        uint256 amount1
    ) internal pure returns (uint128 liquidity) {
        if (sqrtPriceAX96 > sqrtPriceBX96)
            (sqrtPriceAX96, sqrtPriceBX96) = (sqrtPriceBX96, sqrtPriceAX96);
        return
            toUint128(
                FullMath.mulDiv(
                    amount1,
                    FixedPoint96.Q96,
                    sqrtPriceBX96 - sqrtPriceAX96
                )
            );
    }

    function getLiquidityForAmounts(
        uint160 sqrtPriceX96,
        uint160 sqrtPriceAX96,
        uint160 sqrtPriceBX96,
        uint256 amount0,
        uint256 amount1
    ) internal pure returns (uint128 liquidity) {
        if (sqrtPriceAX96 > sqrtPriceBX96)
            (sqrtPriceAX96, sqrtPriceBX96) = (sqrtPriceBX96, sqrtPriceAX96);

        if (sqrtPriceX96 <= sqrtPriceAX96) {
            liquidity = getLiquidityForAmount0(
                sqrtPriceAX96,
                sqrtPriceBX96,
                amount0
            );
        } else if (sqrtPriceX96 < sqrtPriceBX96) {
            uint128 liquidity0 = getLiquidityForAmount0(
                sqrtPriceX96,
                sqrtPriceBX96,
                amount0
            );
            uint128 liquidity1 = getLiquidityForAmount1(
                sqrtPriceAX96,
                sqrtPriceX96,
                amount1
            );
            liquidity = liquidity0 < liquidity1 ? liquidity0 : liquidity1;
        } else {
            liquidity = getLiquidityForAmount1(
                sqrtPriceAX96,
                sqrtPriceBX96,
                amount1
            );
        }
    }

    function getAmount0ForLiquidity(
        uint160 sqrtPriceAX96,
        uint160 sqrtPriceBX96,
        uint128 liquidity
    ) internal pure returns (uint256 amount0) {
        if (sqrtPriceAX96 > sqrtPriceBX96)
            (sqrtPriceAX96, sqrtPriceBX96) = (sqrtPriceBX96, sqrtPriceAX96);
        return
            FullMath.mulDiv(
                uint256(liquidity) << FixedPoint96.RESOLUTION,
                sqrtPriceBX96 - sqrtPriceAX96,
                sqrtPriceBX96
            ) / sqrtPriceAX96;
    }

    function getAmount1ForLiquidity(
        uint160 sqrtPriceAX96,
        uint160 sqrtPriceBX96,
        uint128 liquidity
    ) internal pure returns (uint256 amount1) {
        if (sqrtPriceAX96 > sqrtPriceBX96)
            (sqrtPriceAX96, sqrtPriceBX96) = (sqrtPriceBX96, sqrtPriceAX96);
        return
            FullMath.mulDiv(
                liquidity,
                sqrtPriceBX96 - sqrtPriceAX96,
                FixedPoint96.Q96
            );
    }

    function getAmountsForLiquidity(
        uint160 sqrtPriceX96,
        uint160 sqrtPriceAX96,
        uint160 sqrtPriceBX96,
        uint128 liquidity
    ) internal pure returns (uint256 amount0, uint256 amount1) {
        if (sqrtPriceAX96 > sqrtPriceBX96)
            (sqrtPriceAX96, sqrtPriceBX96) = (sqrtPriceBX96, sqrtPriceAX96);

        if (sqrtPriceX96 <= sqrtPriceAX96) {
            amount0 = getAmount0ForLiquidity(
                sqrtPriceAX96,
                sqrtPriceBX96,
                liquidity
            );
        } else if (sqrtPriceX96 < sqrtPriceBX96) {
            amount0 = getAmount0ForLiquidity(
                sqrtPriceX96,
                sqrtPriceBX96,
                liquidity
            );
            amount1 = getAmount1ForLiquidity(
                sqrtPriceAX96,
                sqrtPriceX96,
                liquidity
            );
        } else {
            amount1 = getAmount1ForLiquidity(
                sqrtPriceAX96,
                sqrtPriceBX96,
                liquidity
            );
        }
    }
}
