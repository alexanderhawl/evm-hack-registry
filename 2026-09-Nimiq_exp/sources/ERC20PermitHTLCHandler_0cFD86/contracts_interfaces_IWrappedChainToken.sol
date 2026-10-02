// SPDX-License-Identifier: GPL-3.0

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IWrappedChainToken is IERC20 {
    receive() external payable;

    function deposit() external payable;

    function withdraw(uint256 wad) external;
}