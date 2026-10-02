// SPDX-License-Identifier: GPL-3.0

pragma solidity >=0.8.7;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

import "@uniswap/v2-core/contracts/interfaces/IUniswapV2Pair.sol";
import "@uniswap/v2-periphery/contracts/interfaces/IWETH.sol";

interface ITransferLogbook {
    function commissionedEvent(address sender, address token, uint amount, uint amountIn, uint amountOut, string memory message) external returns (uint index);
    function commissionedEventUpdate(address sender, uint index, uint amountUpdate, uint amountInUpdate, uint amountOutUpdate, string memory message) external;
}

interface IBonfireMagic {
    function computeSwapAmounts(uint balanceA, uint balanceB, uint reserveA, uint reserveB, uint pancakeSwapFeePermille) external view returns (uint amountAOut, uint amountBOut);
    function computeSwapAmountsWithReflection(uint balanceA, uint balanceB, uint reserveA, uint reserveB, uint reflectionB, uint totalSupplyB, uint pancakeSwapFeePermille) external view returns (uint amountAOut, uint amountBOut);
}

contract BonfireSwap is Ownable {
    bytes4 private constant TRANSFER = bytes4(keccak256(bytes('transfer(address,uint256)')));
    bytes4 private constant TRANSFERFROM = bytes4(keccak256(bytes('transferFrom(address,address,uint256)')));
    ITransferLogbook public constant logbook = ITransferLogbook(0x5b7D3F54B004eD2634C1360102E43cD0d22686FD );
    IWETH public constant WETH = IWETH(0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c);
    address public constant tokenAddress = 0x5e90253fbae4Dab78aa351f4E6fed08A64AB5590;
    address public constant pancakePair = 0xD3F478F0d5E98b01f757bc6cB54Db4C00b9838f2;
    uint public constant reflection = 5;
    uint public constant totalTax = 10;
    uint public constant pancakeSwapFeePermille = 2;

    IBonfireMagic public magic = IBonfireMagic(0xf33D46ecBB9fEdF80F8fEeBa8eb9d3c1053d3f91);
    event BonfireMagicUpdate(address _magic);

    uint public minimumSkimAmount = 1e6 * 1e9;

    address[] public pools;

    modifier ensure(uint deadline) {
        require(deadline >= block.timestamp, 'UniswapV2Router: EXPIRED');
        _;
    }

    function setBonfireMagic(address _magic) public onlyOwner {
        magic = IBonfireMagic(_magic);
        emit BonfireMagicUpdate(_magic);
    }

    function setMinimumSkimAmount(uint minAmount) public onlyOwner {
        minimumSkimAmount = minAmount;
    }

    function setPool(address pool, bool enabled) public onlyOwner {
        for (uint i=0; i<pools.length; i++) {
            if (pools[i] == pool) {
                if (!enabled) {
                    pools[i] = pools[pools.length-1];
                    pools.pop();
                }
                return;
            }
        }
        if (enabled) pools.push(pool);
    }

    function skimPotential(address pool) public view returns (uint amountEstimation) {
        uint reserve;
        if (IUniswapV2Pair(pool).token0() == tokenAddress) {
            (reserve,,) = IUniswapV2Pair(pool).getReserves();
        } else {
            (,reserve,) = IUniswapV2Pair(pool).getReserves();
        }
        uint potential = IERC20(tokenAddress).balanceOf(pool) - reserve;
        amountEstimation = potential - (potential * totalTax / 100);
    }

    function skimPools(address beneficiary) public returns (uint amountAOut, uint amountBOut) {
        for (uint8 i=0; i<pools.length; i++) {
            if (skimPotential(pools[i]) >= minimumSkimAmount) {
                (uint a0, uint a1) = skimPool(pools[i], beneficiary);
                if (IUniswapV2Pair(pools[i]).token0() == tokenAddress) {
                    amountAOut += a0;
                    amountBOut += a1;
                } else {
                    amountAOut += a1;
                    amountBOut += a0;
                }
            }
        }
    }

    function skimPool(address pool, address beneficiary) public returns (uint amountAOut, uint amountBOut) {
        (amountAOut, amountBOut) = _enactSwap(address(WETH), 0, reflection, beneficiary, pool);
    }

    function transfer(address to, uint amountAIn, address beneficiary, uint deadline) public ensure(deadline) returns (uint amountAOut, uint amountBOut) {
        _safeTransferFrom(tokenAddress, to, pancakePair, amountAIn);
        (amountAOut, amountBOut) = skimPools(beneficiary);
    }

    function simpleTransfer(address to, uint amountAIn, address beneficiary) public returns (uint amountAOut, uint amountBOut) {
        return transfer(to, amountAIn, beneficiary, block.timestamp);
    }

    function loggedTransfer(address to, uint amountAIn, address beneficiary, uint deadline, string memory purpose) public ensure(deadline) returns (uint amountAOut, uint amountBOut) {
        _safeTransferFrom(tokenAddress, to, pancakePair, amountAIn);
        (amountAOut, amountBOut) = skimPools(beneficiary);
        logbook.commissionedEvent(to, tokenAddress, amountAIn, amountAOut, amountBOut, purpose);
    }

    function simpleLoggedTransfer(address to, uint amountAIn, address beneficiary, string memory purpose) public returns (uint amountAOut, uint amountBOut) {
        return loggedTransfer(to, amountAIn, beneficiary, block.timestamp, purpose);
    }

    function buy(uint minAmountOut, address to, uint deadline) public payable ensure(deadline) returns (uint amountAOut, uint amountBOut) {
        uint amountAIn = msg.value;
        WETH.deposit{value: amountAIn}();
        _safeTransfer(address(WETH), pancakePair, amountAIn);
        (amountAOut, amountBOut) = _enactSwap(address(WETH), minAmountOut, reflection, to, pancakePair);
    }

    function simpleBuy(uint minAmountOut) public payable returns (uint amountAOut, uint amountBOut) {
        return buy(minAmountOut, msg.sender, block.timestamp);
    }

    function loggedBuy(uint minAmountOut, address to, uint deadline, string memory purpose) public payable ensure(deadline) returns (uint amountAOut, uint amountBOut) {
        uint amountAIn = msg.value;
        (amountAOut, amountBOut) = buy(minAmountOut, to, deadline);
        logbook.commissionedEvent(to, tokenAddress, amountAIn, amountAOut, amountBOut, purpose);
    }
    
    function simpleLoggedBuy(uint minAmountOut, string memory purpose) public payable returns (uint amountAOut, uint amountBOut) {
        return loggedBuy(minAmountOut, msg.sender, block.timestamp, purpose);
    }

    function sell(uint amountAIn, uint minAmountOut, address payable to, uint deadline) public ensure(deadline) returns (uint amountAOut, uint amountBOut) {
        _safeTransferFrom(tokenAddress, msg.sender, pancakePair, amountAIn);
        (amountAOut, amountBOut) = _enactSwap(tokenAddress, minAmountOut, 0, address(this), pancakePair);
        WETH.withdraw(amountBOut);
        to.transfer(amountBOut);
    }

    function simpleSell(uint amount, uint minAmountOut) public returns (uint amountAOut, uint amountBOut) {
        return sell(amount, minAmountOut, payable(msg.sender), block.timestamp);
    }

    function loggedSell(uint amountAIn, uint minAmountOut, address payable to, uint deadline, string memory purpose) public ensure(deadline) returns (uint amountAOut, uint amountBOut) {
        _safeTransferFrom(tokenAddress, msg.sender, pancakePair, amountAIn);
        (amountAOut, amountBOut) = _enactSwap(tokenAddress, minAmountOut, 0, address(this), pancakePair);
        WETH.withdraw(amountBOut);
        to.transfer(amountBOut);
        logbook.commissionedEvent(to, tokenAddress, amountAIn, amountAOut, amountBOut, purpose);
    }

    function simpleLoggedSell(uint amount, uint minAmountOut, string memory purpose) public returns (uint amountAOut, uint amountBOut) {
        return loggedSell(amount, minAmountOut, payable(msg.sender), block.timestamp, purpose);
    }

    function _safeTransferFrom(address token, address from, address to, uint amount) internal {
        (bool success, bytes memory data) = token.call(abi.encodeWithSelector(TRANSFERFROM, from, to, amount));
        require(success && (data.length == 0 || abi.decode(data, (bool))), 'BonfireSwap: TRANSFERFROM_FAILED');
    }
    
    function _safeTransfer(address token, address to, uint value) internal {
        (bool success, bytes memory data) = token.call(abi.encodeWithSelector(TRANSFER, to, value));
        require(success && (data.length == 0 || abi.decode(data, (bool))), 'BonfireSwap: TRANSFER_FAILED');
    }

    function _enactSwap(address tokenAAddress, uint minAmountOut, uint reflectionB, address to, address uniswapPair) internal returns (uint amountAOut, uint amountBOut) {
        IUniswapV2Pair pair = IUniswapV2Pair(uniswapPair);
        if (pair.token0() == tokenAAddress) {
            uint balanceA;
            uint balanceB;
            uint reserveA;
            uint reserveB;
            balanceA = IERC20(pair.token0()).balanceOf(uniswapPair);
            balanceB = IERC20(pair.token1()).balanceOf(uniswapPair);
            (reserveA, reserveB, ) = pair.getReserves();
            if (reflectionB > 0) {
                (amountAOut, amountBOut) = magic.computeSwapAmountsWithReflection(balanceA, balanceB, reserveA, reserveB, reflectionB, IERC20(pair.token1()).totalSupply(), pancakeSwapFeePermille);
            } else {
                (amountAOut, amountBOut) = magic.computeSwapAmounts(balanceA, balanceB, reserveA, reserveB, pancakeSwapFeePermille);
            }
        } else {
            uint balanceA;
            uint balanceB;
            uint reserveA;
            uint reserveB;
            balanceB = IERC20(pair.token0()).balanceOf(uniswapPair);
            balanceA = IERC20(pair.token1()).balanceOf(uniswapPair);
            (reserveB, reserveA, ) = pair.getReserves();
            if (reflectionB > 0) {
                (amountAOut, amountBOut) = magic.computeSwapAmountsWithReflection(balanceA, balanceB, reserveA, reserveB, reflectionB, IERC20(pair.token0()).totalSupply(), pancakeSwapFeePermille);
            } else {
                (amountAOut, amountBOut) = magic.computeSwapAmounts(balanceA, balanceB, reserveA, reserveB, pancakeSwapFeePermille);
            }
        }
        uint gains;
        if (pair.token0() == tokenAAddress) {
            gains = IERC20(pair.token1()).balanceOf(to);
            pair.swap(amountAOut, amountBOut, to, new bytes(0));
            gains = IERC20(pair.token1()).balanceOf(to) - gains;
        } else {
            gains = IERC20(pair.token0()).balanceOf(to);
            pair.swap(amountBOut, amountAOut, to, new bytes(0));
            gains = IERC20(pair.token0()).balanceOf(to) - gains;
        }
        require (gains >= minAmountOut, "BonfireSwap: MinOut not met.");
    }

    function getAmountOut(uint amountIn, uint reserveIn, uint reserveOut) internal pure returns (uint amountOut) {
        require(amountIn > 0, "BonfireSwap: insufficient input amount.");
        require(reserveIn > 0 && reserveOut > 0, "BonfireSwap: insufficient liquidity.");
        uint amountInWithFee = amountIn * 998;
        uint numerator = amountInWithFee * reserveOut;
        uint denominator = reserveIn * 1000 + amountInWithFee;
        amountOut = numerator / denominator;
    }

    function pancakeQuoteBuy(uint amountA) public view returns (uint amountB) {
        IUniswapV2Pair pair = IUniswapV2Pair(pancakePair);
        (uint reserveA, uint reserveB, ) = pair.getReserves();
        if (pair.token0() == tokenAddress) (reserveA, reserveB) = (reserveB, reserveA);
        amountB = getAmountOut(amountA, reserveA, reserveB);
    }

    function taxedQuoteBuy(uint amountA) public view returns (uint amountB) {
        return pancakeQuoteBuy(amountA)*(100-totalTax)/100;
    }

    function bonfireQuoteBuy(uint amountA) public view returns (uint amountB) {
        IERC20 token = IERC20(tokenAddress);
        uint quoteB = pancakeQuoteBuy(amountA);
        uint quoteBReduced = quoteB * (100-totalTax) / 100;
        uint pairReflection = quoteB * reflection * (quoteBReduced+token.balanceOf(pancakePair)) / (100 * token.totalSupply());
        amountB = quoteBReduced + pairReflection;
    }

    function pancakeQuoteSell(uint amountA) public view returns (uint amountB) {
        IUniswapV2Pair pair = IUniswapV2Pair(pancakePair);
        (uint reserveA, uint reserveB, ) = pair.getReserves();
        if (pair.token1() == tokenAddress) (reserveA, reserveB) = (reserveB, reserveA);
        amountB = getAmountOut(amountA, reserveA, reserveB);
    }

    function taxedQuoteSell(uint amountA) public view returns (uint amountB) {
        amountB = pancakeQuoteSell(amountA*(100-totalTax)/100);
    }

    function bonfireQuoteSell(uint amountA) public view returns (uint amountB) {
        IERC20 token = IERC20(tokenAddress);
        uint amountAReduced = amountA * (100-totalTax) / 100;
        uint pairReflection = amountA * reflection * (amountAReduced + token.balanceOf(pancakePair)) / (100 * token.totalSupply());
        amountB = pancakeQuoteSell(amountAReduced + pairReflection);
    }

    function pairStats() public view returns (uint balance0, uint reserve0, uint balance1, uint reserve1) {
        IUniswapV2Pair pair = IUniswapV2Pair(pancakePair);
        balance0 = IERC20(pair.token0()).balanceOf(pancakePair);
        balance1 = IERC20(pair.token1()).balanceOf(pancakePair);
        (reserve0, reserve1, ) = pair.getReserves();
    }

    receive() external payable {}

    function withdrawETH(address payable to, uint256 amount) external onlyOwner {
        to.transfer(amount);
    }

    function withdrawAllETH(address payable to) external onlyOwner {
        to.transfer(address(this).balance);
    }

    function withdrawToken(address _tokenAddress, address to, uint256 amount) external onlyOwner {
        ERC20 token = ERC20(_tokenAddress);
        token.transfer(to, amount);
    }

    function withdrawAllToken(address _tokenAddress, address to) external onlyOwner {
        ERC20 token = ERC20(_tokenAddress);
        token.transfer(to, token.balanceOf(address(this)));
    }

}


