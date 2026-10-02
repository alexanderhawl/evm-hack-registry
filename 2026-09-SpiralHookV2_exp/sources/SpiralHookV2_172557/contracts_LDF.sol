// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";

// The first-ever multi-chain immutable perpetual launchpad with day-0 leverage. Launch any token, trade it, borrow against it, long it, short it up to 20x leverage - from block zero.
// Spiral is a Uniswap V4 hook protocol that fuses an AMM, a lending market, perpetual exchange and a launchpad into a single contract surface. Every token in the system - the canonical SPIRAL and any token deployed through the launchpad - gets the full primitive set from the moment the pool initializes:
// Trade: spot BUY / SELL through the V4 pool via the Universal Router.
// Borrow: deposit the token, draw ETH from idle below-spot liquidity, repay any time.
// Leverage long: a forced atomic market buy that loops collateral ⇄ ETH borrow up to the launch's max LTV.
// Leverage short: the mirror of a long - borrow tokens from a reserved slice, sell, pocket the ETH.
// Liquidations: permissionless, with built-in maturity gating and bounty caps.
// First multi-chain launchpad where every chain's revenue buys back one canonical token. The launchpad runs on Ethereum, Base, BNB Chain and Robinhood Chain, but there is a single canonical SPIRAL - and it lives on Ethereum.
// Fees earned on every chain converge on it: on Ethereum the buyback fires atomically on-chain, while Base, BNB and Robinhood Chain accumulate their fee slices in a custodial treasury that is bridged to Ethereum for the exact same buy-and-burn. Wherever the activity happens, it all compounds into buying and burning the one canonical SPIRAL.
// Liquidity is locked to the hook - nobody can add or remove LP (onlyPoolManager = the Uniswap V4 PoolManager singleton. poolManager is set as immutable in the hook's constructor - it's the canonical Uniswap V4 contract on each chain (Ethereum mainnet: 0x000000000004444c5dc75cB358380D2e3dE08A90). It is a Uniswap-owned contract, NOT Spiral's deployer and NOT the hook itself)
// Flywheel system with 100% of revenue buying and burning SPIRAL token on Ethereum.
// Immutable V4-hook perps launchpad - atomic leveraged-long & short - borrow primitives - constructor-frozen fee routing - one canonical chain (token + hook + atomic burn), 4 launchpad-only chains - no governance, no admin key, no LP.
// Website: https://spir8l.com
// Docs: https://spir8l.com/docs
// Math: https://spir8l.com/math
// Telegram: https://t.me/spir8l_com
// Twitter: https://x.com/spir8l_com

