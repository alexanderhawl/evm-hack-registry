// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// ============================================================================
//                 _ _  _ ___  ____ ____ ___ ____ _  _ ___
//                 | |\/| |__] |  | |__/  |  |__| |\ |  |
//                 | |  | |    |__| |  \  |  |  | | \|  |
//
// ============================================================================
//
// IMPORTANT: DO NOT PROVIDE LIQUIDITY FOR THIS TOKEN
//
// PROTOCOL OWNED LIQUIDITY IS PROVIDED
//
// ANY EXTERNALLY PROVIDED LIQUIDITY WILL BE AUTOMATICALLY
// TRANSFERRED TO THE DAO TREASURY
//
// FOR MORE INFORMATION CLICK ON "Read Contract" THEN CLICK ON
// THE ADDRESS LINK UNDER "INFO_CONTRACT"
//
// THE "Code" tab of the linked "INFO_CONTRACT" WILL PROVIDE
// ADDITIONAL DETAILS
//
// THE INFO_CONTRACT ADDRESS RETURNED HERE MAY CHANGE AS
// NEW INFORMATION IS ADDED

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/utils/math/SafeCast.sol";

import "../uniswap/IUniswapV3Pool.sol";
import "../uniswap/IPositionManager.sol";
import "../uniswap/FixedPoint128.sol";
import "../uniswap/PositionKey.sol";

import "../callbacks/ITokenTransferCallback.sol";
import "../utils/EnumerableValues.sol";
import "../role/RoleModule.sol";

contract RewardToken is ERC20, ERC20Permit, ERC20Votes, RoleModule {
    using EnumerableSet for EnumerableSet.AddressSet;
    using EnumerableValues for EnumerableSet.AddressSet;

    EnumerableSet.AddressSet internal _transferCallbacks;

    uint256 private constant _CALLBACKS_DISABLED = 1;
    uint256 private constant _CALLBACKS_ENABLED = 2;

    uint256 private _areCallbacksEnabled;

    bool public areTransfersEnabled = true;
    address public INFO_CONTRACT;

    constructor(
        RoleStore _roleStore,
        string memory name_,
        string memory symbol_
    )
        RoleModule(_roleStore)
        ERC20(name_, symbol_)
        ERC20Permit(name_)
    {
        _areCallbacksEnabled = _CALLBACKS_ENABLED;
    }

    function setInfoContract(address _infoContract) external onlyRole(Role.INFO_ADMIN) {
        INFO_CONTRACT = _infoContract;
    }

    function clock() public view override returns (uint48) {
        return SafeCast.toUint48(block.timestamp);
    }

    // solhint-disable-next-line func-name-mixedcase
    function CLOCK_MODE() public view override returns (string memory) {
        // Check that the clock was not modified
        require(clock() == block.timestamp, "ERC20Votes: broken clock mode");
        return "mode=timestamp";
    }

    function enableTransfers() external onlyRole(Role.CONFIG_ADMIN) {
        areTransfersEnabled = true;
    }

    function disableTransfers() external onlyRole(Role.CONFIG_ADMIN) {
        areTransfersEnabled = false;
    }

    function enableCallbacks() external onlyRole(Role.CALLBACK_ADMIN) {
        _enableCallbacks();
    }

    function disableCallbacks() external onlyRole(Role.CALLBACK_ADMIN) {
        _disableCallbacks();
    }

    function transferWithoutCallbacks(address to, uint256 amount) external onlyRole(Role.CALLBACK_ADMIN) returns (bool) {
        address owner = _msgSender();
        _disableCallbacks();
        _transfer(owner, to, amount);
        _enableCallbacks();
        return true;
    }

    function addTransferCallback(address _callback) external onlyRole(Role.CONFIG_ADMIN) {
        _transferCallbacks.add(_callback);
    }

    function removeTransferCallback(address _callback) external onlyRole(Role.CONFIG_ADMIN) {
        _transferCallbacks.remove(_callback);
    }

    function transferCallbacks(uint256 start, uint256 end) external view returns (address[] memory) {
        return _transferCallbacks.valuesAt(start, end);
    }

    function mint(address to, uint256 amount) external onlyRole(Role.TOKEN_MINTER) {
        _mint(to, amount);
    }

    function burn(address account, uint256 amount) external onlyRole(Role.TOKEN_BURNER) {
        _burn(account, amount);
    }

    function _beforeTokenTransfer(address from, address to, uint256 amount) internal override(ERC20) {
        if (!areTransfersEnabled) {
            revert("transfers not enabled");
        }

        super._beforeTokenTransfer(from, to, amount);

        if (_areCallbacksEnabled == _CALLBACKS_ENABLED) {
            _areCallbacksEnabled = _CALLBACKS_DISABLED;

            uint256 count = _transferCallbacks.length();
            for (uint256 i; i < count; i++) {
                ITokenTransferCallback(_transferCallbacks.at(i)).beforeTokenTransfer(msg.sender, from, to, amount);
            }

            _areCallbacksEnabled = _CALLBACKS_ENABLED;
        }
    }

    function _afterTokenTransfer(address from, address to, uint256 amount) internal override(ERC20, ERC20Votes) {
        super._afterTokenTransfer(from, to, amount);

        if (_areCallbacksEnabled == _CALLBACKS_ENABLED) {
            _areCallbacksEnabled = _CALLBACKS_DISABLED;

            uint256 count = _transferCallbacks.length();
            for (uint256 i; i < count; i++) {
                ITokenTransferCallback(_transferCallbacks.at(i)).afterTokenTransfer(msg.sender, from, to, amount);
            }

            _areCallbacksEnabled = _CALLBACKS_ENABLED;
        }
    }

    function _enableCallbacks() internal {
        _areCallbacksEnabled = _CALLBACKS_ENABLED;
    }

    function _disableCallbacks() internal {
        _areCallbacksEnabled = _CALLBACKS_DISABLED;
    }

    function _mint(address to, uint256 amount) internal override(ERC20, ERC20Votes) {
        _disableCallbacks();
        super._mint(to, amount);
        _enableCallbacks();
    }

    function _burn(address account, uint256 amount) internal override(ERC20, ERC20Votes) {
        _disableCallbacks();
        super._burn(account, amount);
        _enableCallbacks();
    }
}
