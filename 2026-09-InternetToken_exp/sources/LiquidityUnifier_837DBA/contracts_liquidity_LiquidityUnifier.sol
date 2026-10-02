// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/utils/math/SafeCast.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

import "../role/RoleModule.sol";
import "../uniswap/Uniswap.sol";
import "../constants/Constants.sol";
import "../tokens/RewardToken.sol";

contract LiquidityUnifier is RoleModule, ReentrancyGuard {
    using SafeCast for int256;
    using SafeCast for uint256;
    using SafeERC20 for IERC20;

    using EnumerableSet for EnumerableSet.AddressSet;
    using EnumerableValues for EnumerableSet.AddressSet;

    address public immutable rewardToken;
    address public treasury;
    uint256 public swapAmount;
    uint256 public keeperFee;

    address public currentPoolV3;

    EnumerableSet.AddressSet internal _excludedPools;

    event UpdateConfig(address treasury, uint256 swapAmount, uint256 keeperFee);
    event AddExcludedPool(address pool);
    event RemoveExcludedPool(address pool);

    constructor(
        RoleStore _roleStore,
        address _rewardToken,
        address _treasury,
        uint256 _swapAmount,
        uint256 _keeperFee
    ) RoleModule(_roleStore) {
        rewardToken = _rewardToken;

        treasury = _treasury;
        swapAmount = _swapAmount;
        keeperFee = _keeperFee;
    }

    function updateConfig(
        address _treasury,
        uint256 _swapAmount,
        uint256 _keeperFee
    ) external onlyRole(Role.CONFIG_ADMIN) {
        treasury = _treasury;
        swapAmount = _swapAmount;
        keeperFee = _keeperFee;

        emit UpdateConfig(_treasury, _swapAmount, _keeperFee);
    }

    /// @notice Adds a pool to exclusion list.
    /// @param _pool Pool address to exclude from unifier swaps
    function addExcludedPool(address _pool) external onlyRole(Role.CONFIG_ADMIN) {
        _excludedPools.add(_pool);
        emit AddExcludedPool(_pool);
    }

    /// @notice Removes a pool from exclusion list.
    /// @param _pool Pool address to remove from exclusions
    function removeExcludedPool(address _pool) external onlyRole(Role.CONFIG_ADMIN) {
        _excludedPools.remove(_pool);
        emit RemoveExcludedPool(_pool);
    }

    modifier validateSupply() {
        uint256 supply = IERC20(rewardToken).totalSupply();

        _;

        if (IERC20(rewardToken).totalSupply() > supply) {
            revert("supply cannot increase");
        }
    }

    /// @notice Returns excluded pools.
    /// @param start Start index (inclusive)
    /// @param end End index (exclusive)
    /// @return Array slice of excluded pool addresses
    function excludedPools(uint256 start, uint256 end) external view returns (address[] memory) {
        return _excludedPools.valuesAt(start, end);
    }

    /// @notice Swaps newly minted reward token through a provided Uniswap V2 pair and distributes received token.
    /// @param token Output token to receive and distribute
    /// @param pool Uniswap V2 pair address for `rewardToken` and `token`
    function swapV2(address token, address pool) external nonReentrant validateSupply {
        _validatePool(pool);
        _validatePoolV2Tokens(token, pool);

        (uint112 reserve0, uint112 reserve1, /* uint32 blockTimestampLast */) = IUniswapV2Pair(pool).getReserves();
        // reserveIn is reserve0: if reserve0 is for rewardToken
        // reserve0 is for rewardToken: if rewardToken < token
        uint256 reserveIn = rewardToken < token ? reserve0 : reserve1;
        uint256 reserveOut = rewardToken < token ? reserve1 : reserve0;
        uint256 amountInWithFee = swapAmount * 997;
        uint256 numerator = amountInWithFee * reserveOut;
        uint256 denominator = (reserveIn * 1000) + amountInWithFee;
        uint256 amountOut = numerator / denominator;

        // amount0Out = amountOut if token0 is token
        // token0 is token if token < rewardToken
        RewardToken(rewardToken).mint(pool, swapAmount);

        uint256 balance = IERC20(token).balanceOf(address(this));

        IUniswapV2Pair(pool).swap({
            amount0Out: token < rewardToken ? amountOut : 0,
            amount1Out: token < rewardToken ? 0 : amountOut,
            to: address(this),
            data: ""
        });

        uint256 received = IERC20(token).balanceOf(address(this)) - balance;

        _distribute(token, received);
        _clearPool(pool);
    }

    // since the main liquidity pool should be excluded, it would be possible
    // for a user to provide liquidity to that pool in the form of the base
    // token
    //
    // if price enters the range of the user's liquidity the user would not
    // be able to remove the liquidity due to the validations in RewardToken
    //
    // the user may still be able to withdraw liquidity by doing a swap to
    // raise the price of the token so that their position is completely
    // in the base token, they can then remove liquidity and sell the bought
    // tokens
    //
    // this may not be preventable but the impact may not be significant,
    // the fees required to be paid to raise the token's price may also
    // deter users from doing this
    /// @notice Swaps newly minted reward token through a provided Uniswap V3 pool and distributes received token.
    /// @param token Output token to receive and distribute
    /// @param pool Uniswap V3 pool address for `rewardToken` and `token`
    function swapV3(address token, address pool) external nonReentrant validateSupply {
        _validatePool(pool);
        _validatePoolV3Tokens(token, pool);

        // zeroForOne: true if swapping token0 for token1
        // and token0 is rewardToken
        bool zeroForOne = IUniswapV3Pool(pool).token0() == rewardToken;

        uint160 sqrtPriceLimitX96 = zeroForOne ? (TickMath.MIN_SQRT_RATIO + 1) : (TickMath.MAX_SQRT_RATIO - 1);

        uint256 balance = IERC20(token).balanceOf(address(this));

        currentPoolV3 = pool;

        IUniswapV3Pool(pool).swap({
            recipient: address(this),
            zeroForOne: zeroForOne,
            amountSpecified: swapAmount.toInt256(),
            sqrtPriceLimitX96: sqrtPriceLimitX96,
            data: ""
        });

        currentPoolV3 = address(0);
        uint256 received = IERC20(token).balanceOf(address(this)) - balance;

        _distribute(token, received);
        _clearPool(pool);
    }

    function uniswapV3SwapCallback(
        int256 amount0Delta,
        int256 amount1Delta,
        bytes calldata /* data */
    ) external {
        address _currentPoolV3 = currentPoolV3;

        if (msg.sender != _currentPoolV3) {
            revert("msg.sender != currentPoolV3");
        }

        int256 amount = amount0Delta > 0 ? amount0Delta : amount1Delta;
        RewardToken(rewardToken).mint(_currentPoolV3, amount.toUint256());
    }

    function _validatePool(address pool) internal view {
        if (pool == address(0)) {
            revert("invalid pool");
        }
        if (pool.code.length == 0) {
            revert("invalid pool");
        }

        if (_excludedPools.contains(pool)) {
            revert("excluded pool");
        }
    }

    function _validatePoolV2Tokens(address token, address pool) internal view {
        address token0 = IUniswapV2Pair(pool).token0();
        address token1 = IUniswapV2Pair(pool).token1();
        if (!(token0 == rewardToken && token1 == token || token0 == token && token1 == rewardToken)) {
            revert("invalid pool");
        }
    }

    function _validatePoolV3Tokens(address token, address pool) internal view {
        address token0 = IUniswapV3Pool(pool).token0();
        address token1 = IUniswapV3Pool(pool).token1();
        if (!(token0 == rewardToken && token1 == token || token0 == token && token1 == rewardToken)) {
            revert("invalid pool");
        }
    }

    function _distribute(
        address token,
        uint256 amount
    ) internal {
        uint256 keeperAmount = amount * keeperFee / Constants.FLOAT_BASE;
        IERC20(token).safeTransfer(msg.sender, keeperAmount);
        IERC20(token).safeTransfer(treasury, amount - keeperAmount);
    }

    function _clearPool(address pool) internal {
        uint256 poolBalance = IERC20(rewardToken).balanceOf(pool);
        RewardToken(rewardToken).burn(pool, poolBalance);
    }
}
