// SPDX-License-Identifier: GPL-3.0

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IERC20Meta is IERC20 {
    function getChainId() external view returns (uint256);

    function getDomainSeperator() external view returns (bytes32);

    function getNonce(address user) external view returns (uint256);

    function executeMetaTransaction(address userAddress, bytes memory functionSignature, bytes32 sigR, bytes32 sigS, uint8 sigV) external payable returns (bytes memory);
}