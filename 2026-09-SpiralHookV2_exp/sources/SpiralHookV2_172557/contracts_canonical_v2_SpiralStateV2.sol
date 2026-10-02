// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

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


/// @title  SpiralStateV2
/// @notice Storage layout, constants, structs, events, errors, and
///         modifiers for the v2 canonical Spiral hook. Inherited by
///         `SpiralHookV2` only - the previous Hook/Ops split was
///         removed in favour of a single deployed contract, so this
///         abstract no longer needs to be ABI-compatible across two
///         inheritors.
///
///         Canonical v2 surface intentionally exposes ONLY longs and
///         borrows. Shorts are a per-launch (child) feature: they require
///         a reserved-supply slice held off-curve and the protocol's
///         canonical SPIRAL is fully bonded into the curve at deploy
///         (1M, no reserved). Removing the short surface here makes
///         canonical's mental model identical to its on-chain behaviour
///         and closes the H-10/M-5/M-6 audit findings as obsolete.
abstract contract SpiralStateV2 {
    // ─── Constants ─────────────────────────────────────────────────────────
    uint256 internal constant LTV_BPS                   = 4000;   // 40%
    uint256 internal constant ORIG_FEE_BPS              = 100;    // 1% of collateral value
    uint256 internal constant SWAP_FEE_BPS              = 200;    // 2% - to feeCollector (normal)
    // ─── Sniper-tax tiers ────────────────────────────────────────────────────
    // Canonical lives on Ethereum (~12s blocks). Trading is closed until the
    // owner calls `openTrading()`, which records `tradingOpenBlock`. For a
    // decaying window after open, external BUY/SELL pay an elevated ETH-side
    // swap fee (to `feeCollector`, same recipient as the normal 2%). Windows
    // below are CUMULATIVE block offsets from `tradingOpenBlock`; the math is
    // `blocks = seconds / 12`:
    //   [0,   5)  → 48%   (first 1 min)
    //   [5,  25)  → 38%   (1–5 min)
    //   [25, 50)  → 25%   (5–10 min)
    //   [50,100)  → 20%   (10–20 min)
    //   [100,150) → 15%   (20–30 min)
    //   [150, ∞)  → 2%    (SWAP_FEE_BPS, normal)
    // Leverage/borrow are NOT taxed here - their swaps are hook-initiated and
    // bypass beforeSwap/afterSwap; `ORIG_FEE_BPS` stays 1% for those paths.
    uint256 internal constant SNIPER_W1_BLOCKS = 5;     // 1 min
    uint256 internal constant SNIPER_W2_BLOCKS = 25;    // 5 min
    uint256 internal constant SNIPER_W3_BLOCKS = 50;    // 10 min
    uint256 internal constant SNIPER_W4_BLOCKS = 100;   // 20 min
    uint256 internal constant SNIPER_W5_BLOCKS = 150;   // 30 min
    uint256 internal constant SNIPER_T1_BPS    = 4800;  // 48%
    uint256 internal constant SNIPER_T2_BPS    = 3800;  // 38%
    uint256 internal constant SNIPER_T3_BPS    = 2500;  // 25%
    uint256 internal constant SNIPER_T4_BPS    = 2000;  // 20%
    uint256 internal constant SNIPER_T5_BPS    = 1500;  // 15%
    uint256 internal constant LIQUIDATION_THRESHOLD_BPS = 15_000; // 150%
    uint256 internal constant LIQUIDATION_BOUNTY_BPS    = 100;    // 1% of debt
    /// @notice Per-tx hard cap on liquidator bounty. Defence-in-depth backstop
    ///         against accounting bugs / outlier outflows; not load-bearing
    ///         against any specific attack (cooldowns + maturity gates already
    ///         prevent flash-loan self-liq). Raised from 0.01 → 1 ether per
    ///         audit H-7: at the old cap, liquidations on debt > 1 ETH paid
    ///         a fixed 0.01 ETH that didn't cover gas. New cap lets the 1%
    ///         bps rate apply in full for any debt up to 100 ETH (covers
    ///         every realistic position) while still bounding the outlier
    ///         single-tx payout.
    uint256 internal constant MAX_LIQUIDATION_BOUNTY    = 1 ether;
    /// @notice Blocks a position must age before it's liquidation-eligible.
    ///         Primarily atomicity/flash-loan protection (a position from a
    ///         strictly earlier block can't be manufactured inside a single
    ///         atomic flash-loan tx - that job doesn't scale with block time),
    ///         so unlike LIQ_MATURITY_BLOCKS below this doesn't need to
    ///         preserve a specific wall-clock duration if canonical ever
    ///         moves to a faster chain - see the canonical-chain-migration
    ///         plan's per-constant security analysis.
    uint256 internal constant COOLDOWN_BLOCKS           = 2;
    uint256 internal constant SELF_LIQ_BOUNTY_BPS       = 50;
    /// @notice Audit MA-H-02 fix: third-party `liquidate` must recover at least
    ///         `(debt × LIQUIDATION_THRESHOLD_BPS × MIN_RECOVERY_BPS_FACTOR) /
    ///         (10_000 × 10_000)` ETH from the seize swap. Caps the bad-debt
    ///         a single sandwich-pumped seizure can leak into band L. At the
    ///         edge of liquidation a healthy seize on canonical (liqT=15000)
    ///         recovers ≈ 1.5 × debt × (1 - slippage); the 5000 factor (50 %)
    ///         requires ≥ 0.75 × debt, which fits any realistic position with
    ///         curve slippage below 50 %. Positions DEEPER underwater than
    ///         ~40 % past threshold fall back to `selfLiquidate` (owner force-
    ///         exit at half bounty, no floor) - correct margin-rules outcome.
    uint256 internal constant MIN_RECOVERY_BPS_FACTOR   = 5_000; // 50% of liqThreshold
    /// @notice Audit H-1 mitigation: a third-party `liquidate` requires the
    ///         victim's position to be observed underwater at TWO separate
    ///         blocks at least `LIQ_MATURITY_BLOCKS` apart - the first
    ///         observation flags it, the second (after the maturity window)
    ///         actually liquidates. Forces the attacker to keep spot
    ///         manipulated across blocks while arb closes any artificial gap.
    ///         Does NOT apply to `selfLiquidate` (owner's force-exit path).
    ///         This IS a real-time-cost mechanism (the attacker must sustain
    ///         a manipulated price for the full window while arb corrects
    ///         it), so unlike COOLDOWN_BLOCKS above it genuinely needs to
    ///         preserve its ~36s wall-clock duration if canonical ever moves
    ///         to a faster chain - see the canonical-chain-migration plan's
    ///         per-constant security analysis.
    uint256 internal constant LIQ_MATURITY_BLOCKS       = 3;
    /// @notice Audit MA-H-01 fix: dual of `LIQ_MATURITY_BLOCKS` on the clear
    ///         side. A flagged position has to be observed HEALTHY across
    ///         this many additional blocks before the flag is removed, so a
    ///         single-block cross-EOA spot pump can no longer reset the
    ///         liquidator's maturity counter. Any unhealthy observation
    ///         within the window resets the healthy timer back to zero.
    ///         Same real-time-cost reasoning as `LIQ_MATURITY_BLOCKS`.
    uint256 internal constant CLEAR_MATURITY_BLOCKS     = 3;
    uint256 internal constant MIN_COLLATERAL_VALUE      = 0.05 ether;
    /// @notice Cap on the leverage convergence loop iterations inside
    ///         `spiralLongFromEth._runLeverageLoops`. Audit M-09 raised this
    ///         from 20 → 40: with LTV up to 9500 bps (DEGEN child launches -
    ///         canonical is bounded lower) the zero-slippage iter count to
    ///         hit the 20× DEGEN ceiling is ~5; realistic slippage stays in
    ///         the same neighbourhood; shallow-pool partial-fill band-hops
    ///         dominate the worst case. 40 gives 8× headroom over the
    ///         mathematical minimum and covers a few-dozen-band-hop
    ///         pathological pool. Worst-case gas ≈ 40 × 250k ≈ 10M - fits
    ///         every supported chain's 30M block limit comfortably.
    uint8   internal constant MAX_INTERNAL_LOOPS        = 40;

    uint256 public constant VERSION = 2;

    // ─── Errors ────────────────────────────────────────────────────────────
    error NotOwner();
    error NotPoolManager();
    error PoolAlreadyInitialized();
    error PoolNotInitializedErr();
    error UnauthorizedLP();
    error ZeroAddress();
    error Reentrancy();
    error InvalidAction();
    error EthTransferFailed();
    error TokenSupplyMismatch();
    error InvalidPoolKey();
    error UnauthorizedInitialize();
    error SwapInSameBlock();
    error CollateralBelowMin();
    error NoOpenPosition();
    error CooldownActive();
    error RepayAmountMismatch();
    error NotUnderwater();
    error TickFull();
    error BoundBelowSpot();
    error BadRange();
    error NoEthOut();
    error SpiralBuybackLocked();
    error OneLiquidationPerBlock();
    /// @notice Reverted by `spiralLongFromEth` when no leverage iteration
    ///         could borrow against any band (audit M-10). The caller
    ///         should instead buy spot via Universal Router and then open
    ///         a regular long with the resulting SPIRAL balance.
    error NoLeverageApplied();
    error BadLeverage();
    error SlippageExceeded();
    error PositionUnderwater();
    error WrongKind();
    error PositionNotFound();
    error BadFraction();
    error MsgValueMustBeZero();
    /// @notice Iterative leverage loop ended below 95% of requested target -
    ///         per-band ETH-side LP was too thin to reach the requested
    ///         leverage. User retries lower or waits for pool depth to grow.
    error LeverageMissedTarget();
    /// @notice Audit H-6 mitigation: third-party `liquidate` rejected because
    ///         the position is still inside its open-cooldown window. The
    ///         user's own close / repay / selfLiquidate paths are unaffected.
    error PositionTooFresh();
    /// @notice Audit H-1 mitigation: position observed underwater but the
    ///         flag hasn't matured yet (`block.number < firstUnderwaterBlock
    ///         + LIQ_MATURITY_BLOCKS`). Liquidator must retry after the
    ///         window. If spot recovers in the meantime, any caller can
    ///         clear the flag by re-running `liquidate`.
    error LiquidationNotMatured();
    /// @notice Audit MA-H-02 fix: third-party seize recovered less than
    ///         `(debt × liqThresholdBps × MIN_RECOVERY_BPS_FACTOR) / 1e8`
    ///         ETH, blocking sandwich-pumped or deeply-underwater lossy
    ///         seizes. Owner can still force-exit via `selfLiquidate`.
    error LossyLiquidationRefused();
    /// @notice Audit N-H-01 mitigation: `liquidate(user, posId)` called with
    ///         `user == msg.sender` is rejected. Owners liquidating their
    ///         own positions must route through `selfLiquidate(posId)` so
    ///         the L-9 protection (no `lastLiquidationBlock` write on the
    ///         owner's own seizure) applies. Pre-fix this guard, an attacker
    ///         could pre-stage dust positions and `liquidate(self, dustId)`
    ///         every block to burn the per-block liquidation slot - denying
    ///         third-party liquidations of high-value victim positions for
    ///         the same block.
    error UseSelfLiquidate();
    /// @notice External BUY/SELL (and the leverage/borrow open paths) are
    ///         rejected until the owner calls `openTrading()`. Seeding and
    ///         pool init (owner/internal) are unaffected.
    error TradingClosed();
    /// @notice `openTrading()` called a second time. Trading opens exactly once.
    error TradingAlreadyOpen();
    /// @notice `openTrading()` rejected because the curve isn't fully seeded
    ///         (the last band has zero liquidity). seedBands enforces
    ///         contiguity from band 0, so a non-empty last band ⇒ all seeded.
    error NotFullySeeded();

    // ─── Enums ─────────────────────────────────────────────────────────────
    enum Kind { LONG, BORROW }

    enum Action {
        SEED_BANDS,
        INIT_BUY,
        SPIRAL_LONG_STEP,
        BORROW,
        LONG_CLOSE_LIKE,
        REPAY,
        LIQUIDATE
    }

    // ─── Structs ───────────────────────────────────────────────────────────
    struct Position {
        Kind     kind;
        uint16   bandId;
        uint64   openedAtBlock;
        uint256  collateralSpiral;
        uint256  debtETH;
        uint256  entrySpotE18;
    }

    struct Band {
        int24   tickLower;
        int24   tickUpper;
        uint128 liquidity;
        uint256 borrowedETH;
    }

    // ─── Storage layout (DO NOT REORDER) ───────────────────────────────────
    mapping(address user => mapping(uint256 positionId => Position)) public positions;
    mapping(address user => uint256) public nextPositionId;

    mapping(uint256 bandId => Band) public bands;

    PoolKey public poolKey;
    bool    public poolInitialized;

    /// @notice Settable-once before pool init. Locked permanently after.
    address payable public spiralBuyback;

    uint256 public totalOutstandingDebt;
    uint256 public totalCollateralLocked;

    mapping(address origin => uint64 blockNumber) public lastSwapBlockOf;

    uint64  public lastLiquidationBlock;
    uint64  public launchBlock;

    /// @notice Trading gate. External BUY/SELL and the leverage/borrow open
    ///         paths revert until the owner calls `openTrading()` (once, after
    ///         the curve is fully seeded). `tradingOpenBlock` anchors the
    ///         sniper-tax decay window. Fresh non-proxy deploy, so appending
    ///         these here is layout-safe.
    bool    public tradingOpen;
    uint64  public tradingOpenBlock;

    uint160 public lpMinSqrtPriceX96;
    uint160 public lpMaxSqrtPriceX96;

    /// @notice Audit H-1: per-position flag tracking sustained underwater.
    ///         A third-party `liquidate` that observes the position underwater
    ///         and finds this slot == 0 SETS the slot to `block.number` and
    ///         returns without liquidating. A subsequent call ≥
    ///         `LIQ_MATURITY_BLOCKS` later, while still underwater, performs
    ///         the actual liquidation. If a call observes the position back
    ///         healthy and finds this slot != 0, it CLEARS the slot. Only the
    ///         third-party path uses this; `selfLiquidate` bypasses it.
    mapping(address user => mapping(uint256 positionId => uint64))
        public firstUnderwaterBlock;

    /// @notice Audit MA-H-01: tracks the first block in which a previously-
    ///         flagged position was observed HEALTHY at live spot. The
    ///         underwater flag clears only when the position has stayed
    ///         healthy for `CLEAR_MATURITY_BLOCKS` blocks past this marker.
    ///         Any unhealthy observation (via helper, `liquidate` or
    ///         `tryClearFlagLong`) resets this back to zero, forcing an
    ///         attacker's pump to be sustained across the full window. Only
    ///         meaningful when `firstUnderwaterBlock != 0`; cleaned up
    ///         alongside it.
    mapping(address user => mapping(uint256 positionId => uint64))
        public firstHealthyBlock;

    uint256 internal _locked = 1;

    // ─── Events ────────────────────────────────────────────────────────────
    event PoolReady(PoolId indexed id, uint256 totalSupply);
    /// @notice Emitted once when the owner opens trading. `atBlock` anchors the
    ///         sniper-tax decay window.
    event TradingOpened(uint64 atBlock);
    event BandSeeded(uint256 indexed bandId, int24 tickLower, int24 tickUpper, uint256 spiralAmount, uint128 liquidity);

    event PositionOpened(
        address indexed user,
        uint256 indexed positionId,
        Kind    kind,
        uint16  bandId,
        uint256 collateralSpiral,
        uint256 debtETH,
        uint256 entrySpotE18,
        uint256 origFeeETH
    );

    event PositionClosed(
        address indexed user,
        uint256 indexed positionId,
        uint256 collateralSold,
        uint256 debtRepaid,
        uint256 ethReturned,
        int256  realizedPnlETH
    );

    event PositionReduced(
        address indexed user,
        uint256 indexed positionId,
        uint16  fractionBps,
        uint256 collateralSold,
        uint256 debtRepaid,
        uint256 ethReturned
    );

    event PositionLiquidated(
        address indexed user,
        uint256 indexed positionId,
        address indexed liquidator,
        uint256 collateralSeized,
        uint256 ethProceeds,
        uint256 bountyETH,
        bool    selfLiquidation
    );

    event Repaid(
        address indexed user,
        uint256 indexed positionId,
        uint256 amountETH,
        uint256 collateralReturned,
        bool    full
    );

    /// @notice Audit H-1: emitted when `liquidate` flags a position as
    ///         underwater. The actual liquidation can only happen after
    ///         `LIQ_MATURITY_BLOCKS` blocks have elapsed AND the position
    ///         is still underwater at that later block.
    event LiquidationFlagged(address indexed user, uint256 indexed positionId, uint256 atBlock);
    /// @notice Audit H-1: emitted when a call observes a previously-flagged
    ///         position back to healthy. Anyone can clear (the function
    ///         returns normally, no revert), so the marker stays accurate.
    event LiquidationFlagCleared(address indexed user, uint256 indexed positionId);

    // ─── Modifiers ─────────────────────────────────────────────────────────
    modifier nonReentrant() {
        if (_locked != 1) revert Reentrancy();
        _locked = 2;
        _;
        _locked = 1;
    }

    /// @notice Audit R2-L-03: bump `lastSwapBlockOf` AFTER the function body
    ///         as well as on `afterSwap`. V4's `Hooks.sol:253,293` skips
    ///         `afterSwap` when the unlocker is the hook itself, so internal
    ///         swaps (`spiralLongFromEth`, `closeLongAtomic`, the seize
    ///         swap in `liquidate`, etc.) used to leave the slot at zero -
    ///         which let a single EOA chain multiple gated entry points in
    ///         the same block, leaking the MA-H-01 cost model and bypassing
    ///         the R2-M-03 `noSameBlockSwap` on `tryClearFlag*`. Writing the
    ///         slot at the end of every gated call closes that loop:
    ///         `noSameBlockSwap` now truly means "no second gated call per
    ///         block per EOA," regardless of whether the call swapped
    ///         externally or only internally. Revert paths roll back the
    ///         write - only successful gated calls bump.
    modifier noSameBlockSwap() {
        if (uint64(block.number) <= lastSwapBlockOf[tx.origin]) revert SwapInSameBlock();
        _;
        lastSwapBlockOf[tx.origin] = uint64(block.number);
    }
}
