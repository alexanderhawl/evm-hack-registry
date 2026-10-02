// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

import "./RewardToken.sol";

contract Convertor is ReentrancyGuard {
    using SafeERC20 for IERC20;

    IERC20 public immutable transferrableToken;
    RewardToken public immutable mintableToken;

    constructor(
        IERC20 _transferrableToken,
        RewardToken _mintableToken
    ) {
        transferrableToken = _transferrableToken;
        mintableToken = _mintableToken;
    }

    function convert(address from, uint256 amount) external nonReentrant {
        if (from == address(transferrableToken)) {
            transferrableToken.safeTransferFrom(msg.sender, address(this), amount);
            mintableToken.mint(msg.sender, amount);
            return;
        }

        if (from == address(mintableToken)) {
            mintableToken.burn(msg.sender, amount);
            transferrableToken.safeTransfer(msg.sender, amount);
            return;
        }

        revert("invalid from token");
    }
}