/// @title LDF (Liquidity Distribution Function)
/// @notice Maps the Spiral constant-product curve `realSpiral · (V + realETH) = K` to V4
///         concentrated-liquidity bands. Pool currency0 = ETH (zero), currency1 = SPIRAL.
///         As realETH grows, V4 price (SPIRAL/ETH = currency1/currency0) DROPS, currentTick DROPS.
///         So band 0 (lowest realETH range 0-30 ETH) corresponds to the HIGHEST V4 ticks.
library LDF {
    // ── must-have constants ────────────────────────────────────────────────
    int24   internal constant TICK_SPACING       = 60;
    uint256 internal constant TOTAL_SUPPLY       = 1_000_000 * 1e18;   // 1M SPIRAL
    uint256 internal constant V                  = 5 ether;             // virtual ETH reserve
    uint256 internal constant K_NUMERATOR        = 5 * 1_000_000;      // K = V * TOTAL_SUPPLY = 5e18 * 1e24 = 5e42 wei^2
                                                                         // we store K as `K_NUMERATOR * 1e36` to keep precision
    uint256 internal constant BAND_ETH_WIDTH     = 30 ether;            // 30 ETH per band
    uint256 internal constant NUM_BANDS          = 100;                 // covers realETH 0..3000

    // K in wei^2: V_wei * TOTAL_SUPPLY_wei = (5 * 1e18) * (1e6 * 1e18) = 5e42
    function K() internal pure returns (uint256) {
        return 5 ether * 1_000_000 * 1e18; // = 5e42 wei^2
    }

    // ── band → SPIRAL allocation ───────────────────────────────────────────
    /// @notice SPIRAL tokens (wei) allocated to band `bandId`, per the bonding curve.
    ///         SPIRAL_band_i = K/(V + 30i) - K/(V + 30(i+1))
    function spiralAllocForBand(uint256 bandId) internal pure returns (uint256) {
        uint256 ethStart = bandId * BAND_ETH_WIDTH;
        uint256 ethEnd   = (bandId + 1) * BAND_ETH_WIDTH;
        uint256 kVal = K();
        return kVal / (V + ethStart) - kVal / (V + ethEnd);
    }

    // ── price ↔ sqrtPrice ↔ tick ────────────────────────────────────────────
    /// @notice Compute sqrtPriceX96 at given realETH using the Spiral curve.
    ///         V4_price = K / (V + realETH)^2  (token1/token0 = SPIRAL/ETH ratio)
    ///         sqrtPrice = sqrt(V4_price) = sqrt(K) / (V + realETH)
    ///         sqrtPriceX96 = sqrt(K) / (V + realETH) * 2^96
    function sqrtPriceAtRealETH(uint256 realETH) internal pure returns (uint160) {
        uint256 effectiveETH = V + realETH;
        uint256 sqrtK = sqrt(K());
        uint256 result = (sqrtK << 96) / effectiveETH;
        require(result <= type(uint160).max, "sqrtPriceOverflow");
        require(result >= TickMath.MIN_SQRT_PRICE && result <= TickMath.MAX_SQRT_PRICE, "sqrtPriceRange");
        return uint160(result);
    }

    /// @notice Compute realETH given a sqrtPriceX96 (inverse of sqrtPriceAtRealETH).
    function realETHAtSqrtPrice(uint160 sqrtPriceX96) internal pure returns (uint256) {
        uint256 sqrtK = sqrt(K());
        uint256 effectiveETH = (sqrtK << 96) / uint256(sqrtPriceX96);
        if (effectiveETH < V) return 0;
        return effectiveETH - V;
    }

    /// @notice V4 ticks for a band's ETH range, aligned to TICK_SPACING (align DOWN
    ///         for both bounds so adjacent bands tile cleanly).
    ///         Returns (tickLower, tickUpper) where tickUpper > tickLower.
    function bandToV4Ticks(uint256 bandId) internal pure returns (int24 tickLower, int24 tickUpper) {
        uint256 ethStart = bandId * BAND_ETH_WIDTH;
        uint256 ethEnd   = (bandId + 1) * BAND_ETH_WIDTH;
        uint160 sqrtPriceLow  = sqrtPriceAtRealETH(ethEnd);   // higher realETH → lower V4 price → lower tick
        uint160 sqrtPriceHigh = sqrtPriceAtRealETH(ethStart); // lower realETH → higher tick
        int24 rawLow  = TickMath.getTickAtSqrtPrice(sqrtPriceLow);
        int24 rawHigh = TickMath.getTickAtSqrtPrice(sqrtPriceHigh);
        tickLower = alignDown(rawLow);
        tickUpper = alignDown(rawHigh);
        if (tickUpper <= tickLower) tickUpper = tickLower + TICK_SPACING;
    }

    // `liquidationEthForBorrowEth` was defined here for a planned bound-band
    // resolver that never shipped - production code resolves bound bands via
    // `_findFeasibleBorrowBand` (LP-availability scan) instead. Removed in
    // audit L-08 / N-L-09 cleanup so the file no longer carries dead math
    // whose comment-derived formula and returned value disagreed.

    /// @notice Map realETH to band id (clamped to [0, NUM_BANDS-1]).
    function ethToBandId(uint256 realETH) internal pure returns (uint256) {
        uint256 b = realETH / BAND_ETH_WIDTH;
        if (b >= NUM_BANDS) b = NUM_BANDS - 1;
        return b;
    }

    // ── valuation ──────────────────────────────────────────────────────────
    /// @notice Value `spiralAmount` in ETH at current sqrtPriceX96.
    ///         spot (ETH per SPIRAL) = 1 / V4_price = 2^192 / sqrtPriceX96^2
    function spiralValueInETH(uint160 sqrtPriceX96, uint256 spiralAmount) internal pure returns (uint256) {
        uint256 sqrtP = uint256(sqrtPriceX96);
        uint256 a = FullMath.mulDiv(spiralAmount, 1 << 96, sqrtP);
        return FullMath.mulDiv(a, 1 << 96, sqrtP);
    }

    /// @notice Curve-aware estimate of ETH proceeds for selling `spiralAmount`
    ///         SPIRAL against the bonding curve. See LDFx.swapTokenForEthOnCurve
    ///         for the derivation. Used by SpiralViewsV2.quoteCloseLongAtomic
    ///         to predict ACTUAL ethReturned (the chain swap goes back DOWN
    ///         the curve, recovering materially less ETH than spot × amount).
    /// @dev    The canonical Spiral pool has no reservedSupply - the entire
    ///         token supply is seeded as LP - so no scaling is needed here.
    function swapSpiralForEthOnCurve(uint160 sqrtPriceX96, uint256 spiralAmount)
        internal pure returns (uint256)
    {
        if (spiralAmount == 0) return 0;
        uint256 realETH = realETHAtSqrtPrice(sqrtPriceX96);
        uint256 vPlusR  = V + realETH;
        uint256 kVal    = K();
        uint256 nvR     = FullMath.mulDiv(spiralAmount, vPlusR, 1);
        uint256 denom   = kVal + nvR;
        if (denom == 0) return 0;
        return FullMath.mulDiv(vPlusR, nvR, denom);
    }

    /// @notice Curve-aware estimate of SPIRAL output when injecting
    ///         `ethAmount` ETH into the bonding curve at the current spot.
    ///         Symmetric inverse of `swapSpiralForEthOnCurve`:
    ///           spiral_out = K × ethIn / ((V+R) × (V+R+ethIn))
    ///         Asymptotes to `K / (V+R)` (all in-pool SPIRAL) as ethIn → ∞,
    ///         so the formula stays sane even when the buy would empty the
    ///         curve. Used by `SpiralBuyback.flush` to derive an internal
    ///         slippage floor that does not depend on the caller (audit H-4).
    function swapEthForTokenOnCurve(uint160 sqrtPriceX96, uint256 ethAmount)
        internal pure returns (uint256)
    {
        if (ethAmount == 0) return 0;
        uint256 realETH  = realETHAtSqrtPrice(sqrtPriceX96);
        uint256 vPlusR   = V + realETH;
        uint256 vPlusRN  = vPlusR + ethAmount;
        if (vPlusR == 0 || vPlusRN == 0) return 0;
        // a = K × ethAmount / (V+R). Max numerator at typical inputs:
        // K = 2e43, ethAmount up to ~3e21 (3000 ETH ceiling) → 6e64,
        // comfortably inside uint256.
        uint256 a = FullMath.mulDiv(K(), ethAmount, vPlusR);
        return a / vPlusRN;
    }

    // ── V4 LP math wrappers ────────────────────────────────────────────────
    /// @notice Liquidity (uint128) needed to deploy `spiralAmount` as single-sided
    ///         token1 (SPIRAL) liquidity over [tickLower, tickUpper], assuming
    ///         currentTick > tickUpper (band fully above current price = all token1).
    function liquidityForSpiralOnly(int24 tickLower, int24 tickUpper, uint256 spiralAmount)
        internal pure returns (uint128)
    {
        return LiquidityAmounts.getLiquidityForAmount1(
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            spiralAmount
        );
    }

    /// @notice Liquidity needed to deploy `ethAmount` as single-sided token0 (ETH)
    ///         liquidity over [tickLower, tickUpper], assuming currentTick < tickLower.
    function liquidityForEthOnly(int24 tickLower, int24 tickUpper, uint256 ethAmount)
        internal pure returns (uint128)
    {
        return LiquidityAmounts.getLiquidityForAmount0(
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            ethAmount
        );
    }

    /// @notice Liquidity to extract `ethAmount` of ETH from a position over
    ///         [tickLower, tickUpper], at current sqrtP. Handles straddle
    ///         (currentTick in band) by using only the upper sub-range that's still
    ///         in the ETH-only zone (currentTick < tickLower of the sub-range).
    /// @dev See LDFx.liquidityForEthAtSpot for full rationale. Manual mulDiv
    ///      so we can cap at uint128 max instead of bubbling SafeCastOverflow
    ///      from the library when sqrtP is within ~1 tick of sqrtU.
    function liquidityForEthAtSpot(
        uint160 sqrtP,
        int24 tickLower,
        int24 tickUpper,
        uint256 ethAmount
    ) internal pure returns (uint128) {
        uint160 sqrtU = TickMath.getSqrtPriceAtTick(tickUpper);
        if (sqrtP >= sqrtU) return 0;
        uint160 sqrtL = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtLo = sqrtP <= sqrtL ? sqrtL : sqrtP;
        uint256 intermediate = FullMath.mulDiv(uint256(sqrtLo), uint256(sqrtU), 1 << 96);
        uint256 raw = FullMath.mulDiv(ethAmount, intermediate, uint256(sqrtU) - uint256(sqrtLo));
        if (raw > type(uint128).max) return 0;
        return uint128(raw);
    }

    // ── tick alignment ─────────────────────────────────────────────────────
    function alignDown(int24 tick) internal pure returns (int24) {
        // Solidity int division rounds toward zero; for negative ticks this is NOT floor.
        // Our use case is positive ticks (Spiral curve has positive ticks throughout).
        if (tick >= 0) {
            return (tick / TICK_SPACING) * TICK_SPACING;
        } else {
            int24 q = tick / TICK_SPACING;
            if (q * TICK_SPACING != tick) q -= 1;
            return q * TICK_SPACING;
        }
    }

    function alignUp(int24 tick) internal pure returns (int24) {
        int24 d = alignDown(tick);
        if (d == tick) return tick;
        return d + TICK_SPACING;
    }

    // ── uint256 sqrt (Babylonian) ─────────────────────────────────────────
    function sqrt(uint256 x) internal pure returns (uint256 r) {
        if (x == 0) return 0;
        uint256 z = (x + 1) / 2;
        r = x;
        while (z < r) { r = z; z = (x / z + z) / 2; }
    }
}
