// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./IUniswapV2Factory.sol";
import "./IUniswapV2Pair.sol";

import "./IPositionManager.sol";
import "./IUniswapV3Pool.sol";
import "./FixedPoint128.sol";
import "./IUniswapV3Factory.sol";
import "./TickMath.sol";

library Uniswap {
    struct GetFeesCache {
    	uint256 tickLowerFeeGrowthBelow_0;
    	uint256 tickLowerFeeGrowthBelow_1;
    	uint256 tickUpperFeeGrowthAbove_0;
    	uint256 tickUpperFeeGrowthAbove_1;

        uint256 feeGrowthGlobal0X128;
        uint256 feeGrowthGlobal1X128;

    	uint256 fr_t1_0;
    	uint256 fr_t1_1;

    	uint256 uncollectedFees_0;
    	uint256 uncollectedFees_1;
    }

    struct GetPositionCache {
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        uint256 feeGrowthInside0LastX128;
        uint256 feeGrowthInside1LastX128;
        uint128 tokensOwed0;
        uint128 tokensOwed1;
    }

    function subIn256(uint256 x, uint256 y) internal pure returns (uint256) {
        unchecked {
            return x - y;
        }
    }

    // reference: https://blog.uniswap.org/uniswap-v3-math-primer-2
    function getFees(
        IUniswapV3Pool pool,
        IPositionManager.Position memory position,
        IUniswapV3Pool.Slot0 memory slot0,
        IUniswapV3Pool.Tick memory tickLower,
        IUniswapV3Pool.Tick memory tickUpper
    ) internal view returns (uint256, uint256) {
        GetFeesCache memory cache;

        cache.feeGrowthGlobal0X128 = pool.feeGrowthGlobal0X128();
        cache.feeGrowthGlobal1X128 = pool.feeGrowthGlobal1X128();

    	if (slot0.tick >= position.tickUpper) {
    		cache.tickUpperFeeGrowthAbove_0 = subIn256(cache.feeGrowthGlobal0X128, tickUpper.feeGrowthOutside0X128);
    		cache.tickUpperFeeGrowthAbove_1 = subIn256(cache.feeGrowthGlobal1X128, tickUpper.feeGrowthOutside1X128);
    	} else {
            // Else if current tick is in range only need fg for upper growth
    		cache.tickUpperFeeGrowthAbove_0 = tickUpper.feeGrowthOutside0X128;
    		cache.tickUpperFeeGrowthAbove_1 = tickUpper.feeGrowthOutside1X128;
    	}

        // If current tick is in range only need fg for lower growth
    	if (slot0.tick >= position.tickLower){
    		cache.tickLowerFeeGrowthBelow_0 = tickLower.feeGrowthOutside0X128;
    		cache.tickLowerFeeGrowthBelow_1 = tickLower.feeGrowthOutside1X128;
    	} else {
            // If current tick is above the range fg- fo,il Growth below range
    		cache.tickLowerFeeGrowthBelow_0 = subIn256(cache.feeGrowthGlobal0X128, tickLower.feeGrowthOutside0X128);
    		cache.tickLowerFeeGrowthBelow_1 = subIn256(cache.feeGrowthGlobal1X128, tickLower.feeGrowthOutside1X128);
    	}

        //   fr(t1) For both token0 and token1
    	cache.fr_t1_0 = subIn256(subIn256(cache.feeGrowthGlobal0X128, cache.tickLowerFeeGrowthBelow_0), cache.tickUpperFeeGrowthAbove_0);
    	cache.fr_t1_1 = subIn256(subIn256(cache.feeGrowthGlobal1X128, cache.tickLowerFeeGrowthBelow_1), cache.tickUpperFeeGrowthAbove_1);

    	// The final calculations uncollected fees formula
    	// for both token 0 and token 1 since we now know everything that is needed to compute it
        // subtracting the two values and then multiplying with liquidity l *(fr(t1) - fr(t0))
    	cache.uncollectedFees_0 = (position.liquidity * subIn256(cache.fr_t1_0, position.feeGrowthInside0LastX128)) / FixedPoint128.Q128;
    	cache.uncollectedFees_1 = (position.liquidity * subIn256(cache.fr_t1_1, position.feeGrowthInside1LastX128)) / FixedPoint128.Q128;

        return (position.tokensOwed0 + cache.uncollectedFees_0, position.tokensOwed1 + cache.uncollectedFees_1);
    }

    /// @dev Simulate exact-input swap impact using current sqrt price and in-range liquidity.
    /// @dev This models within-range price impact but does not model liquidity changes after tick crossings.
    function simulateSwapExactIn(
        uint256 amountIn,
        uint128 liquidity,
        uint160 sqrtPriceX96,
        bool zeroForOne,
        uint24 feePpm
    ) internal pure returns (uint256 amountOut, uint160 nextSqrtPriceX96) {
        if (amountIn == 0 || liquidity == 0) {
            return (0, sqrtPriceX96);
        }

        uint256 amountInAfterFee = amountIn * (1e6 - feePpm) / 1e6;
        if (amountInAfterFee == 0) {
            return (0, sqrtPriceX96);
        }

        uint256 liquidityX96 = uint256(liquidity) << 96;

        if (zeroForOne) {
            uint256 denominator = liquidityX96 + amountInAfterFee * uint256(sqrtPriceX96);
            nextSqrtPriceX96 = uint160(mulDiv(liquidityX96, sqrtPriceX96, denominator));
            amountOut = mulDiv(uint256(liquidity), uint256(sqrtPriceX96) - uint256(nextSqrtPriceX96), 2 ** 96);
            return (amountOut, nextSqrtPriceX96);
        }

        uint256 delta = mulDiv(amountInAfterFee, 2 ** 96, liquidity);
        nextSqrtPriceX96 = uint160(uint256(sqrtPriceX96) + delta);

        uint256 numerator = mulDiv(liquidityX96, uint256(nextSqrtPriceX96) - uint256(sqrtPriceX96), uint256(nextSqrtPriceX96));
        amountOut = numerator / uint256(sqrtPriceX96);
    }

    /// @dev Full-precision mulDiv copied from Uniswap-style implementation.
    function mulDiv(uint256 a, uint256 b, uint256 denominator) internal pure returns (uint256 result) {
        unchecked {
            uint256 prod0;
            uint256 prod1;
            assembly {
                let mm := mulmod(a, b, not(0))
                prod0 := mul(a, b)
                prod1 := sub(sub(mm, prod0), lt(mm, prod0))
            }

            if (prod1 == 0) {
                return prod0 / denominator;
            }

            require(denominator > prod1, "mulDiv overflow");

            uint256 remainder;
            assembly {
                remainder := mulmod(a, b, denominator)
                prod1 := sub(prod1, gt(remainder, prod0))
                prod0 := sub(prod0, remainder)
            }

            uint256 twos = denominator & (~denominator + 1);
            assembly {
                denominator := div(denominator, twos)
                prod0 := div(prod0, twos)
                twos := add(div(sub(0, twos), twos), 1)
            }
            prod0 |= prod1 * twos;

            uint256 inv = (3 * denominator) ^ 2;
            inv *= 2 - denominator * inv;
            inv *= 2 - denominator * inv;
            inv *= 2 - denominator * inv;
            inv *= 2 - denominator * inv;
            inv *= 2 - denominator * inv;
            inv *= 2 - denominator * inv;

            result = prod0 * inv;
        }
    }
}
