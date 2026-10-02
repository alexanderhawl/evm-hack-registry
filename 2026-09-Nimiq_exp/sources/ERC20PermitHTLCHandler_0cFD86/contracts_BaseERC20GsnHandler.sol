// SPDX-License-Identifier: GPL-3.0

pragma solidity ^0.8.0;

import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import "@uniswap/v3-core/contracts/interfaces/callback/IUniswapV3SwapCallback.sol";
import "@openzeppelin/contracts/utils/math/SafeCast.sol";
import "./interfaces/IWrappedChainToken.sol";
import "./BaseCombinedGsnHandler.sol";

using SafeCast for uint256;

abstract contract BaseERC20GsnHandler is BaseCombinedGsnHandler, IUniswapV3SwapCallback {

    /// @dev The minimum value that can be returned from #getSqrtRatioAtTick. Equivalent to getSqrtRatioAtTick(MIN_TICK)
    uint160 internal constant MIN_SQRT_RATIO = 4295128739;
    /// @dev The maximum value that can be returned from #getSqrtRatioAtTick. Equivalent to getSqrtRatioAtTick(MAX_TICK)
    uint160 internal constant MAX_SQRT_RATIO = 1461446703485210103287273052203988822378723970342;

    IWrappedChainToken public wrappedChainToken;

    mapping(IERC20 => IUniswapV3Pool) public registeredTokenPool;
    mapping(IERC20 => uint256) public deposits;
    uint256 private registeredTokenCount = 0;

    mapping(address => uint256) internal nonces;

    struct FeeInformation {
        IERC20 token;
        address payer;
        uint256 fee;
        uint256 chainTokenFee;
    }

    modifier onlyRegisteredToken(IERC20 token) {
        require(address(registeredTokenPool[token]) != address(0), "Base: token not registered");
        _;
    }

    modifier onlyWithWrappedChainToken() {
        require(address(wrappedChainToken) != address(0), "Base: no wrapped chain token");
        _;
    }

    function setWrappedChainToken(IWrappedChainToken _wrappedChainToken) public onlyOwner {
        require(registeredTokenCount == 0, "Base: tokens registered");
        wrappedChainToken = _wrappedChainToken;
        require(wrappedChainToken.approve(owner(), type(uint256).max), "Base: owner approval failed");
    }

    function registerToken(IERC20 token, IUniswapV3Pool pool) public onlyOwner {
        require(address(pool) != address(0), "Base: No pool defined");
        require(address(registeredTokenPool[token]) == address(0), "Base: token already registered");
        registeredTokenPool[token] = pool;
        registeredTokenCount = registeredTokenCount + 1;
    }

    // @dev deprecated
    function registeredTokenPoolFee(IERC20 token) public view returns (uint24 fee) {
        if (address(registeredTokenPool[token]) != address(0)) {
            return registeredTokenPool[token].fee();
        }
        return 0;
    }

    function unregisterToken(IERC20 token) public onlyOwner onlyRegisteredToken(token) {
        delete registeredTokenPool[token];
        registeredTokenCount = registeredTokenCount - 1;
    }

    function processFeeInternal(FeeInformation memory feeInformation) internal {
        if (feeInformation.fee > 0) {
            if (feeInformation.chainTokenFee > 0) {
                bool zeroForOne = address(feeInformation.token) < address(wrappedChainToken);
                (int256 amount0Delta, int256 amount1Delta) = registeredTokenPool[feeInformation.token].swap(
                    address(this),
                    zeroForOne,
                    -(feeInformation.chainTokenFee).toInt256(),
                    (zeroForOne ? MIN_SQRT_RATIO + 1 : MAX_SQRT_RATIO - 1),
                    abi.encode(FEE_UNISWAP_CALLBACK_SELECTOR, feeInformation)
                );
                (amount0Delta, amount1Delta);
            } else {
                require(feeInformation.token.transferFrom(feeInformation.payer, address(this), feeInformation.fee), "Base: Fee transfer failed");
            }
        } else {
            require(feeInformation.chainTokenFee == 0, "Base: Fee too low");
        }
    }

    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata _data) external virtual override {
        (bytes4 methodId) = abi.decode(_data, (bytes4));
        if (methodId == FEE_UNISWAP_CALLBACK_SELECTOR) {
            feeUniswapCallback(amount0Delta, amount1Delta, _data);
        } else {
            require(false, "Base: Unexpected callback");
        }
    }

    bytes4 internal constant FEE_UNISWAP_CALLBACK_SELECTOR = bytes4(keccak256(bytes("feeUniswapCallback(int256,int256,bytes)")));
    function feeUniswapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata _data) internal {
        require(amount0Delta > 0 || amount1Delta > 0, "Base: Amount zero");
        (bytes4 methodId, FeeInformation memory feeInformation) = abi.decode(_data, (bytes4, FeeInformation));
        (methodId);
        require(msg.sender == address(registeredTokenPool[feeInformation.token]), "Base: Pool not registered");
        bool zeroForOne = address(feeInformation.token) < address(wrappedChainToken);
        (uint256 amountIn, uint256 amountOutReceived) = zeroForOne ? (uint256(amount0Delta), uint256(-amount1Delta)) : (uint256(amount1Delta), uint256(-amount0Delta));
        require(amountIn <= feeInformation.fee, "Base: fee too low");
        require(amountOutReceived == feeInformation.chainTokenFee, "Base: pool failed");
        if (feeInformation.payer == address(this)) {
            require(feeInformation.token.transfer(msg.sender, amountIn), "Base: Fee transfer failed");
        } else {
            require(feeInformation.token.transferFrom(feeInformation.payer, msg.sender, amountIn), "Base: Fee transfer failed");
        }
    }

    function finishFeeInternal(FeeInformation memory feeInformation) internal {
        if (feeInformation.chainTokenFee > 0) {
            wrappedChainToken.withdraw(feeInformation.chainTokenFee);
            relayHub.depositFor{value : feeInformation.chainTokenFee}(address(this));
        }
    }

    function finishFeeWithCustomTargetInternal(FeeInformation memory feeInformation, address payable target) internal {
        if (feeInformation.chainTokenFee > 0) {
            wrappedChainToken.withdraw(feeInformation.chainTokenFee);
            target.transfer(feeInformation.chainTokenFee);
        }
    }

    function decodeFeeInformationInternal(bytes memory data, IERC20 token, address payer, uint feeIndex, uint256 chainTokenFee) internal pure returns(FeeInformation memory feeInformation) {
        feeInformation = FeeInformation({
            token : token,
            payer : payer,
            fee : uint256(GsnUtils.getParam(data, feeIndex)),
            chainTokenFee : chainTokenFee
        });
    }

    function getNonce(address from) public override view returns (uint256) {
        return nonces[from];
    }

    function withdraw(uint amount, address payable target) public onlyOwner {
        target.transfer(amount);
    }

    function withdrawToken(IERC20 token, uint amount, address target) public onlyOwner {
        uint balance = token.balanceOf(address(this));
        require(balance >= deposits[token], "Base: balance invalid");
        require(amount <= balance - deposits[token], "Base: amount too high");
        token.transfer(target, amount);
    }

    // solhint-disable-next-line no-empty-blocks
    receive() external virtual payable {}
}
