// SPDX-License-Identifier: GPL-3.0

pragma solidity ^0.8.0;

import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import "@uniswap/v3-core/contracts/interfaces/callback/IUniswapV3SwapCallback.sol";
import "@openzeppelin/contracts/utils/math/SafeCast.sol";
import "./interfaces/IERC20WithPermit.sol";
import "./BaseERC20GsnHandler.sol";

    using SafeCast for uint256;

abstract contract BaseERC20PermitHandler is BaseERC20GsnHandler {

    struct PermitRequestData {
        IERC20WithPermit token;
        uint256 value;
        bytes32 sigR;
        bytes32 sigS;
        uint8 sigV;
    }

    function executePermitInternal(address userAddress, PermitRequestData memory permitRequestData) internal {
        permitRequestData.token.permit(userAddress, address(this), permitRequestData.value, type(uint256).max, permitRequestData.sigV, permitRequestData.sigR, permitRequestData.sigS);
    }

    function approveIfRequiredInternal(address userAddress, PermitRequestData memory permitRequestData, uint256 required) internal {
        if (permitRequestData.token.allowance(userAddress, address(this)) < required) {
            executePermitInternal(userAddress, permitRequestData);
        }
    }

    function decodePermitRequestDataInternal(bytes memory data, uint tokenIndex, uint valueIndex, uint sigIndex) internal pure returns(PermitRequestData memory permitRequestData) {
        permitRequestData = PermitRequestData({
            token : IERC20WithPermit(address(uint160(GsnUtils.getParam(data, tokenIndex)))),
            value : uint256(GsnUtils.getParam(data, valueIndex)),
            sigR : bytes32(GsnUtils.getParam(data, sigIndex)),
            sigS : bytes32(GsnUtils.getParam(data, sigIndex + 1)),
            sigV : uint8(GsnUtils.getParam(data, sigIndex + 2))
        });
    }

    function decodePermitRequestDataWithKnownTokenInternal(bytes memory data, IERC20WithPermit token, uint valueIndex, uint sigIndex) internal pure returns(PermitRequestData memory permitRequestData) {
        permitRequestData = PermitRequestData({
            token : token,
            value : uint256(GsnUtils.getParam(data, valueIndex)),
            sigR : bytes32(GsnUtils.getParam(data, sigIndex)),
            sigS : bytes32(GsnUtils.getParam(data, sigIndex + 1)),
            sigV : uint8(GsnUtils.getParam(data, sigIndex + 2))
        });
    }
}
