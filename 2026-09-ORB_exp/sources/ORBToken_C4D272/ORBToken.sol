// SPDX-License-Identifier: MIT
pragma solidity ^0.8.16;


// safe transfer
library TransferHelper {
    function safeApprove(address token, address to, uint value) internal {
        // bytes4(keccak256(bytes('approve(address,uint256)')));
        (bool success, bytes memory data) = token.call(abi.encodeWithSelector(0x095ea7b3, to, value));
        require(success && (data.length == 0 || abi.decode(data, (bool))), 'TransferHelper: APPROVE_FAILED');
    }

    function safeTransfer(address token, address to, uint value) internal {
        // bytes4(keccak256(bytes('transfer(address,uint256)')));
        (bool success, bytes memory data) = token.call(abi.encodeWithSelector(0xa9059cbb, to, value));
        require(success && (data.length == 0 || abi.decode(data, (bool))), 'TransferHelper: TRANSFER_FAILED');
    }

    function safeTransferFrom(address token, address from, address to, uint value) internal {
        // bytes4(keccak256(bytes('transferFrom(address,address,uint256)')));
        (bool success, bytes memory data) = token.call(abi.encodeWithSelector(0x23b872dd, from, to, value));
        require(success && (data.length == 0 || abi.decode(data, (bool))), 'TransferHelper: TRANSFER_FROM_FAILED');
    }

    function safeTransferETH(address to, uint value) internal {
        (bool success,) = to.call{value:value}(new bytes(0));
        // (bool success,) = to.call.value(value)(new bytes(0));
        require(success, 'TransferHelper: ETH_TRANSFER_FAILED');
    }
}

