// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/utils/Strings.sol";
import "../utils/EnumerableValues.sol";
import "./Role.sol";

contract RoleStore {
    using EnumerableSet for EnumerableSet.AddressSet;
    using EnumerableSet for EnumerableSet.Bytes32Set;
    using EnumerableValues for EnumerableSet.AddressSet;
    using EnumerableValues for EnumerableSet.Bytes32Set;

    EnumerableSet.Bytes32Set internal roles;
    mapping(bytes32 => EnumerableSet.AddressSet) internal roleMembers;
    mapping(address => mapping (bytes32 => bool)) roleCache;

    modifier onlyRole(bytes32 role) {
        _checkRole(msg.sender, role);
        _;
    }

    constructor() {
        _grantRole(msg.sender, Role.ROLE_ADMIN);
    }

    function grantRole(address account, bytes32 role) external onlyRole(Role.ROLE_ADMIN) {
        _grantRole(account, role);
    }

    function revokeRole(address account, bytes32 role) external onlyRole(Role.ROLE_ADMIN) {
        _revokeRole(account, role);
    }

    function getRoles(uint256 start, uint256 end) external view returns (bytes32[] memory) {
        return roles.valuesAt(start, end);
    }

    function getRoleMembers(bytes32 roleKey, uint256 start, uint256 end) external view returns (address[] memory) {
        return roleMembers[roleKey].valuesAt(start, end);
    }

    function hasRole(address account, bytes32 role) public view returns (bool) {
        return roleCache[account][role];
    }

    function checkRole(address account, bytes32 role) public view {
        return _checkRole(account, role);
    }

    function _grantRole(address account, bytes32 role) internal {
        roles.add(role);
        roleMembers[role].add(account);
        roleCache[account][role] = true;
    }

    function _revokeRole(address account, bytes32 role) internal {
        roleMembers[role].remove(account);
        roleCache[account][role] = false;

        if (roleMembers[role].length() == 0) {
            if (role == Role.ROLE_ADMIN) {
                revert("ROLE_ADMIN cannot be empty");
            }
        }
    }

    function _checkRole(address account, bytes32 role) internal view {
        if (!hasRole(account, role)) {
            revert(
                string(
                    abi.encodePacked(
                        "AccessControl: account ",
                        Strings.toHexString(account),
                        " is missing role ",
                        Strings.toHexString(uint256(role), 32)
                    )
                )
            );
        }
    }

}
