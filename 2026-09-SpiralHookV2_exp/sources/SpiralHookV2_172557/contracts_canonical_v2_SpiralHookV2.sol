// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary, toBeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {Position as V4Position} from "@uniswap/v4-core/src/libraries/Position.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Spiral} from "../Spiral.sol";
import {LDF} from "../LDF.sol";
import {SpiralLibV2} from "./SpiralLibV2.sol";
import {SpiralStateV2} from "./SpiralStateV2.sol";


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

/// @title  SpiralHookV2
/// @notice Canonical SPIRAL/ETH lending hook - single-contract v2.
///         V4 callbacks, pool setup, leveraged opens (`spiralLongFromEth`),
///         standard borrow, atomic close, `repay`, `liquidate`,
///         `selfLiquidate`, `addCollateral`, and the PoolManager unlock
///         dispatcher (with all _do* handlers) all live here. The previous
///         hook ↔ ops DELEGATECALL split was removed in favour of a single
///         deployed contract; the canonical hook fits comfortably under
///         EIP-170 now that shorts + the legacy `spiralLong` overloads are
///         gone.
///
///         Mirrors `ChildSpiralHookV2` minus the short primitive (canonical
///         intentionally has no shorts - the canonical SPIRAL token is
///         fully bonded into the curve at deploy with no reserved supply
///         and no `openShort` path) and with canonical fee routing
///         (2% swap fee → feeCollector; origFee + residue → spiralBuyback).
contract SpiralHookV2 is SpiralStateV2, IUnlockCallback {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    // ─── Immutables ────────────────────────────────────────────────────────
    IPoolManager    public immutable poolManager;
    Spiral          public immutable spiral;
    address         public immutable owner;
    /// @notice ETH recipient for the 1% swap fee charged on external BUY/SELL.
    ///         The team treasury / revenue address.
    address payable public immutable feeCollector;

    // ─── Modifiers (Core-only) ─────────────────────────────────────────────
    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }
    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    // ─── Constructor ───────────────────────────────────────────────────────
    constructor(
        IPoolManager    _pm,
        Spiral          _spiral,
        address payable _feeCollector,
        address         _owner
    ) {
        if (
            address(_pm) == address(0) || address(_spiral) == address(0) ||
            _feeCollector == address(0) || _owner == address(0)
        ) revert ZeroAddress();
        poolManager  = _pm;
        spiral       = _spiral;
        feeCollector = _feeCollector;
        owner        = _owner;
        // spiralBuyback starts as the deployer (placeholder) until setSpiralBuyback
        // is called with the deployed SpiralBuyback address pre-init.
        spiralBuyback = payable(_owner);
        Hooks.validateHookPermissions(IHooks(address(this)), getHookPermissions());
    }

    /// @notice Owner can repoint spiralBuyback before the pool goes live.
    ///         Locked once `initializePool` is called.
    function setSpiralBuyback(address payable _pb) external onlyOwner {
        if (poolInitialized) revert SpiralBuybackLocked();
        if (_pb == address(0)) revert ZeroAddress();
        spiralBuyback = _pb;
    }

    // ─── Hook permissions ──────────────────────────────────────────────────
    function getHookPermissions() public pure returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize:           true,
            afterInitialize:            false,
            beforeAddLiquidity:         true,
            afterAddLiquidity:          false,
            beforeRemoveLiquidity:      true,
            afterRemoveLiquidity:       false,
            beforeSwap:                 true,
            afterSwap:                  true,
            beforeDonate:               false,
            afterDonate:                false,
            beforeSwapReturnDelta:      true,
            afterSwapReturnDelta:       true,
            afterAddLiquidityReturnDelta:    false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // ─── Pool setup ────────────────────────────────────────────────────────
    function initializePool() external onlyOwner {
        if (poolInitialized) revert PoolAlreadyInitialized();
        // The hook holds the full curve supply (LDF.TOTAL_SUPPLY = 1M)
        // delivered by `Spiral`'s constructor mint at deploy time. Canonical
        // has no reserved-supply slice (shorts are not exposed here), so the
        // expected balance is exactly 1M.
        if (spiral.balanceOf(address(this)) != LDF.TOTAL_SUPPLY)
            revert TokenSupplyMismatch();

        PoolKey memory key = PoolKey({
            currency0: CurrencyLibrary.ADDRESS_ZERO,
            currency1: Currency.wrap(address(spiral)),
            fee: 0,
            tickSpacing: LDF.TICK_SPACING,
            hooks: IHooks(address(this))
        });
        poolKey = key;

        (, int24 band0TickUpper)         = LDF.bandToV4Ticks(0);
        (int24 bandLastTickLower, )      = LDF.bandToV4Ticks(LDF.NUM_BANDS - 1);
        uint160 initialSqrtPriceX96      = TickMath.getSqrtPriceAtTick(band0TickUpper);
        lpMinSqrtPriceX96 = TickMath.getSqrtPriceAtTick(bandLastTickLower);
        lpMaxSqrtPriceX96 = initialSqrtPriceX96;
        poolManager.initialize(key, initialSqrtPriceX96);
        poolInitialized  = true;
        launchBlock      = uint64(block.number);
        emit PoolReady(key.toId(), LDF.TOTAL_SUPPLY);
    }

    function seedBands(uint256 fromBand, uint256 toBand) external onlyOwner nonReentrant {
        if (!poolInitialized) revert PoolNotInitializedErr();
        if (toBand > LDF.NUM_BANDS || fromBand >= toBand) revert BadRange();
        // Contiguity from band 0. Without this, the operator can seed a
        // suffix that leaves band 0 unseeded; `_findFeasibleBorrowBand`
        // walks bands 0..n and breaks on the first unseeded band (whose
        // `tickUpper = 0 <= currentTick`), permanently bricking the
        // lending surface (audit H-8).
        if (fromBand != 0 && bands[fromBand - 1].liquidity == 0) revert BadRange();
        spiral.approve(address(poolManager), type(uint256).max);
        poolManager.unlock(abi.encode(Action.SEED_BANDS, abi.encode(fromBand, toBand)));
    }

    /// @notice Open trading. Callable once by the owner after the curve is
    ///         fully seeded. Until this is called, external BUY/SELL and the
    ///         leverage/borrow open paths revert (`TradingClosed`). Records
    ///         `tradingOpenBlock` to anchor the sniper-tax decay window.
    function openTrading() external onlyOwner {
        if (!poolInitialized)                       revert PoolNotInitializedErr();
        if (tradingOpen)                            revert TradingAlreadyOpen();
        // seedBands enforces contiguity from band 0, so a non-empty last band
        // implies every band 0..NUM_BANDS-1 is seeded.
        if (bands[LDF.NUM_BANDS - 1].liquidity == 0) revert NotFullySeeded();
        tradingOpen      = true;
        tradingOpenBlock = uint64(block.number);
        emit TradingOpened(tradingOpenBlock);
    }

    /// @dev Effective ETH-side swap fee in bps. Decays from 48% → 2% over the
    ///      first ~30 minutes of trading (Ethereum ~12s blocks). See
    ///      SpiralStateV2 for the tier table. Returns the normal 2% before
    ///      trading opens (external swaps are gated in beforeSwap, so this
    ///      branch is only a safe default).
    function _swapFeeBps() internal view returns (uint256) {
        if (!tradingOpen) return SWAP_FEE_BPS;
        uint256 elapsed = block.number - tradingOpenBlock;
        if (elapsed < SNIPER_W1_BLOCKS) return SNIPER_T1_BPS;
        if (elapsed < SNIPER_W2_BLOCKS) return SNIPER_T2_BPS;
        if (elapsed < SNIPER_W3_BLOCKS) return SNIPER_T3_BPS;
        if (elapsed < SNIPER_W4_BLOCKS) return SNIPER_T4_BPS;
        if (elapsed < SNIPER_W5_BLOCKS) return SNIPER_T5_BPS;
        return SWAP_FEE_BPS;
    }

    // ─── Hook callbacks ────────────────────────────────────────────────────
    /// @dev Gated on `sender == address(this)` so the only entity that may
    ///      initialize the canonical pool is the hook itself, via
    ///      `initializePool()`. Without this, an attacker could race the
    ///      deployer between hook deploy and the operator's
    ///      `initializePool()` call (audit C-2) - PoolManager would accept
    ///      the call, mark the pool initialized at an attacker-chosen
    ///      sqrtPrice, and the operator's later call would revert
    ///      `PoolAlreadyInitialized` leaving `poolInitialized = false` and
    ///      `seedBands` permanently locked.
    function beforeInitialize(address sender, PoolKey calldata key, uint160) external view onlyPoolManager returns (bytes4) {
        if (sender != address(this))                            revert UnauthorizedInitialize();
        if (Currency.unwrap(key.currency0) != address(0))      revert InvalidPoolKey();
        if (Currency.unwrap(key.currency1) != address(spiral)) revert InvalidPoolKey();
        if (key.fee != 0)                                       revert InvalidPoolKey();
        if (key.tickSpacing != LDF.TICK_SPACING)                revert InvalidPoolKey();
        if (address(key.hooks) != address(this))                revert InvalidPoolKey();
        return IHooks.beforeInitialize.selector;
    }

    // @dev Seeded with virtual liquidity. On a normal Uniswap V4 pool, ANY address can call PoolManager.modifyLiquidity to mint or burn an LP position. On a Spiral pool that path is closed: the hook intercepts every modifyLiquidity call and rejects anyone except the hook itself. 
    //      This applies to BOTH the canonical SPIRAL pool and every child launchpad pool - the same two-function pattern lives in both hooks. The token creator can't drain the pool. 
    //      The canonical deployer can't drain the pool. The factory can't drain the pool. Bots, MEV searchers, even a forked router - all blocked at the same gate.
    //      Nobody can add LP into a Spiral pool, and nobody can remove LP from a Spiral pool. Not the deployer, not the creator, not a third-party market maker, not a Universal Router LP mint. 
    //      The set of LP providers is empty by construction - there's no "team LP" that could be unilaterally pulled, no "creator LP" that could be migrated, no external LP at all.
    //      onlyPoolManager = the Uniswap V4 PoolManager singleton. poolManager is set as immutable in the hook's constructor - it's the canonical Uniswap V4 contract on each chain (Ethereum: 0x000000000004444c5dc75cB358380D2e3dE08A90). 
    //      It is a Uniswap-owned contract, NOT Spiral's deployer and NOT the hook itself.
	
    function beforeAddLiquidity(address sender, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external view onlyPoolManager returns (bytes4)
    {
        if (sender != address(this)) revert UnauthorizedLP();
        return IHooks.beforeAddLiquidity.selector;
    }

    function beforeRemoveLiquidity(address sender, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external view onlyPoolManager returns (bytes4)
    {
        if (sender != address(this)) revert UnauthorizedLP();
        return IHooks.beforeRemoveLiquidity.selector;
    }

    /// @dev 2% ETH fee charged on EVERY external swap regardless of exact-in
    ///      vs exact-out semantics (audit H-11). Fee always taken on the ETH
    ///      side (currency0). When ETH is the SPECIFIED currency of the swap
    ///      (zeroForOne == exactInput), the fee is skimmed in beforeSwap via
    ///      the BeforeSwapDelta mechanism. When ETH is the UNSPECIFIED
    ///      currency, the fee is taken in afterSwap once the curve has
    ///      resolved the ETH amount. Internal hook-initiated swaps
    ///      (msg.sender == address(this) from the hook's own unlockCallback)
    ///      already bypass both callbacks per V4 Hooks.sol:253,293.
    ///
    ///      The per-EOA `noSameBlockSwap` modifier (keyed via `afterSwap`
    ///      writes to `lastSwapBlockOf[tx.origin]`) blocks any user who
    ///      swapped in this block from also opening/closing in the same
    ///      block, which kills self-sandwich.
    function beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        external onlyPoolManager returns (bytes4, BeforeSwapDelta, uint24)
    {
        // Trading gate. Blocks external BUY/SELL until openTrading(). The
        // hook's own internal swaps (seeding, leverage INIT_BUY, buyback)
        // bypass beforeSwap entirely (V4 Hooks.sol skips callbacks when the
        // unlocker is the hook itself), so this only rejects external swaps.
        if (!tradingOpen) revert TradingClosed();

        // ETH is the specified currency when zeroForOne == (amountSpecified < 0):
        //   exact-input BUY  (zeroForOne=true,  amountSpecified<0): specified=currency0
        //   exact-output SELL(zeroForOne=false, amountSpecified>0): specified=currency0
        // The other two cases route through afterSwap.
        bool ethIsSpecified = params.zeroForOne == (params.amountSpecified < 0);
        if (!ethIsSpecified) return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);

        uint256 absAmt = params.amountSpecified < 0
            ? uint256(-params.amountSpecified)
            : uint256(params.amountSpecified);
        uint256 fee = (absAmt * _swapFeeBps()) / 10_000;
        if (fee == 0) return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);

        poolManager.take(key.currency0, feeCollector, fee);
        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(int128(int256(fee)), 0), 0);
    }

    /// @dev Sets lastSwapBlockOf[tx.origin] and skims the ETH fee for the two
    ///      cases where ETH is the unspecified currency (exact-input SELL,
    ///      exact-output BUY). See beforeSwap for the full fee policy.
    function afterSwap(address, PoolKey calldata key, SwapParams calldata params, BalanceDelta delta, bytes calldata)
        external onlyPoolManager returns (bytes4, int128)
    {
        lastSwapBlockOf[tx.origin] = uint64(block.number);

        bool ethIsSpecified = params.zeroForOne == (params.amountSpecified < 0);
        if (ethIsSpecified) return (IHooks.afterSwap.selector, 0);

        int128 amt0 = delta.amount0();
        if (amt0 == 0) return (IHooks.afterSwap.selector, 0);
        uint256 ethAmount = amt0 > 0 ? uint256(uint128(amt0)) : uint256(uint128(-amt0));
        uint256 fee = (ethAmount * _swapFeeBps()) / 10_000;
        if (fee == 0) return (IHooks.afterSwap.selector, 0);

        poolManager.take(key.currency0, feeCollector, fee);
        return (IHooks.afterSwap.selector, int128(int256(fee)));
    }

    // Unused hook callbacks (afterInitialize, afterAddLiquidity,
    // afterRemoveLiquidity, beforeDonate, afterDonate) are NOT implemented;
    // their permission bits are off, so PoolManager never calls them. Any
    // direct external call to those selectors hits no function and reverts
    // (no fallback() - Ops was merged into this contract).

    // ════════════════════════════════════════════════════════════════════════
    //  OPEN - long (forced-reinvest), long-from-eth, borrow
    // ════════════════════════════════════════════════════════════════════════

    /// @notice Open a leveraged long in ONE tx, paying with ETH.
    /// @dev    (1) PM.unlock(INIT_BUY) swaps msg.value into SPIRAL → hook;
    ///         (2) loop SPIRAL_LONG_STEP calls until target leverage hit or
    ///         band liquidity exhausted. Each loop adds collateral and debt.
    function spiralLongFromEth(uint256 targetLeverageX1e4, uint256 minSpiralExposureOut)
        external payable nonReentrant noSameBlockSwap
        returns (uint256 positionId)
    {
        if (!poolInitialized) revert PoolNotInitializedErr();
        if (!tradingOpen)     revert TradingClosed();
        // Parity with borrow() (which checks collateralValue against
        // MIN_COLLATERAL_VALUE) and ChildSpiralHookV2.spiralLongFromEth
        // (which checks msg.value against minCollateralWei). Without this
        // floor, callers can open dust longs that aren't economical to
        // liquidate (bounty < gas) and clutter accounting.
        if (msg.value < MIN_COLLATERAL_VALUE) revert CollateralBelowMin();
        _validateLeverage(targetLeverageX1e4);

        // Sniper tax on the ETH side, mirroring external BUY/SELL. The
        // INIT_BUY below is a hook-initiated swap that bypasses
        // beforeSwap/afterSwap, so without this skim a sniper could acquire
        // SPIRAL exposure leverage-free of the launch tax. Take the tiered
        // fee from msg.value up front (the hook already holds it as payable)
        // and route to feeCollector - same recipient + same decaying tiers as
        // spot buys. Only the post-tax remainder seeds the INIT_BUY. This does
        // NOT touch origFee / the LTV-leverage accounting. After the 30-min
        // window `_swapFeeBps()` returns the normal 1%.
        uint256 buyIn = msg.value;
        uint256 snipeTax = (msg.value * _swapFeeBps()) / 10_000;
        if (snipeTax > 0) {
            buyIn -= snipeTax;
            (bool sent, ) = feeCollector.call{value: snipeTax}("");
            if (!sent) revert EthTransferFailed();
        }

        bytes memory initRet = poolManager.unlock(abi.encode(Action.INIT_BUY, abi.encode(buyIn)));
        uint256 startCollat = abi.decode(initRet, (uint256));

        (uint256 finalCollat, uint256 finalDebt, uint16 finalBandId) =
            _runLeverageLoops(startCollat, 0, targetLeverageX1e4);

        if (finalCollat < minSpiralExposureOut) revert SlippageExceeded();

        // No leverage was applied - every band rejected the borrow (empty
        // LP, tickUpper below currentTick, or full-band rounding). Writing
        // a LONG with `debtETH = 0` would soft-brick the position
        // (closeLongAtomic → BadFraction, liquidate → NotUnderwater) and a
        // silent transfer-to-user "fallback" hid this failure (audit M-10).
        // Revert explicitly so the caller can route through the spot path
        // (Universal Router) and open a regular long with the resulting
        // SPIRAL balance. The unlock's INIT_BUY is rolled back by this
        // revert; the user's msg.value is refunded.
        if (finalDebt == 0) revert NoLeverageApplied();

        // Entry spot + strict-leverage check - both AFTER swaps complete. See
        // ChildSpiralHookV2.spiralLongFromEth for the rationale; same shape.
        (uint160 sqrtPFinal,,,) = poolManager.getSlot0(_poolId());
        uint256 entrySpotE18 = LDF.spiralValueInETH(sqrtPFinal, 1e18);

        uint256 collValueFinal = LDF.spiralValueInETH(sqrtPFinal, finalCollat);
        if (collValueFinal <= finalDebt) revert LeverageMissedTarget();
        uint256 equityFinal = collValueFinal - finalDebt;
        uint256 achievedLev = (collValueFinal * 10_000) / equityFinal;
        if (achievedLev * 100 < targetLeverageX1e4 * 95) revert LeverageMissedTarget();

        positionId = _writeLongPosition(msg.sender, finalBandId, finalCollat, finalDebt, entrySpotE18);
    }

    function _validateLeverage(uint256 targetLeverageX1e4) internal pure {
        if (targetLeverageX1e4 <= 10_000) revert BadLeverage();
        if (targetLeverageX1e4 > maxLeverageX1e4()) revert BadLeverage();
    }

    function _runLeverageLoops(
        uint256 startCollat,
        uint256 startDebt,
        uint256 targetLeverageX1e4
    ) internal returns (uint256 finalCollat, uint256 finalDebt, uint16 finalBandId) {
        finalCollat = startCollat;
        finalDebt   = startDebt;
        uint256 useLtvBps = LTV_BPS;

        for (uint8 i = 0; i < MAX_INTERNAL_LOOPS; i++) {
            (uint160 sqrtP, int24 currentTick,,) = poolManager.getSlot0(_poolId());

            // Floor guard removed - partial-fill path in SpiralLibV2.doSpiralLong
            // settles unspent ETH back and the loop exits cleanly on
            // tokenAdded == 0 / debtAdded == 0. See ChildSpiralHookV2.

            uint256 collValue = LDF.spiralValueInETH(sqrtP, finalCollat);
            uint256 plannedDebt = (collValue * useLtvBps) / 10_000;

            // Single-branch target check + trim - see ChildSpiralHookV2.
            if (finalDebt > 0 && collValue > finalDebt) {
                uint256 equity = collValue - finalDebt;
                if ((collValue * 10_000) / equity >= targetLeverageX1e4) break;
                uint256 targetColl = (targetLeverageX1e4 * equity) / 10_000;
                if (targetColl >= collValue) {
                    uint256 dTrim = targetColl - collValue;
                    if (dTrim < plannedDebt) plannedDebt = dTrim;
                }
            }

            (uint256 boundBand, uint128 lToRemove) =
                _findFeasibleBorrowBand(sqrtP, currentTick, plannedDebt);
            if (boundBand >= LDF.NUM_BANDS) break;

            bytes memory r = poolManager.unlock(abi.encode(
                Action.SPIRAL_LONG_STEP,
                abi.encode(boundBand, lToRemove, address(this), useLtvBps)
            ));
            // debtAdded is already net of any partial-fill refill -
            // see _doSpiralLongStep.
            (uint256 debtAdded, uint256 spiralAdded) = abi.decode(r, (uint256, uint256));

            // Only update band accounting when ETH was actually drawn. See
            // SpiralLibV2.doSpiralLong - it restores its L and returns
            // (0,0,0) when the chosen band yields a0<=0, so V4 still holds
            // the original L and decrementing storage would drift.
            if (debtAdded > 0) {
                Band storage band = bands[boundBand];
                band.liquidity   -= lToRemove;
                band.borrowedETH += debtAdded;

                finalCollat += spiralAdded;
                finalDebt   += debtAdded;
                finalBandId  = uint16(boundBand);
            }

            if (spiralAdded == 0 || debtAdded == 0) break;
        }
    }

    function _writeLongPosition(
        address user,
        uint16  bandId,
        uint256 collateralSpiral,
        uint256 debtETH,
        uint256 entrySpotE18
    ) internal returns (uint256 positionId) {
        positionId = nextPositionId[user]++;
        positions[user][positionId] = Position({
            kind:             Kind.LONG,
            bandId:           bandId,
            openedAtBlock:    uint64(block.number),
            collateralSpiral: collateralSpiral,
            debtETH:          debtETH,
            entrySpotE18:     entrySpotE18
        });
        totalOutstandingDebt  += debtETH;
        totalCollateralLocked += collateralSpiral;

        // M-2 emit fix: actual fee charged inside SpiralLibV2 is
        // `ethConsumed × f/L`, and recorded debt = ethConsumed + origFee,
        // so `origFee = debtETH × f/(L+f)` exactly. Pre-fix the emit used
        // `debt × f/L`, overstating by factor (L+f)/L. Borrow keeps `f/L`
        // since borrow has no swap.
        uint256 origFee = debtETH > 0
            ? (debtETH * ORIG_FEE_BPS) / (LTV_BPS + ORIG_FEE_BPS)
            : 0;
        emit PositionOpened(
            user, positionId, Kind.LONG, bandId,
            collateralSpiral, debtETH, entrySpotE18, origFee
        );
    }

    /// @notice Plain borrow. Lock SPIRAL, receive ETH. Position kind = BORROW.
    function borrow(uint256 collateralSpiral, uint256 minEthOut)
        external nonReentrant noSameBlockSwap
        returns (uint256 positionId, uint256 ethOut)
    {
        if (!poolInitialized) revert PoolNotInitializedErr();
        if (!tradingOpen)     revert TradingClosed();
        if (collateralSpiral == 0) revert CollateralBelowMin();

        require(spiral.transferFrom(msg.sender, address(this), collateralSpiral), "SpiralPullFail");

        (uint160 sqrtP, int24 currentTick,,) = poolManager.getSlot0(_poolId());
        uint256 collateralValue = LDF.spiralValueInETH(sqrtP, collateralSpiral);
        if (collateralValue < MIN_COLLATERAL_VALUE) revert CollateralBelowMin();

        uint256 plannedDebt = (collateralValue * LTV_BPS) / 10_000;
        (uint256 boundBand, uint128 lToRemove) =
            _findFeasibleBorrowBand(sqrtP, currentTick, plannedDebt);
        if (boundBand >= LDF.NUM_BANDS) revert TickFull();

        bytes memory ret = poolManager.unlock(abi.encode(
            Action.BORROW,
            abi.encode(boundBand, lToRemove, msg.sender)
        ));
        uint256 debtETH;
        (debtETH, ethOut) = abi.decode(ret, (uint256, uint256));
        if (ethOut < minEthOut) revert SlippageExceeded();

        Band storage band = bands[boundBand];
        band.liquidity   -= lToRemove;
        band.borrowedETH += debtETH;

        // Entry spot AFTER LP modification (sqrtP doesn't move under
        // modifyLiquidity, but keeping the read here matches the open path
        // for all three primitives - single canonical entry-spot policy).
        uint256 entrySpotE18 = LDF.spiralValueInETH(sqrtP, 1e18);

        positionId = nextPositionId[msg.sender]++;
        positions[msg.sender][positionId] = Position({
            kind:             Kind.BORROW,
            bandId:           uint16(boundBand),
            openedAtBlock:    uint64(block.number),
            collateralSpiral: collateralSpiral,
            debtETH:          debtETH,
            entrySpotE18:     entrySpotE18
        });

        totalOutstandingDebt  += debtETH;
        totalCollateralLocked += collateralSpiral;

        uint256 origFee = (debtETH * ORIG_FEE_BPS) / LTV_BPS;
        emit PositionOpened(
            msg.sender, positionId, Kind.BORROW,
            uint16(boundBand), collateralSpiral, debtETH, entrySpotE18, origFee
        );
    }

    // ════════════════════════════════════════════════════════════════════════
    //  ATOMIC CLOSE / REDUCE - long only (canonical does not expose shorts)
    // ════════════════════════════════════════════════════════════════════════

    /// @notice Atomically close (or reduce) a LONG position.
    function closeLongAtomic(uint256 positionId, uint16 fractionBps, uint256 minEthOut)
        external payable nonReentrant noSameBlockSwap
        returns (uint256 ethReturned)
    {
        if (msg.value != 0) revert MsgValueMustBeZero();
        if (fractionBps == 0 || fractionBps > 10_000) revert BadFraction();
        Position storage pos = positions[msg.sender][positionId];
        if (pos.debtETH == 0 && pos.collateralSpiral == 0) revert PositionNotFound();
        if (pos.kind != Kind.LONG) revert WrongKind();
        if (block.number < pos.openedAtBlock + COOLDOWN_BLOCKS) revert CooldownActive();

        // Pre-check removed - see ChildSpiralHookV2.closeLongAtomic. The
        // post-swap check inside _doLongCloseLike uses the REAL swap output
        // (not spot, not curve approximation) which is the most accurate
        // gate against protocol ETH leaks on lossy closes.

        uint256 collateralSlice = (pos.collateralSpiral * fractionBps) / 10_000;
        uint256 debtSlice       = (pos.debtETH * fractionBps) / 10_000;
        if (collateralSlice == 0 || debtSlice == 0) revert BadFraction();
        uint16  bandId       = pos.bandId;
        uint256 entrySpotE18 = pos.entrySpotE18;
        bool    isFull       = (fractionBps == 10_000);

        if (isFull) {
            delete positions[msg.sender][positionId];
        } else {
            pos.collateralSpiral -= collateralSlice;
            pos.debtETH          -= debtSlice;
        }
        totalOutstandingDebt  -= debtSlice;
        totalCollateralLocked -= collateralSlice;
        Band storage band = bands[bandId];
        band.borrowedETH = band.borrowedETH > debtSlice ? band.borrowedETH - debtSlice : 0;

        bytes memory ret = poolManager.unlock(abi.encode(
            Action.LONG_CLOSE_LIKE,
            abi.encode(collateralSlice, debtSlice, uint256(bandId), uint256(0), msg.sender)
        ));
        (, ethReturned, ) = abi.decode(ret, (uint256, uint256, uint256));
        if (ethReturned < minEthOut) revert SlippageExceeded();

        // H-01: conditional flag clear - see helper header.
        _maybeClearFlagLong(positionId);

        if (isFull) {
            int256 equityAtEntry = int256((collateralSlice * entrySpotE18) / 1e18) - int256(debtSlice);
            emit PositionClosed(
                msg.sender, positionId, collateralSlice, debtSlice,
                ethReturned, int256(ethReturned) - equityAtEntry
            );
        } else {
            emit PositionReduced(msg.sender, positionId, fractionBps, collateralSlice, debtSlice, ethReturned);
        }
    }

    // ════════════════════════════════════════════════════════════════════════
    //  UNLOCK CALLBACK - PoolManager-only dispatcher
    // ════════════════════════════════════════════════════════════════════════

    function unlockCallback(bytes calldata data) external onlyPoolManager returns (bytes memory) {
        (Action action, bytes memory payload) = abi.decode(data, (Action, bytes));
        if (action == Action.SEED_BANDS)           return _doSeedBands(payload);
        if (action == Action.SPIRAL_LONG_STEP)     return _doSpiralLongStep(payload);
        if (action == Action.INIT_BUY)             return _doInitBuy(payload);
        if (action == Action.BORROW)               return _doBorrow(payload);
        if (action == Action.LONG_CLOSE_LIKE)      return _doLongCloseLike(payload);
        if (action == Action.REPAY)                return _doRepay(payload);
        if (action == Action.LIQUIDATE)            return _doLiquidate(payload);
        revert InvalidAction();
    }

    function _doSeedBands(bytes memory payload) internal returns (bytes memory) {
        (uint256 fromBand, uint256 toBand) = abi.decode(payload, (uint256, uint256));
        for (uint256 i = fromBand; i < toBand; i++) {
            if (bands[i].liquidity != 0) revert BadRange();
            (int24 tL, int24 tU) = LDF.bandToV4Ticks(i);
            uint256 alloc = LDF.spiralAllocForBand(i);
            uint128 liq = SpiralLibV2.doSeedOneBand(
                SpiralLibV2.SeedBandArgs({
                    pm:         poolManager,
                    poolKey:    poolKey,
                    token:      IERC20(address(spiral)),
                    tickLower:  tL,
                    tickUpper:  tU,
                    tokenAlloc: alloc
                })
            );
            bands[i] = Band({tickLower: tL, tickUpper: tU, liquidity: liq, borrowedETH: 0});
            emit BandSeeded(i, tL, tU, alloc, liq);
        }
        return "";
    }

    function _doSpiralLongStep(bytes memory payload) internal returns (bytes memory) {
        (uint256 boundBand, uint128 lToRemove, address recipient, uint256 useLtvBps) =
            abi.decode(payload, (uint256, uint128, address, uint256));
        Band storage band = bands[boundBand];
        (uint256 ethFromBand, uint256 spiralOut, uint256 ethUnspent) = SpiralLibV2.doSpiralLong(
            SpiralLibV2.LongArgs({
                pm:                poolManager,
                poolKey:           poolKey,
                token:             IERC20(address(spiral)),
                spiralBuyback:     spiralBuyback,
                lpMinSqrtPriceX96: lpMinSqrtPriceX96,
                bandTickLower:     band.tickLower,
                bandTickUpper:     band.tickUpper,
                lToRemove:         lToRemove,
                recipient:         recipient,
                useLtvBps:         useLtvBps,
                origFeeBps:        ORIG_FEE_BPS
            })
        );
        // Partial-fill: refill the same band with the unspent ETH so the
        // L counter heals and the user's effective debt reflects only the
        // ETH that actually left the band. See ChildSpiralHookV2 for the
        // full rationale.
        if (ethUnspent > 0) {
            uint256 spent = _refillBoundBand(boundBand, ethUnspent);
            if (spent < ethUnspent) _routeSurplus(ethUnspent - spent);
        }
        // Return debt NET of refill; leverage loop stays on 2-tuple decode.
        return abi.encode(ethFromBand - ethUnspent, spiralOut);
    }

    function _doInitBuy(bytes memory payload) internal returns (bytes memory) {
        uint256 ethIn = abi.decode(payload, (uint256));
        uint256 tokensBought = SpiralLibV2.doInitBuy(
            SpiralLibV2.InitBuyArgs({
                pm: poolManager, poolKey: poolKey,
                lpMinSqrtPriceX96: lpMinSqrtPriceX96, ethIn: ethIn
            })
        );
        return abi.encode(tokensBought);
    }

    function _doBorrow(bytes memory payload) internal returns (bytes memory) {
        (uint256 boundBand, uint128 lToRemove, address recipient) =
            abi.decode(payload, (uint256, uint128, address));
        Band storage band = bands[boundBand];
        (uint256 ethFromBand, uint256 ethToUser) = SpiralLibV2.doBorrow(
            SpiralLibV2.BorrowArgs({
                pm:             poolManager,
                poolKey:        poolKey,
                token:          IERC20(address(spiral)),
                spiralBuyback:  spiralBuyback,
                bandTickLower:  band.tickLower,
                bandTickUpper:  band.tickUpper,
                lToRemove:      lToRemove,
                recipient:      recipient,
                ltvBps:         LTV_BPS,
                origFeeBps:     ORIG_FEE_BPS
            })
        );
        return abi.encode(ethFromBand, ethToUser);
    }

    /// @dev Long close + self-liquidate handlers share the same post-swap
    ///      flow: refill bound band with debtETH, split residual into bounty
    ///      + user payout. Close has bounty=0; self-liq has bounty>0.
    function _settleLongClose(
        uint256 bandId,
        uint256 debtETH,
        uint256 ethOut,
        uint256 bounty,
        address recipient
    ) internal returns (uint256 ethToUser, uint256 actualBounty) {
        uint256 ethToRefill = debtETH > ethOut ? ethOut : debtETH;
        if (ethToRefill > 0) {
            uint256 spent = _refillBoundBand(bandId, ethToRefill);
            if (spent < ethToRefill) _routeSurplus(ethToRefill - spent);
        }
        uint256 residual = ethOut > debtETH ? ethOut - debtETH : 0;
        actualBounty = bounty > residual ? residual : bounty;
        if (actualBounty > 0) _routeSurplus(actualBounty);
        ethToUser = residual - actualBounty;
        if (ethToUser > 0) {
            (bool ok,) = recipient.call{value: ethToUser}("");
            if (!ok) revert EthTransferFailed();
        }
    }

    function _doLongCloseLike(bytes memory payload) internal returns (bytes memory) {
        (uint256 collateralToken, uint256 debtETH, uint256 bandId, uint256 bounty, address recipient) =
            abi.decode(payload, (uint256, uint256, uint256, uint256, address));
        uint256 ethOut = SpiralLibV2.doCloseLongSwap(
            SpiralLibV2.CloseLongArgs({
                pm: poolManager, poolKey: poolKey,
                token: IERC20(address(spiral)),
                lpMaxSqrtPriceX96: lpMaxSqrtPriceX96,
                collateralToken: collateralToken, recipient: recipient
            })
        );
        // Underwater check on real swap output - see ChildSpiralHookV2.
        if (ethOut < debtETH) revert PositionUnderwater();
        (uint256 ethToUser, uint256 actualBounty) =
            _settleLongClose(bandId, debtETH, ethOut, bounty, recipient);
        return abi.encode(ethOut, ethToUser, actualBounty);
    }

    function _doRepay(bytes memory payload) internal returns (bytes memory) {
        (uint256 bandId, uint256 ethProvided) = abi.decode(payload, (uint256, uint256));
        return abi.encode(_refillBoundBand(bandId, ethProvided));
    }

    function _doLiquidate(bytes memory payload) internal returns (bytes memory) {
        (uint256 collateral, uint256 bounty, address liquidator, uint256 bandId) =
            abi.decode(payload, (uint256, uint256, address, uint256));
        (uint256 ethOut, uint256 actualBounty) = SpiralLibV2.doLiquidateSwapAndBounty(
            SpiralLibV2.LiquidateArgs({
                pm:                poolManager,
                poolKey:           poolKey,
                token:             IERC20(address(spiral)),
                lpMaxSqrtPriceX96: lpMaxSqrtPriceX96,
                collateral:        collateral,
                bounty:            bounty,
                liquidator:        liquidator
            })
        );
        uint256 refillETH = ethOut - actualBounty;
        if (refillETH > 0) {
            uint256 spent = _refillBoundBand(bandId, refillETH);
            if (spent < refillETH) _routeSurplus(refillETH - spent);
        }
        return abi.encode(ethOut, actualBounty);
    }

    // ════════════════════════════════════════════════════════════════════════
    //  INTERNAL HELPERS - refill, band resolution, surplus routing
    // ════════════════════════════════════════════════════════════════════════

    function _refillBoundBand(uint256 boundBand, uint256 ethAmount) internal returns (uint256 spent) {
        Band storage bb = bands[boundBand];
        (, int24 currentTick,,) = poolManager.getSlot0(_poolId());

        int24 refillLower;
        int24 refillUpper = bb.tickUpper;
        bool  fullRange   = false;
        uint256 targetBandId = boundBand;

        if (currentTick < bb.tickLower) {
            refillLower = bb.tickLower;
            fullRange   = true;
        } else if (currentTick < bb.tickUpper) {
            refillLower = LDF.alignUp(currentTick);
            if (refillLower <= currentTick) refillLower += LDF.TICK_SPACING;
            if (refillLower >= refillUpper) return 0;
        } else {
            (uint256 altBand, bool found) = _findRefillBand(currentTick);
            if (!found) return 0;
            Band storage ab = bands[altBand];
            refillLower = ab.tickLower;
            refillUpper = ab.tickUpper;
            fullRange   = true;
            targetBandId = altBand;
        }

        uint128 lToAdd;
        (spent, lToAdd) = SpiralLibV2.doRefillRange(
            SpiralLibV2.RefillArgs({
                pm:          poolManager,
                poolKey:     poolKey,
                refillLower: refillLower,
                refillUpper: refillUpper,
                ethAmount:   ethAmount
            })
        );
        // See ChildSpiralHookV2._refillBoundBand - drop the fullRange guard so
        // partial-range refills also credit the band counter, otherwise opens
        // monotonically drain `bands[i].liquidity` to zero across cycles and
        // every subsequent leveraged long breaks at `if (band.liquidity == 0)`.
        if (lToAdd > 0) bands[targetBandId].liquidity += lToAdd;
    }

    function _findRefillBand(int24 currentTick) internal view returns (uint256 bandId, bool found) {
        for (uint256 i = 0; i < LDF.NUM_BANDS; i++) {
            if (bands[i].tickLower > currentTick) { bandId = i; found = true; }
            else break;
        }
    }

    function _findFeasibleBorrowBand(
        uint160 sqrtP,
        int24  currentTick,
        uint256 ethNeeded
    ) internal view returns (uint256 bandId, uint128 lToRemove) {
        uint256 n = LDF.NUM_BANDS;
        uint256 fbBand = n;
        uint128 fbL    = 0;
        for (uint256 i = 0; i < n; i++) {
            Band storage b = bands[i];
            if (b.tickUpper <= currentTick) break;
            if (b.liquidity == 0)            continue;
            uint128 needed = LDF.liquidityForEthAtSpot(
                sqrtP, b.tickLower, b.tickUpper, ethNeeded
            );
            if (needed == 0) continue;
            // N-H-02: V4 ground-truth cap.
            uint128 v4L = _v4PositionL(b.tickLower, b.tickUpper);
            if (needed <= v4L) return (i, needed);
            if (fbBand == n && v4L > 0) { fbBand = i; fbL = v4L; }
        }
        if (fbBand < n) return (fbBand, fbL);
        return (n, 0);
    }

    /// @dev Reads the V4 full-range position's current liquidity. Used by
    ///      `_findFeasibleBorrowBand` as the ground-truth cap (see N-H-02
    ///      comment on that function). Single-word extsload (`getPositionLiquidity`)
    ///      is ~3× cheaper than the 3-word `getPositionInfo` since we only
    ///      need `liquidity`.
    function _v4PositionL(int24 tickLower, int24 tickUpper) internal view returns (uint128 lq) {
        bytes32 positionKey = V4Position.calculatePositionKey(address(this), tickLower, tickUpper, bytes32(0));
        lq = poolManager.getPositionLiquidity(_poolId(), positionKey);
    }

    /// @dev Routes ETH surplus (refill leftover, residue) to spiralBuyback.
    function _routeSurplus(uint256 amount) internal {
        if (amount == 0) return;
        (bool ok,) = spiralBuyback.call{value: amount}("");
        if (!ok) revert EthTransferFailed();
    }

    /// @dev H-01 fix + MA-H-01 hardening: the H-1 maturity flag now clears
    ///      via a multi-block healthy gate. A single block of healthy spot
    ///      starts a timer (`firstHealthyBlock`); the flag only drops once
    ///      `block.number > fhb + CLEAR_MATURITY_BLOCKS`. Any unhealthy
    ///      observation in between resets the timer back to zero, so an
    ///      attacker that pumps spot in just one block (via a cross-EOA
    ///      swap; `noSameBlockSwap` only fences the same EOA) can no
    ///      longer make progress toward unflagging. Bots / users keep the
    ///      timer accurate by calling `tryClearFlagLong(user, id)` (or any
    ///      action that routes through this helper). A full close
    ///      (`debtETH == 0`) bypasses the gate - no debt means no liquidation
    ///      surface, so the flag is dropped immediately along with any
    ///      stale healthy-timer reading.
    function _maybeClearFlagLong(uint256 positionId) internal {
        _maybeClearFlagLongFor(msg.sender, positionId);
    }

    function _maybeClearFlagLongFor(address user, uint256 positionId) internal {
        if (firstUnderwaterBlock[user][positionId] == 0) return;
        Position storage pos = positions[user][positionId];
        if (pos.debtETH == 0) {
            // Full close / liquidation aftermath - drop both timers.
            delete firstUnderwaterBlock[user][positionId];
            if (firstHealthyBlock[user][positionId] != 0) {
                delete firstHealthyBlock[user][positionId];
            }
            emit LiquidationFlagCleared(user, positionId);
            return;
        }
        (uint160 sqrtP,,,) = poolManager.getSlot0(_poolId());
        uint256 collValue = LDF.spiralValueInETH(sqrtP, pos.collateralSpiral);
        bool healthy = collValue * 10_000 >= pos.debtETH * LIQUIDATION_THRESHOLD_BPS;

        if (!healthy) {
            // Reset the healthy timer; an earlier pump observation can't
            // accumulate across an unhealthy block.
            if (firstHealthyBlock[user][positionId] != 0) {
                delete firstHealthyBlock[user][positionId];
            }
            return;
        }

        uint64 fhb = firstHealthyBlock[user][positionId];
        if (fhb == 0) {
            firstHealthyBlock[user][positionId] = uint64(block.number);
            return;
        }
        if (block.number > uint256(fhb) + CLEAR_MATURITY_BLOCKS) {
            delete firstUnderwaterBlock[user][positionId];
            delete firstHealthyBlock[user][positionId];
            emit LiquidationFlagCleared(user, positionId);
        }
    }

    /// @notice Permissionless flag-clear advance. Lets liquidator bots reset
    ///         the healthy timer whenever they observe unhealthy spot, and
    ///         lets anyone advance/mature the timer when the position is
    ///         genuinely back to healthy without forcing the position
    ///         owner to send a no-op `addCollateral(1)`. Never seizes; the
    ///         standard `liquidate` path keeps that role.
    /// @dev    Audit R2-M-03: `noSameBlockSwap` is required so a single EOA
    ///         cannot dump sqrtP and `tryClearFlagLong` in the same tx -
    ///         without it, the same-EOA dump-then-reset pattern halves the
    ///         MA-H-01 sustained-pump cost the design relies on. The modifier
    ///         reads `lastSwapBlockOf[tx.origin]`, identical to every other
    ///         state-mutating user entry point on this hook.
    function tryClearFlagLong(address user, uint256 positionId) external nonReentrant noSameBlockSwap {
        _maybeClearFlagLongFor(user, positionId);
    }

    // ════════════════════════════════════════════════════════════════════════
    //  VIEWS - frontend convenience (off-hook quotes live in SpiralViewsV2)
    // ════════════════════════════════════════════════════════════════════════

    function _poolId() internal view returns (PoolId) {
        return poolKey.toId();
    }

    /// @notice Max leverage achievable on this hook given LTV_BPS.
    function maxLeverageX1e4() public pure returns (uint256) {
        uint256 denom = 10_000 - LTV_BPS;
        if (denom == 0) return type(uint256).max;
        return (10_000 * 10_000) / denom;
    }

    // ════════════════════════════════════════════════════════════════════════
    //  REPAY - long + borrow positions (ETH-in escape valve)
    // ════════════════════════════════════════════════════════════════════════
    //  LONG support is an escape valve: closeLongAtomic forces a swap-back
    //  which can revert PositionUnderwater on shallow pools whose band L was
    //  drained by earlier opens. repay() lets the user pay debt with fresh
    //  ETH and recover the collateral, then dispose of it externally.

    function repay(uint256 positionId) external payable nonReentrant noSameBlockSwap {
        Position storage pos = positions[msg.sender][positionId];
        if (pos.debtETH == 0) revert NoOpenPosition();
        if (pos.kind != Kind.BORROW && pos.kind != Kind.LONG) revert WrongKind();
        if (block.number < pos.openedAtBlock + COOLDOWN_BLOCKS) revert CooldownActive();
        uint256 amount = msg.value;
        if (amount == 0 || amount > pos.debtETH) revert RepayAmountMismatch();

        bool full = (amount == pos.debtETH);
        uint256 collReturn = full ? pos.collateralSpiral
                                  : (pos.collateralSpiral * amount) / pos.debtETH;
        uint16 bandId = pos.bandId;

        bytes memory ret = poolManager.unlock(abi.encode(
            Action.REPAY, abi.encode(uint256(bandId), amount)
        ));
        uint256 refilled = abi.decode(ret, (uint256));

        Band storage b = bands[bandId];
        b.borrowedETH = b.borrowedETH > amount ? b.borrowedETH - amount : 0;

        if (full) {
            delete positions[msg.sender][positionId];
        } else {
            pos.debtETH          -= amount;
            pos.collateralSpiral -= collReturn;
        }
        totalOutstandingDebt  -= amount;
        totalCollateralLocked -= collReturn;

        // H-01: conditional flag clear - see helper header. Pre-fix the
        // unconditional delete let a 1-wei repay every 3 blocks pin the
        // liquidator's maturity counter to zero indefinitely.
        _maybeClearFlagLong(positionId);

        require(spiral.transfer(msg.sender, collReturn), "ReturnFailed");
        if (refilled < amount) {
            (bool ok,) = spiralBuyback.call{value: amount - refilled}("");
            if (!ok) revert EthTransferFailed();
        }
        emit Repaid(msg.sender, positionId, amount, collReturn, full);
    }

    // ════════════════════════════════════════════════════════════════════════
    //  LIQUIDATE - third-party permissionless
    // ════════════════════════════════════════════════════════════════════════

    /// @notice Permissionless liquidation of an underwater LONG or BORROW.
    /// @dev H-1 + H-6 hardening:
    ///        • H-6: refuses to act while the position is inside its
    ///          open-cooldown window (`block.number < openedAtBlock +
    ///          COOLDOWN_BLOCKS`).
    ///        • H-1: a third-party liquidation requires the position to be
    ///          observed underwater across TWO calls separated by at least
    ///          `LIQ_MATURITY_BLOCKS`. The first underwater observation
    ///          FLAGS the position (no state change to the position itself)
    ///          and returns. A later call, after the maturity window AND
    ///          while still underwater, performs the actual liquidation. If
    ///          spot recovers in between, any caller can CLEAR the flag by
    ///          invoking `liquidate` again - the function returns normally,
    ///          so the clear persists.
    function liquidate(address user, uint256 positionId) external nonReentrant noSameBlockSwap {
        // Audit N-H-01 fix: owners can't seize their own positions through
        // this path. The L-9 fix removed the `lastLiquidationBlock` bump
        // from `selfLiquidate`, but `liquidate(self, ...)` STILL bumps it,
        // letting an attacker pre-stage dusts and burn the per-block
        // liquidation slot. Force same-EOA owners through `selfLiquidate`
        // (which already skips the bump). Placed BEFORE the
        // OneLiquidationPerBlock check so the rejection is informative
        // even when the global counter is already set.
        if (user == msg.sender) revert UseSelfLiquidate();
        if (uint64(block.number) <= lastLiquidationBlock) revert OneLiquidationPerBlock();
        Position storage pos = positions[user][positionId];
        if (pos.debtETH == 0) revert NoOpenPosition();
        if (block.number < uint256(pos.openedAtBlock) + COOLDOWN_BLOCKS) revert PositionTooFresh();

        (uint160 sqrtP,,,) = poolManager.getSlot0(poolKey.toId());
        uint256 collValue = LDF.spiralValueInETH(sqrtP, pos.collateralSpiral);
        bool underwater = collValue * 10_000 < pos.debtETH * LIQUIDATION_THRESHOLD_BPS;
        uint64 fub = firstUnderwaterBlock[user][positionId];

        if (!underwater) {
            if (fub == 0) revert NotUnderwater();
            // MA-H-01: route the back-to-healthy clear through the multi-
            // block healthy gate so a single pumped block can no longer
            // drop the flag in one call. The helper either advances the
            // healthy timer or clears the flag once it has matured. No
            // revert - state writes commit.
            _maybeClearFlagLongFor(user, positionId);
            return;
        }

        // Position is currently underwater. Two-step gate:
        if (fub == 0) {
            // First observation. Flag it and return - no liquidation yet.
            firstUnderwaterBlock[user][positionId] = uint64(block.number);
            emit LiquidationFlagged(user, positionId, block.number);
            return;
        }
        if (block.number < uint256(fub) + LIQ_MATURITY_BLOCKS) revert LiquidationNotMatured();

        // Flagged + matured + still underwater → actual liquidation.
        uint256 collateral = pos.collateralSpiral;
        uint256 debt       = pos.debtETH;
        uint16  bandId     = pos.bandId;
        uint256 bounty     = (debt * LIQUIDATION_BOUNTY_BPS) / 10_000;
        if (bounty > MAX_LIQUIDATION_BOUNTY) bounty = MAX_LIQUIDATION_BOUNTY;

        delete positions[user][positionId];
        delete firstUnderwaterBlock[user][positionId];
        // MA-H-01: keep the healthy timer in sync - should already be 0 in
        // the matured-seize path (any healthy obs would have aborted via
        // the !underwater branch above) but the explicit cleanup is cheap
        // and removes the only path that could leave a dangling reading.
        if (firstHealthyBlock[user][positionId] != 0) {
            delete firstHealthyBlock[user][positionId];
        }
        totalOutstandingDebt  -= debt;
        totalCollateralLocked -= collateral;
        lastLiquidationBlock   = uint64(block.number);

        bytes memory ret = poolManager.unlock(abi.encode(
            Action.LIQUIDATE,
            abi.encode(collateral, bounty, msg.sender, uint256(bandId))
        ));
        (uint256 ethProceeds, uint256 actualBounty) = abi.decode(ret, (uint256, uint256));

        // Audit MA-H-02 fix: minimum-recovery floor on third-party seizes.
        // A sandwich-pumped seize swap (attacker frontruns the liquidator's
        // tx with a SPIRAL dump that depresses sqrtP, so the seize sells
        // collateral cheaply and most of `debt` becomes silent bad debt on
        // the band) used to be silently absorbed. The floor refuses any
        // seize that recovers less than `MIN_RECOVERY_BPS_FACTOR` of the
        // threshold-implied recovery - so an attacker can capture at most
        // `(1 − floorFraction) × debt × liqThresholdBps / 10000` of MEV per
        // attempt, and the protocol stops absorbing the rest as band-L
        // bad debt. Deeply underwater positions that fail this floor must
        // be force-exited by the owner via `selfLiquidate` (which keeps
        // the no-floor force-exit semantics, accepting the loss).
        // Reverting here rolls back the entire seize swap and all
        // bookkeeping mutations above (Solidity tx semantics) - band state
        // is restored, no partial-state risk.
        uint256 floorEth = (debt * LIQUIDATION_THRESHOLD_BPS * MIN_RECOVERY_BPS_FACTOR) / 1e8;
        if (ethProceeds < floorEth) revert LossyLiquidationRefused();

        // Decrement by actual refill, not full debt - on lossy liqs the band
        // is only credited `ethProceeds - actualBounty`; using `debt` would
        // silently under-count band utilization (mirrors child Ops pattern).
        Band storage b = bands[bandId];
        uint256 refilled = ethProceeds > actualBounty ? ethProceeds - actualBounty : 0;
        uint256 dec      = refilled < debt ? refilled : debt;
        b.borrowedETH    = b.borrowedETH > dec ? b.borrowedETH - dec : 0;

        emit PositionLiquidated(user, positionId, msg.sender, collateral, ethProceeds, actualBounty, false);
    }

    // ════════════════════════════════════════════════════════════════════════
    //  SELF-LIQUIDATE - owner exit at half bounty, underwater-only (Audit L-9)
    // ════════════════════════════════════════════════════════════════════════
    //  Audit L-9 fix (option c, supersedes I-2): the owner can only call this
    //  when their position is actually underwater. Closes the dust-position
    //  griefing attack where an attacker pre-stocked dust positions and
    //  self-liquidated one per block to bump `lastLiquidationBlock` and DoS
    //  third-party liquidations of high-value targets. The original I-2
    //  "zombie escape valve" for non-underwater positions with stuck
    //  closeLongAtomic is preserved through a different door: `repay()`
    //  pays ETH for debt and returns collateral tokens without touching the
    //  curve, so any owner can always exit a long without needing this path.
    //  Owner still pays the half-bounty (50 bps) when calling this.

    function selfLiquidate(uint256 positionId) external nonReentrant noSameBlockSwap {
        Position storage pos = positions[msg.sender][positionId];
        if (pos.debtETH == 0) revert NoOpenPosition();

        // Audit L-9: underwater-only + no lastLiquidationBlock interaction.
        // See header comment block above for full rationale.
        (uint160 sqrtP,,,) = poolManager.getSlot0(poolKey.toId());
        uint256 collValue = LDF.spiralValueInETH(sqrtP, pos.collateralSpiral);
        if (collValue * 10_000 >= pos.debtETH * LIQUIDATION_THRESHOLD_BPS) revert NotUnderwater();

        uint256 collateral = pos.collateralSpiral;
        uint256 debt       = pos.debtETH;
        uint16  bandId     = pos.bandId;
        uint256 bounty     = (debt * LIQUIDATION_BOUNTY_BPS * SELF_LIQ_BOUNTY_BPS) / (10_000 * 100);
        if (bounty > MAX_LIQUIDATION_BOUNTY) bounty = MAX_LIQUIDATION_BOUNTY;

        delete positions[msg.sender][positionId];
        // MA-H-01: keep flag storage consistent with the position. If a
        // third-party liquidator had already flagged this position via
        // `liquidate`, self-liq would otherwise leave that flag dangling
        // - and the new permissionless `tryClearFlagLong` would emit a
        // confusing `LiquidationFlagCleared` on the stale slot.
        if (firstUnderwaterBlock[msg.sender][positionId] != 0) {
            delete firstUnderwaterBlock[msg.sender][positionId];
        }
        if (firstHealthyBlock[msg.sender][positionId] != 0) {
            delete firstHealthyBlock[msg.sender][positionId];
        }
        totalOutstandingDebt  -= debt;
        totalCollateralLocked -= collateral;

        bytes memory ret = poolManager.unlock(abi.encode(
            Action.LIQUIDATE,
            abi.encode(collateral, bounty, msg.sender, uint256(bandId))
        ));
        (uint256 ethProceeds, uint256 actualBounty) = abi.decode(ret, (uint256, uint256));

        // See `liquidate` for the lossy-aware decrement rationale.
        Band storage b = bands[bandId];
        uint256 refilled = ethProceeds > actualBounty ? ethProceeds - actualBounty : 0;
        uint256 dec      = refilled < debt ? refilled : debt;
        b.borrowedETH    = b.borrowedETH > dec ? b.borrowedETH - dec : 0;

        emit PositionLiquidated(msg.sender, positionId, msg.sender, collateral, ethProceeds, actualBounty, true);
    }

    // ════════════════════════════════════════════════════════════════════════
    //  ADD COLLATERAL - recovery path for near-underwater positions
    // ════════════════════════════════════════════════════════════════════════

    /// @dev Audit L-7: `noSameBlockSwap` aligns with every other state-mutating
    ///      user entry point (close / repay / liquidate / open). Closes the
    ///      swap-in-front + rescue-behind single-block pattern that would
    ///      otherwise let bypass H-1's flag-then-liquidate fence.
    function addCollateral(uint256 positionId, uint256 spiralAmount) external nonReentrant noSameBlockSwap {
        if (spiralAmount == 0) revert CollateralBelowMin();
        Position storage pos = positions[msg.sender][positionId];
        if (pos.debtETH == 0 && pos.collateralSpiral == 0) revert PositionNotFound();

        require(spiral.transferFrom(msg.sender, address(this), spiralAmount), "SpiralPullFail");
        pos.collateralSpiral  += spiralAmount;
        totalCollateralLocked += spiralAmount;

        // H-01: conditional flag clear - see helper header. Headline of the
        // H-01 finding: pre-fix a 1-wei addCollateral every 3 blocks
        // pinned the liquidator's maturity counter to zero indefinitely.
        _maybeClearFlagLong(positionId);
    }

    receive() external payable {}
}