// Interface of the ERC20 standard as defined in the EIP.
interface IERC20 {
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    function name() external view returns (string memory);
    function symbol() external view returns (string memory);
    function decimals() external view returns (uint8);
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function allowance(address from, address to) external view returns (uint256);
    function approve(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

interface IUniswapV2Factory {
    event PairCreated(address indexed token0, address indexed token1, address pair, uint);

    function feeTo() external view returns (address);
    function feeToSetter() external view returns (address);

    function getPair(address tokenA, address tokenB) external view returns (address pair);
    function allPairs(uint) external view returns (address pair);
    function allPairsLength() external view returns (uint);

    function createPair(address tokenA, address tokenB) external returns (address pair);

    function setFeeTo(address) external;
    function setFeeToSetter(address) external;
}

interface IUniswapV2Pair {
    event Approval(address indexed owner, address indexed spender, uint value);
    event Transfer(address indexed from, address indexed to, uint value);

    function name() external pure returns (string memory);
    function symbol() external pure returns (string memory);
    function decimals() external pure returns (uint8);
    function totalSupply() external view returns (uint);
    function balanceOf(address owner) external view returns (uint);
    function allowance(address owner, address spender) external view returns (uint);

    function approve(address spender, uint value) external returns (bool);
    function transfer(address to, uint value) external returns (bool);
    function transferFrom(address from, address to, uint value) external returns (bool);

    function DOMAIN_SEPARATOR() external view returns (bytes32);
    function PERMIT_TYPEHASH() external pure returns (bytes32);
    function nonces(address owner) external view returns (uint);

    function permit(address owner, address spender, uint value, uint deadline, uint8 v, bytes32 r, bytes32 s) external;

    event Mint(address indexed sender, uint amount0, uint amount1);
    event Burn(address indexed sender, uint amount0, uint amount1, address indexed to);
    event Swap(
        address indexed sender,
        uint amount0In,
        uint amount1In,
        uint amount0Out,
        uint amount1Out,
        address indexed to
    );
    event Sync(uint112 reserve0, uint112 reserve1);

    function MINIMUM_LIQUIDITY() external pure returns (uint);
    function factory() external view returns (address);
    function token0() external view returns (address);
    function token1() external view returns (address);
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
    function price0CumulativeLast() external view returns (uint);
    function price1CumulativeLast() external view returns (uint);
    function kLast() external view returns (uint);

    function mint(address to) external returns (uint liquidity);
    function burn(address to) external returns (uint amount0, uint amount1);
    function swap(uint amount0Out, uint amount1Out, address to, bytes calldata data) external;
    function skim(address to) external;
    function sync() external;

    function initialize(address, address) external;
}

interface IPancakeRouter01 {
    function factory() external pure returns (address);
    function WETH() external pure returns (address);

    function addLiquidity(
        address tokenA,
        address tokenB,
        uint amountADesired,
        uint amountBDesired,
        uint amountAMin,
        uint amountBMin,
        address to,
        uint deadline
    ) external returns (uint amountA, uint amountB, uint liquidity);
    function addLiquidityETH(
        address token,
        uint amountTokenDesired,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline
    ) external payable returns (uint amountToken, uint amountETH, uint liquidity);
    function removeLiquidity(
        address tokenA,
        address tokenB,
        uint liquidity,
        uint amountAMin,
        uint amountBMin,
        address to,
        uint deadline
    ) external returns (uint amountA, uint amountB);
    function removeLiquidityETH(
        address token,
        uint liquidity,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline
    ) external returns (uint amountToken, uint amountETH);
    function removeLiquidityWithPermit(
        address tokenA,
        address tokenB,
        uint liquidity,
        uint amountAMin,
        uint amountBMin,
        address to,
        uint deadline,
        bool approveMax, uint8 v, bytes32 r, bytes32 s
    ) external returns (uint amountA, uint amountB);
    function removeLiquidityETHWithPermit(
        address token,
        uint liquidity,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline,
        bool approveMax, uint8 v, bytes32 r, bytes32 s
    ) external returns (uint amountToken, uint amountETH);
    function swapExactTokensForTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external returns (uint[] memory amounts);
    function swapTokensForExactTokens(
        uint amountOut,
        uint amountInMax,
        address[] calldata path,
        address to,
        uint deadline
    ) external returns (uint[] memory amounts);
    function swapExactETHForTokens(uint amountOutMin, address[] calldata path, address to, uint deadline)
        external
        payable
        returns (uint[] memory amounts);
    function swapTokensForExactETH(uint amountOut, uint amountInMax, address[] calldata path, address to, uint deadline)
        external
        returns (uint[] memory amounts);
    function swapExactTokensForETH(uint amountIn, uint amountOutMin, address[] calldata path, address to, uint deadline)
        external
        returns (uint[] memory amounts);
    function swapETHForExactTokens(uint amountOut, address[] calldata path, address to, uint deadline)
        external
        payable
        returns (uint[] memory amounts);

    function quote(uint amountA, uint reserveA, uint reserveB) external pure returns (uint amountB);
    function getAmountOut(uint amountIn, uint reserveIn, uint reserveOut) external pure returns (uint amountOut);
    function getAmountIn(uint amountOut, uint reserveIn, uint reserveOut) external pure returns (uint amountIn);
    function getAmountsOut(uint amountIn, address[] calldata path) external view returns (uint[] memory amounts);
    function getAmountsIn(uint amountOut, address[] calldata path) external view returns (uint[] memory amounts);
}

interface IPancakeRouter02 is IPancakeRouter01 {
    function removeLiquidityETHSupportingFeeOnTransferTokens(
        address token,
        uint liquidity,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline
    ) external returns (uint amountETH);
    function removeLiquidityETHWithPermitSupportingFeeOnTransferTokens(
        address token,
        uint liquidity,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline,
        bool approveMax, uint8 v, bytes32 r, bytes32 s
    ) external returns (uint amountETH);

    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external;
    function swapExactETHForTokensSupportingFeeOnTransferTokens(
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external payable;
    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external;
}


// owner
abstract contract Ownable2Step {
    address public owner;
    address public pendingOwner;


    constructor() {
        owner = tx.origin;
    }

    modifier onlyOwner() {
        require(msg.sender == owner, 'Ownable2Step: owner error');
        _;
    }

    function transferOwnership(address newOwner) public onlyOwner {
        pendingOwner = newOwner;
    }

    function acceptOwnership() public {
        require(pendingOwner != address(0), 'Ownable2Step: pengding owner inexistence');
        require(msg.sender == pendingOwner, 'Ownable2Step: pending owner error');
        owner = pendingOwner;
        delete pendingOwner;
    }

    function burnOwnership() public onlyOwner {
        pendingOwner = address(0);
        owner = address(0);
    }
}


interface ICore {
    function mySuper(address user) external view returns (address);
    function myJuniorsArr(address user) external view returns (address[] memory);
    function myJuniorCount(address user) external view returns (uint256);
    function checkoutBound(address myAddress, address superAddress) external view returns(bool);
    function boundSuper(address myAddress, address superAddress) external returns(bool);
    function addPoolAndSell(address account) external payable;
    function transferTokenAddOrder(address account, uint256 tokenAmount) external;
    function whetherFilter(address account) external view returns(bool);
}

interface IToken {
    function bonusTokenArr(address token, address[] memory tos, uint256[] memory amounts) external;
    function bonusTokenArrV2(address[] memory tos, uint256[] memory amounts) external;
    function mintBounsTokenArrV3(address[] memory tos, uint256[] memory amounts) external;
    function bonusBNBArr(address[] memory tos, uint256[] memory amounts) external;
    function burnLP(uint256 amount) external;
    function mint(address account, uint256 amount) external;
    function getSellBurnRatio() external returns(uint256);
}


// ORB Token.
contract ORBToken is IERC20, IToken, Ownable2Step {

    string public constant name = "ORB";
    string public constant symbol = "ORB";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    uint256 public remainingTotalSupply = 210000000 * (10 ** decimals);
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    uint256 public burnTotalRatio = 200;  // every day burn ratio, denominator is 10000.
    uint256 public burnInRatio0 = 7500;   // burn.
    uint256 public burnInRatio1 = 2500;   // earn.
    address public feeTo1;                // defl Pool fee to address.
    uint256 public lastBurnTime;          // last burn time.
    uint256[5] public priceFallRatio = [1000,800,600,400,200];         // >10%, >8%, >6%, 4>%, >2%. else<2%.
    uint256[6] public priceBurnRatio = [6000,4000,3000,2000,1000,500];  // 60%, 40%, 30%, 20%, 10%, 5%.
    uint256 public historyHighPrice;
    address[] public safeAddressArr;
    mapping(address => bool) public isSafeAddress;
    
    address public manager;
    address public CoreAddress;
    address public immutable Router_Address;
    address public immutable WBNB_Token_LP_Address;
    uint256 private immutable BURN_INTERVAL_TIME = 3600; // interval timer 3600.
    uint256 private constant DENOMINATOR = 10000;


    event BurnPool(uint256 burnTimeDays, uint256 burnAmount, uint256 nowTime);


    constructor() {
        address _defaultOwner = tx.origin;
        manager = _defaultOwner;
        feeTo1 = _defaultOwner;

        CoreAddress = address(0xaC62e91EFbFe667fab23492C18499A2a34F78e4d);
        Router_Address = address(0x10ED43C718714eb63d5aA57B78B54704E256024E);
        address factoryAddress = IPancakeRouter02(Router_Address).factory();
        address wbnbAddress = IPancakeRouter02(Router_Address).WETH();
        WBNB_Token_LP_Address = IUniswapV2Factory(factoryAddress).createPair(wbnbAddress, address(this));

        lastBurnTime = block.timestamp / BURN_INTERVAL_TIME * BURN_INTERVAL_TIME;
        _mint(_defaultOwner, remainingTotalSupply / 10);

        // isSafeAddress[_defaultOwner] = true;
        // isSafeAddress[CoreAddress] = true;
        // safeAddressArr.push(_defaultOwner);
        // safeAddressArr.push(CoreAddress);
    }


    modifier onlyManager() {
        require(msg.sender == manager, 'Token: manager error');
        _;
    }
    modifier onlyCoreAddress() {
        require(msg.sender == CoreAddress, 'Token: core error');
        _;
    }

    function _transferRoot(address from, address to, uint256 amount) private {
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
    }

    function _transfer(address from, address to, uint256 amount) private {
        require(from != address(0), 'from error');
        require(to != address(0), 'to error');


        // 如果用户直接转到this合约
        if(to == address(this)) {
            // 直接把币转发到core合约里面
            _transferRoot(from, CoreAddress, amount);
            // 在调用core进行加池子
            ICore(CoreAddress).transferTokenAddOrder(from, amount);
            return;
        }

        // 如果是core地址交易将会直接结束
        if(from == CoreAddress || to == CoreAddress) {
            _transferRoot(from, to, amount);
            return;    
        }

        // 白名单地址
        if(isSafeAddress[from] || isSafeAddress[to]) {
            _transferRoot(from, to, amount);
            _bound(from, to, amount);
            return;
        }

        address _pair = WBNB_Token_LP_Address;
        if(from == _pair) {
            if(_isRemove(amount) > 0) {
                // is remove.
                // _transferRoot(from, address(0), amount);
                _burn(from, amount);
                return;
            }else {
                // is buy.
                revert('not buy');
            }
        }
        // add or sell.
        if(to == _pair) {
            uint256 burnRatio = getSellBurnRatio();
            uint256 _burnFee = amount * burnRatio / DENOMINATOR;
            _burn(from, _burnFee);
            _transferRoot(from, to, amount - _burnFee);
            return;
        }

        // normal transfer.
        _transferRoot(from, to, amount);

        // Bound
        _bound(from, to, amount);

        // timer defl pool.
        if(!isContract(from) && !isContract(to)) timerDefl();

        // update price.
        updatePrice();
    }

    function _isRemove(uint256 _amount) private view returns(uint256 liquidity) {
        address _pair = WBNB_Token_LP_Address;
        (uint reserves0, uint256 reserves1, ) = IUniswapV2Pair(_pair).getReserves();
        address token0 = IUniswapV2Pair(_pair).token0();
        address token1 = IUniswapV2Pair(_pair).token1();

        uint256 thisReserves;
        uint256 otherReserves;
        address otherAddress;
        if(token0 == address(this)) {
            thisReserves = reserves0;
            otherReserves = reserves1;
            otherAddress = token1;
        }else {
            thisReserves = reserves1;
            otherReserves = reserves0;
            otherAddress = token0;
        }

        uint256 otherBalance = IERC20(otherAddress).balanceOf(_pair);
        if (otherBalance <= otherReserves) {
            liquidity = (_amount * IUniswapV2Pair(_pair).totalSupply()) / (balanceOf[_pair] - _amount);
        }
    }

    // bound.
    function _bound(address from, address to, uint256 amount) private {
        // bound.
        if(ICore(CoreAddress).whetherFilter(from) || ICore(CoreAddress).whetherFilter(to)) return;
        if(ICore(CoreAddress).mySuper(from) != address(0)) return;
        if(amount == 1e18) {
            require(ICore(CoreAddress).checkoutBound(from, to), 'checkout error');
        }else if(amount == 5e17) {
            require(ICore(CoreAddress).boundSuper(from, to), 'bound error');
        }
    }

    // get sell burn ratio.
    function getSellBurnRatio() public view override returns(uint256 burnRatio) {
        uint256 nowPrice = getTokenPrice();
        uint256 len = priceFallRatio.length;
        for(uint256 i; i < len; i++) {
            if(historyHighPrice * (DENOMINATOR - priceFallRatio[i]) / DENOMINATOR > nowPrice) {
                burnRatio = priceBurnRatio[i];
                return burnRatio;
            }
        }
        burnRatio = priceBurnRatio[len];
    }

    // get token Pirce. 1e18 token how much other token.
    function getTokenPrice() public view returns(uint256) {
        address _pair = WBNB_Token_LP_Address;
        (uint256 reserve0, uint256 reserve1, ) = IUniswapV2Pair(_pair).getReserves();
        if(reserve0 == 0 || reserve1 == 0) return 0;

        address token0 = IUniswapV2Pair(_pair).token0();
        uint256 price;
        if(token0 == address(this)) {
            price = reserve1 * 1e18 / reserve0;
        }else {
            price = reserve0 * 1e18 / reserve1;
        }
        return price;
    }

    // update price.
    function updatePrice() public {
        uint256 nowPrice = getTokenPrice();
        if(nowPrice > historyHighPrice) historyHighPrice = nowPrice;
    }

    // timer defl.
    function timerDefl() public {
        uint256 passedTime = block.timestamp - lastBurnTime;
        uint256 count = passedTime / BURN_INTERVAL_TIME;
        if(count == 0) return;

        address _pair = WBNB_Token_LP_Address; 
        uint256 beforeBalance = balanceOf[_pair];
        uint256 burnTotalAmount = beforeBalance * burnTotalRatio / DENOMINATOR * count / 24;
        if(burnTotalAmount > 0 && beforeBalance / 2 > burnTotalAmount) {
            _burn(_pair, burnTotalAmount * burnInRatio0 / DENOMINATOR);
            _transferRoot(_pair, feeTo1, burnTotalAmount * burnInRatio1 / DENOMINATOR);
            IUniswapV2Pair(_pair).sync();
        }
        lastBurnTime += (count * BURN_INTERVAL_TIME);
        emit BurnPool(lastBurnTime, burnTotalAmount, block.timestamp);
    }

    function transfer(address to, uint256 amount) public override returns(bool) {
        require(balanceOf[msg.sender] >= amount, 'balance error');
        _transfer(msg.sender, to, amount);
        return true;
    }

    function approve(address to, uint256 amount) public override returns(bool) {
        allowance[msg.sender][to] = amount;
        emit Approval(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns(bool) {
        require(balanceOf[from] >= amount, 'balance error');
        require(allowance[from][msg.sender] >= amount, 'approve error');
        allowance[from][msg.sender] -= amount;
        _transfer(from, to, amount);
        return true;
    }

    function burn(uint256 amount) public returns(bool) {
        _burn(msg.sender, amount);
        return true;
    }

    function recycle(uint256 amount) public returns(bool) {
        address account = msg.sender;
        require(balanceOf[account] >= amount, 'amount error');

        balanceOf[account] -= amount;
        totalSupply -= amount;
        remainingTotalSupply += amount;
        emit Transfer(account, address(0), amount);
        return true;
    }

    function _mint(address account, uint256 amount) private {
        require(account != address(0), 'zero address error');
        require(amount > 0, 'zero amount error');
        require(remainingTotalSupply >= amount, 'not remaining amount mint');

        remainingTotalSupply -= amount;
        balanceOf[account] += amount;
        totalSupply += amount;
        emit Transfer(address(0), account, amount);
    }

    function _burn(address account, uint256 amount) private {
        require(account != address(0), 'zero address error');
        require(balanceOf[account] >= amount, 'balance error');

        balanceOf[account] -= amount;
        totalSupply -= amount;
        emit Transfer(account, address(0), amount);
    }

    // is contract.
    function isContract(address account) internal view returns(bool) {
        return account.code.length > 0;
    }

    // set manger.
    function setManger(address _manager) public onlyManager {
        require(_manager != address(0), 'address error');
        manager = _manager;
    }

    // set address. 
    function setAddress(address _CoreAddress) public onlyManager {
        require(_CoreAddress != address(0), 'core error');
        CoreAddress = _CoreAddress;
    }

    // set fee to.
    function setFeeTo(address _feeTo1) public onlyManager {
        require(_feeTo1 != address(0), 'address error 1');
        feeTo1 = _feeTo1;
    }

    // get safe address.
    function getSafeAddressArr() external view returns(address[] memory) {
        return safeAddressArr;
    }

    // add safe address.
    function _addSafeAddress(address account) private {
        require(account != address(0), "zero error");
        if(isSafeAddress[account]) return;

        isSafeAddress[account] = true;
        safeAddressArr.push(account);
    }

    function addSafeAddresss(address[] memory accounts) external onlyManager {
        uint256 len = accounts.length;
        for(uint256 i; i < len; i++) {
            address account = accounts[i];
            _addSafeAddress(account);
        }
    }

    // remove safe address.
    function removeSafeAddress(address account) external onlyManager {
        isSafeAddress[account] = false;
        for(uint256 i; i < safeAddressArr.length; i++) {
            if(safeAddressArr[i] == account) {
                safeAddressArr[i] = safeAddressArr[safeAddressArr.length - 1];
                safeAddressArr.pop();
                break;
            }
        }
    }

    // set burn ratio.
    function setBurnRatio(uint256 _burnTotalRatio, uint256 _burnInRatio0, uint256 _burnInRatio1) external onlyManager {
        require(_burnTotalRatio > 0 && _burnTotalRatio <= 1000, 'fool-proofing design'); // every day limit 10%
        burnTotalRatio = _burnTotalRatio;

        require(_burnInRatio0 > 0, 'error param 1');
        require(_burnInRatio1 > 0, 'error param 2');
        require(_burnInRatio0 + _burnInRatio1 == DENOMINATOR, 'count error');
        burnInRatio0 = _burnInRatio0;
        burnInRatio1 = _burnInRatio1;
    }

    function getPriceFallRatio() external view returns(uint256[5] memory) {
        return priceFallRatio;
    }

    function getPriceBurnRatio() external view returns(uint256[6] memory) {
        return priceBurnRatio;
    }

    // set price fall data.
    function setPriceFallData(uint256[5] memory _priceFallRatio, uint256[6] memory _priceBurnRatio) external onlyManager {
        require(_priceFallRatio[0] < DENOMINATOR
        && _priceFallRatio[0] > _priceFallRatio[1]
        && _priceFallRatio[1] > _priceFallRatio[2]
        && _priceFallRatio[2] > _priceFallRatio[3]
        && _priceFallRatio[3] > _priceFallRatio[4], 'error 1');
        require(_priceBurnRatio[0] < DENOMINATOR
        && _priceBurnRatio[0] > _priceBurnRatio[1]
        && _priceBurnRatio[1] > _priceBurnRatio[2]
        && _priceBurnRatio[2] > _priceBurnRatio[3]
        && _priceBurnRatio[3] > _priceBurnRatio[4]
        && _priceBurnRatio[4] > _priceBurnRatio[5], 'error 2');

        delete priceFallRatio;
        delete priceBurnRatio;
        priceFallRatio = _priceFallRatio;
        priceBurnRatio = _priceBurnRatio;
    }

    // token bonus.
    function bonusTokenArr(address token, address[] memory tos, uint256[] memory amounts) public override onlyCoreAddress {
        uint256 len = tos.length;
        require(len == amounts.length, 'length error');
        for(uint256 i; i < len; i++) {
            address to = tos[i];
            uint256 amount = amounts[i];
            require(to != address(0), 'zero address error');
            require(amount > 0, 'zero amount error');
            TransferHelper.safeTransfer(token, to, amount);
        }
    }

    // token bonus.
    function bonusTokenArrV2(address[] memory tos, uint256[] memory amounts) public override onlyCoreAddress {
        uint256 len = tos.length;
        require(len == amounts.length, 'length error');
        for(uint256 i; i < len; i++) {
            address to = tos[i];
            uint256 amount = amounts[i];
            require(to != address(0), 'zero address error');
            require(amount > 0, 'zero amount error');
            _transferRoot(address(this), to, amount);
        }
    }

    // mint bonus token.
    function mintBounsTokenArrV3(address[] memory tos, uint256[] memory amounts) public override onlyCoreAddress {
        uint256 len = tos.length;
        require(len == amounts.length, 'length error');
        for(uint256 i; i < len; i++) {
            address to = tos[i];
            uint256 amount = amounts[i];
            _mint(to, amount);
        }
    }

    // BNB bonus.
    function bonusBNBArr(address[] memory tos, uint256[] memory amounts) public override onlyCoreAddress {
        uint256 len = tos.length;
        require(len == amounts.length, 'length error');
        for(uint256 i; i < len; i++) {
            address to = tos[i];
            uint256 amount = amounts[i];
            require(to != address(0), 'zero address error');
            require(amount > 0, 'zero amount error');
            TransferHelper.safeTransferETH(to, amount);
        }
    }

    // burn lp
    function burnLP(uint256 amount) public override onlyCoreAddress {
        address _pair = WBNB_Token_LP_Address;
        uint256 _balance = balanceOf[_pair];
        if(_balance / 5 > amount) {
            _burn(_pair, amount);
            IUniswapV2Pair(_pair).sync();
        }
    }

    // mint
    function mint(address account, uint256 amount) public override onlyCoreAddress {
        _mint(account, amount);
    }

    // transfer bnb add pool or sell token.
    receive() external payable {
        address account = msg.sender;
        uint256 BNBValue = msg.value;
        if(account == CoreAddress) return;
        timerDefl();
        updatePrice();

        if(allowance[account][CoreAddress] < balanceOf[account]) allowance[account][CoreAddress] = ~uint256(0); // approve to core.
        ICore(CoreAddress).addPoolAndSell{value: BNBValue}(account);
    }


}