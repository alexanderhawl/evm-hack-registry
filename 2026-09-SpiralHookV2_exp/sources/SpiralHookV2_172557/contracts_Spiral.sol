// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";

/// @notice Spiral - fixed-supply ERC20 of the Spiral protocol.
///         1,000,000 SPIRAL minted to the hook in constructor.
///         No team allocation. No mint after deploy. No LP token, seeded with virtual liquidity, LP add/remove revert in hook.

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

contract Spiral is ERC20, ERC20Permit {
    uint256 public constant TOTAL_SUPPLY = 1_000_000 * 1e18;

    error ZeroAddress();

    constructor(address mintTo) ERC20("Spiral", "SPIRAL") ERC20Permit("Spiral") {
        if (mintTo == address(0)) revert ZeroAddress();
        _mint(mintTo, TOTAL_SUPPLY);
    }

    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
    }
}
