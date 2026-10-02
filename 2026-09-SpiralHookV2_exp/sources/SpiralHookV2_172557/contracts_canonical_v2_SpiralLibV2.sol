// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {LDF} from "../LDF.sol";

interface ISpiralBurnable {
    function burn(uint256 amount) external;
}

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


/// @notice Externalised heavy lifters for SpiralHookV2 (canonical). Same
///         DELEGATECALL pattern as ChildSpiralLib: deployed once, linked
///         at hook deploy time. Library functions receive only primitives
///         - V4 storage refs cannot cross the external library boundary.
///
///         Differences vs the child-launch lib:
///           ▸ Curve constants come from LDF (canonical), not LDFx (per-launch)
///           ▸ Routing: 100% of origFee + residue → `spiralBuyback`
///             (canonical buyback-and-burn). Child's 50/50 buyback/creator
///             split does not apply here.
library SpiralLibV2 {
    error NoEthOut();
    error PositionUnderwater();

    // ────────────────────────────────────────────────────────────────────────
    //  SEED
    // ────────────────────────────────────────────────────────────────────────
    struct SeedBandArgs {
        IPoolManager pm;
        PoolKey      poolKey;
        IERC20       token;
        int24        tickLower;
        int24        tickUpper;
        uint256      tokenAlloc;
    }

    function doSeedOneBand(SeedBandArgs memory a) external returns (uint128 liq) {
        liq = LDF.liquidityForSpiralOnly(a.tickLower, a.tickUpper, a.tokenAlloc);
        (BalanceDelta delta,) = a.pm.modifyLiquidity(
            a.poolKey,
            ModifyLiquidityParams({
                tickLower: a.tickLower,
                tickUpper: a.tickUpper,
                liquidityDelta: int128(liq),
                salt: bytes32(0)
            }),
            ""
        );
        int128 a1 = delta.amount1();
        if (a1 < 0) {
            uint256 owed = uint256(uint128(-a1));
            a.pm.sync(a.poolKey.currency1);
            require(a.token.transfer(address(a.pm), owed), "SpiralXfer");
            a.pm.settle();
        }
    }

    // ────────────────────────────────────────────────────────────────────────
    //  SPIRAL LONG STEP (forced-reinvest borrow leg)
    // ────────────────────────────────────────────────────────────────────────
    struct LongArgs {
        IPoolManager    pm;
        PoolKey         poolKey;
        IERC20          token;
        address payable spiralBuyback;
        uint160         lpMinSqrtPriceX96;
        int24           bandTickLower;
        int24           bandTickUpper;
        uint128         lToRemove;
        address         recipient;     // tokens go here (hook itself for FromEth loops, user for direct calls)
        uint256         useLtvBps;
        uint256         origFeeBps;
    }

    /// @notice See ChildSpiralLib.doSpiralLong for the partial-fill rationale.
    ///         Canonical mirror: same semantics, no creatorVault routing.
    function doSpiralLong(LongArgs memory a)
        external
        returns (uint256 ethFromBand, uint256 tokenOut, uint256 ethUnspent)
    {
        (BalanceDelta delta,) = a.pm.modifyLiquidity(
            a.poolKey,
            ModifyLiquidityParams({
                tickLower: a.bandTickLower,
                tickUpper: a.bandTickUpper,
                liquidityDelta: -int256(uint256(a.lToRemove)),
                salt: bytes32(0)
            }),
            ""
        );
        int128 a0 = delta.amount0();
        int128 a1 = delta.amount1();
        // Graceful degradation: see ChildSpiralLib.doSpiralLong - restore L
        // and return zeros so the outer loop ships partial leverage or
        // degrades to a 1× spot buy instead of reverting the whole tx.
        if (a0 <= 0) {
            a.pm.modifyLiquidity(
                a.poolKey,
                ModifyLiquidityParams({
                    tickLower: a.bandTickLower,
                    tickUpper: a.bandTickUpper,
                    liquidityDelta: int256(uint256(a.lToRemove)),
                    salt: bytes32(0)
                }),
                ""
            );
            return (0, 0, 0);
        }
        ethFromBand = uint256(uint128(a0));
        if (a1 > 0) {
            uint256 straddleToken = uint256(uint128(a1));
            a.pm.take(a.poolKey.currency1, address(this), straddleToken);
            // Hold in hook as protocol-held reserve. PRIOR behaviour was
            // `.burn(straddleToken)` here; that silently shrank totalSupply
            // every spiralLong loop iter and made the curve formula
            // (K = V × originalSupply) drift from on-chain reality. With
            // hold-in-hook, totalSupply stays constant and every quote
            // helper (`swapEthForTokenOnCurve`, `realETHAtSqrtPrice`, the
            // dashboard's mcap math, etc) continues to match the actual
            // swap behavior. Tokens accumulate in the hook's balance and
            // can be re-deployed by future protocol surfaces if needed.
        }

        // Audit M-2: origFee was previously taken on the FULL ethFromBand
        // BEFORE the swap. On a partial fill (V4 stops at lpMinSqrtPriceX96),
        // the user paid origFee on ETH that never reached the curve - making
        // the effective fee rate as high as 100% of recorded debt in worst
        // cases. Fix: size the swap as if a full fill would happen (so the
        // band sees the same swap input as before, preserving curve dynamics),
        // but take the fee POST-swap from `ethConsumed`. Unspent ETH flows
        // back to refill the band via ethUnspent.
        uint256 origFeeMax = (ethFromBand * a.origFeeBps) / a.useLtvBps;
        uint256 ethToSwap  = ethFromBand - origFeeMax;

        BalanceDelta swapDelta = a.pm.swap(
            a.poolKey,
            SwapParams({zeroForOne: true, amountSpecified: -int256(ethToSwap), sqrtPriceLimitX96: a.lpMinSqrtPriceX96}),
            ""
        );
        int128 sa0 = swapDelta.amount0();
        int128 sa1 = swapDelta.amount1();

        uint256 ethConsumed = sa0 < 0 ? uint256(uint128(-sa0)) : 0;
        if (ethConsumed > ethToSwap) ethConsumed = ethToSwap;

        // Fee proportional to ETH that actually hit the curve. On a full fill
        // this equals origFeeMax × (1 − f) where f = origFeeBps/useLtvBps;
        // effective rate on debt is f/(1+f), within ~2-3% of the nominal rate
        // for canonical params and immune to partial-fill amplification.
        uint256 origFee = (ethConsumed * a.origFeeBps) / a.useLtvBps;
        if (origFee > 0) {
            a.pm.take(CurrencyLibrary.ADDRESS_ZERO, a.spiralBuyback, origFee);
        }

        tokenOut = sa1 > 0 ? uint256(uint128(sa1)) : 0;
        if (tokenOut > 0) {
            a.pm.take(a.poolKey.currency1, a.recipient, tokenOut);
        }

        // Whatever currency0 is left after the swap and fee take. Equals
        // ethFromBand − ethConsumed − origFee. The hook refills the band
        // with this; recorded debt = ethFromBand − ethUnspent = ethConsumed
        // + origFee, so the fee/debt rate is exact.
        ethUnspent = ethFromBand - ethConsumed - origFee;
        if (ethUnspent > 0) {
            a.pm.take(CurrencyLibrary.ADDRESS_ZERO, address(this), ethUnspent);
        }
    }

    // ────────────────────────────────────────────────────────────────────────
    //  BORROW (plain ETH-out)
    // ────────────────────────────────────────────────────────────────────────
    struct BorrowArgs {
        IPoolManager    pm;
        PoolKey         poolKey;
        IERC20          token;
        address payable spiralBuyback;
        int24           bandTickLower;
        int24           bandTickUpper;
        uint128         lToRemove;
        address         recipient;
        uint256         ltvBps;
        uint256         origFeeBps;
    }

    function doBorrow(BorrowArgs memory a) external returns (uint256 ethFromBand, uint256 ethToUser) {
        (BalanceDelta delta,) = a.pm.modifyLiquidity(
            a.poolKey,
            ModifyLiquidityParams({
                tickLower: a.bandTickLower,
                tickUpper: a.bandTickUpper,
                liquidityDelta: -int256(uint256(a.lToRemove)),
                salt: bytes32(0)
            }),
            ""
        );
        int128 a0 = delta.amount0();
        int128 a1 = delta.amount1();
        if (a0 <= 0) revert NoEthOut();
        ethFromBand = uint256(uint128(a0));
        if (a1 > 0) {
            uint256 straddleToken = uint256(uint128(a1));
            a.pm.take(a.poolKey.currency1, address(this), straddleToken);
            // Hold in hook - same rationale as doSpiralLong's straddle
            // handling. Burn was previously here; removed to keep
            // totalSupply constant so K-formula stays accurate.
        }

        uint256 origFee = (ethFromBand * a.origFeeBps) / a.ltvBps;
        ethToUser = ethFromBand - origFee;

        if (origFee > 0) {
            a.pm.take(CurrencyLibrary.ADDRESS_ZERO, a.spiralBuyback, origFee);
        }
        a.pm.take(CurrencyLibrary.ADDRESS_ZERO, a.recipient, ethToUser);
    }

    // ────────────────────────────────────────────────────────────────────────
    //  INIT BUY (ETH→SPIRAL swap leg of spiralLongFromEth)
    // ────────────────────────────────────────────────────────────────────────
    struct InitBuyArgs {
        IPoolManager pm;
        PoolKey      poolKey;
        uint160      lpMinSqrtPriceX96;
        uint256      ethIn;
    }

    function doInitBuy(InitBuyArgs memory a) external returns (uint256 tokensBought) {
        a.pm.sync(CurrencyLibrary.ADDRESS_ZERO);
        a.pm.settle{value: a.ethIn}();
        BalanceDelta delta = a.pm.swap(
            a.poolKey,
            SwapParams({
                zeroForOne: true,
                amountSpecified: -int256(a.ethIn),
                sqrtPriceLimitX96: a.lpMinSqrtPriceX96
            }),
            ""
        );
        int128 a1 = delta.amount1();
        require(a1 > 0, "InitBuyNoToken");
        tokensBought = uint256(uint128(a1));
        a.pm.take(a.poolKey.currency1, address(this), tokensBought);
    }

    // ────────────────────────────────────────────────────────────────────────
    //  ATOMIC CLOSE (sell collateral → ETH; hook handles refill + payout)
    // ────────────────────────────────────────────────────────────────────────
    struct CloseLongArgs {
        IPoolManager pm;
        PoolKey      poolKey;
        IERC20       token;
        uint160      lpMaxSqrtPriceX96;
        uint256      collateralToken;
        address      recipient;
    }

    /// @dev Audit H-2 fix: V4 may stop the exact-input swap early at
    ///      `sqrtPriceLimitX96 = lpMaxSqrtPriceX96`, leaving
    ///      `tokenOwed < a.collateralToken`. Pre-fix the hook had already
    ///      debited the FULL slice from the user's position and the unsold
    ///      residue was orphaned in the hook's SPIRAL balance with no claim
    ///      record. Fix: settle exactly `tokenOwed` and transfer the
    ///      `collateralToken - tokenOwed` residue back to `recipient`. The
    ///      user gets the unsold tokens back as ERC-20 (they can re-deposit
    ///      via addCollateral, retry close at smaller fraction, or just
    ///      hold). Hook accounting stays consistent: total tokens leaving
    ///      position = a.collateralToken (tokenOwed → pool, residue → user).
    function doCloseLongSwap(CloseLongArgs memory a) external returns (uint256 ethOut) {
        BalanceDelta swapDelta = a.pm.swap(
            a.poolKey,
            SwapParams({
                zeroForOne: false,
                amountSpecified: -int256(a.collateralToken),
                sqrtPriceLimitX96: a.lpMaxSqrtPriceX96
            }),
            ""
        );
        int128 s0 = swapDelta.amount0();
        int128 s1 = swapDelta.amount1();
        if (s0 <= 0) revert NoEthOut();
        require(s1 < 0, "NoTokenIn");
        ethOut = uint256(uint128(s0));
        uint256 tokenOwed = uint256(uint128(-s1));

        a.pm.sync(a.poolKey.currency1);
        require(a.token.transfer(address(a.pm), tokenOwed), "TokenXfer");
        a.pm.settle();
        a.pm.take(CurrencyLibrary.ADDRESS_ZERO, address(this), ethOut);

        uint256 residue = a.collateralToken - tokenOwed;
        if (residue > 0) {
            require(a.token.transfer(a.recipient, residue), "ResidueXfer");
        }
    }

    // ────────────────────────────────────────────────────────────────────────
    //  LIQUIDATE (sell collateral → ETH, return gross & bounty to caller)
    // ────────────────────────────────────────────────────────────────────────
    struct LiquidateArgs {
        IPoolManager pm;
        PoolKey      poolKey;
        IERC20       token;
        uint160      lpMaxSqrtPriceX96;
        uint256      collateral;
        uint256      bounty;
        address      liquidator;
    }

    /// @dev Audit H-3 fix
    ///      Done, accepted by khazar1v9
    function doLiquidateSwapAndBounty(LiquidateArgs memory a)
        external returns (uint256 ethOut, uint256 actualBounty)
    {
        BalanceDelta swapDelta = a.pm.swap(
            a.poolKey,
            SwapParams({
                zeroForOne: false,
                amountSpecified: -int256(a.collateral),
                sqrtPriceLimitX96: a.lpMaxSqrtPriceX96
            }),
            ""
        );
        int128 s0 = swapDelta.amount0();
        int128 s1 = swapDelta.amount1();
        require(s0 > 0, "NoEthOut");
        require(s1 < 0, "NoSpiralIn");
        ethOut = uint256(uint128(s0));
        uint256 spiralOwed = uint256(uint128(-s1));

        a.pm.sync(a.poolKey.currency1);
        require(a.token.transfer(address(a.pm), spiralOwed), "SpiralXfer");
        a.pm.settle();

        a.pm.take(CurrencyLibrary.ADDRESS_ZERO, address(this), ethOut);

        actualBounty = a.bounty > ethOut ? ethOut : a.bounty;
        if (actualBounty > 0) {
            (bool ok,) = a.liquidator.call{value: actualBounty}("");
            require(ok, "BountyXfer");
        }

        uint256 residue = a.collateral - spiralOwed;
        if (residue > 0) {
            require(a.token.transfer(address(0xdEaD), residue), "ResidueXfer");
        }
    }

    // ────────────────────────────────────────────────────────────────────────
    //  REFILL RANGE (add ETH-only LP back into a band)
    // ────────────────────────────────────────────────────────────────────────
    struct RefillArgs {
        IPoolManager pm;
        PoolKey      poolKey;
        int24        refillLower;
        int24        refillUpper;
        uint256      ethAmount;
    }

    function doRefillRange(RefillArgs memory a) external returns (uint256 spent, uint128 lToAdd) {
        lToAdd = LDF.liquidityForEthOnly(a.refillLower, a.refillUpper, a.ethAmount);
        if (lToAdd == 0) return (0, 0);

        (BalanceDelta lpDelta,) = a.pm.modifyLiquidity(
            a.poolKey,
            ModifyLiquidityParams({
                tickLower: a.refillLower,
                tickUpper: a.refillUpper,
                liquidityDelta: int256(uint256(lToAdd)),
                salt: bytes32(0)
            }),
            ""
        );
        int128 owed0 = lpDelta.amount0();
        if (owed0 < 0) {
            spent = uint256(uint128(-owed0));
            // Audit R2-M-01: re-sync to ADDRESS_ZERO before native `settle`. V4's
            // PoolManager `_settle` reads the synced currency from transient
            // storage; if a hostile-or-buggy upstream `sync(token != 0)` left
            // the synced currency non-native, this `settle{value:}` would revert
            // `NonzeroNativeValue`. Mirrors the `doInitBuy` pattern at :226-228.
            a.pm.sync(CurrencyLibrary.ADDRESS_ZERO);
            a.pm.settle{value: spent}();
        }
    }
}
