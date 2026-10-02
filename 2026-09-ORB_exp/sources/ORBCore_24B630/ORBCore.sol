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
        owner = msg.sender;
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

    // take eth.
    function takeETH(address to, uint256 amount) public onlyOwner {
        require(to != address(0), 'Ownable2Step: zero address error');
        require(amount > 0, 'Ownable2Step: value zero error');
        TransferHelper.safeTransferETH(to, amount);
    }

    // take token.
    function takeToken(address token, address to , uint256 amount) public onlyOwner {
        require(to != address(0), 'Ownable2Step: zero address error');
        require(amount > 0, 'Ownable2Step: value zero error');
        TransferHelper.safeTransfer(token, to, amount);
    }
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


// ORB Core.
contract ORBCore is ICore, Ownable2Step {
    mapping(address => address) public mySuper;       // 上级
    mapping(address => address[]) public myJuniors;   // 直推地址数组
    mapping(address => uint256) public myJuniorCount; // 直推数量
    address[] public filterSpecialAddressArr;         // 过滤绑定关系的地址数组
    
    address public Token_Address;  // 本项目的token.
    address public WBNB_Address;
    address public WBNB_Token_LP_Address; // WBNB和token的LP
    address public Router_Address;
    address public Minter_Address; // 空投分红权限地址
    //address public Return_Address; // 计算残留的币，退回到某个地址
    uint256 private constant DENOMINATOR = 10000; // 分母

    // 上下级分红的比例
    // super1=500,
    // super2=400,
    // super3=300,
    // super4=200,
    // super5-10=100(*6=600),
    // super11-20=50(*10=500)，
    // leader=500,
    // user=6000,
    uint256[22] public bonusRateArr = [500,400,300,200,100,100,100,100,100,100,50,50,50,50,50,50,50,50,50,50,1500,6000];
    // 20层上级分红需要有的直推数量
    uint256[20] public superEarnRequireArr = [1,3,3,3,3,5,5,7,7,9,9,11,11,13,13,15,15,15,15,15];

    // 用户累计添加的BNB数量。70%的作为本金额度计算。
    // 可用于统计是否是有效用户(累计满0.14个BNB)。也可以用于计算盈利税。盈利税是计算70%的本金，如转入1个BNB，实际添加池子为0.7个BNB，那么卖出超0.7BNB将会收取盈利税。
    mapping(address => uint256) public userAddBNBCount;
    // 用户累计卖出, 用于计算盈利税
    mapping(address => uint256) public userSellBNBCount;
    // 下级给用户加速数量
    mapping(address => uint256) public userSpeedBNBCount;
    // 用户是否成为上级的有效直推
    mapping(address => bool) public userISValidJunior;
    // 用户的有效直推数量
    mapping(address => uint256) public userValidJunior;

    mapping(uint256 => UserOrderData) public userOrder; // 订单id，对应订单数据
    struct UserOrderData {
        //uint256 capitalBNB;      // 本金，计算70%之后的
        uint256 dayReleaseBNB;   // 每天释放的BNB数量
        uint256 takedBNBCount;   // 已经领取的BNB数量(实际给的是token，要换算成BNB纪录)
        uint256 canTakeBNBTotal; // 领满出局的BNB总量
        address account;         // 用户地址
        uint128 orderID;         // 订单号
        uint64 lastTakedTime;    // 用户最后一次领取的时间
        uint64 isOut;            // 是否领满出局,0=没有领取满，1=领取满了
    }
    uint256 public nextOrderID = 1;  // 下一次的订单ID, 1是开始，后端获取这个值要减去1。

    uint256 public minBNB = 1e16;                    // 最少添加是0.01BNB。所以卖出的配置不能大于等于这个数字。
    uint256 public superMinBNB = 12e16;              // 有效用户的最少质押量，用于上下级奖励，用户质押0.2BNB，60%之后就是0.12BNB，作为有效用户。
    uint256 public userBNBLimit = 1e18;              // 单用户质押的总量限制,1个BNB.
    uint256 constant private SELL_BNB_LOWEST = 1e14; // 卖出最低0.0001BNB。 0.0001BNB-0.001BNB, 1e14=sell 10%, 1e15=sell 95%。
    bool public whiteListOpen = true;                // 白名单验证开关，开启就是需要验证白名单，关闭就是不需要验证白名单。
    mapping(address => bool) public whiteList;       // 只有白名单才可以参与
    mapping(address => bool) public blackList;       // 黑名单地址，只是不允许上下级分红，防止有人绑定不能接受BNB的地址为上级，从而导致分红整笔交易都会失败。 
    uint256 public sellMustFeeRatio = 500;     // 卖出税（需求不明确，支持0比例）
    uint256 public sellBeyondFeeRatio = 1000;  // 盈利税.
    uint256 public sellBurnTokenRatio = 6000;  // 卖出token，会销毁LP池子里面的token比例.（需求不明确，支持0比例）

    address public leader1;  // 加池子5%的税
    address public leader2;  // 卖出5%的税和盈利税
    address public lpTo;     // LP的接收地址.（需求不明确，支持0地址）
    address public tokenTo;  // 转入token的接收地址.（需求不明确，支持0地址）
    uint256 immutable public PROJECT_START_TIME; // 项目开始的时候，用于计算用户添加池子所属于的季度。
    uint256 public takeIntervalTime = 72000;     // 领取的间隔时间

    event BoundSuper(address myAddress, address superAddress);
    event AccountAdd(uint256 orderID, address account, uint256 capitalBNB, uint256 time);
    event AccountSell(address account, uint256 sellTokenAmount, uint256 gainBNBAmount, uint256 time);
    event DayEarn(uint256 OrderID, address account, uint256 mintTokenAmount);
    

    constructor() {
        Token_Address = address(0x008471fAB0a89CBD5C789501d2Afc92985bDeA17);
        WBNB_Address = address(0x008471fAB0a89CBD5C789501d2Afc92985bDeA17);
        WBNB_Token_LP_Address = address(0x008471fAB0a89CBD5C789501d2Afc92985bDeA17);
        Router_Address = address(0x008471fAB0a89CBD5C789501d2Afc92985bDeA17);
        Minter_Address = address(0x008471fAB0a89CBD5C789501d2Afc92985bDeA17);

        leader1 = address(0xa8876f46C3F33C86BD883d6C4B068217349B4D01);
        leader2 = address(0x06Ba42a715192747c5Fc8f0Af34e3f5a93bB7f5f);
        lpTo = address(0x339527f70d5682B3E8E946CC408B78bF0e5CA2Ca);
        tokenTo = address(0x7cF3B05e757F6ca7F1036a68409Cc4bf088E355f);
        PROJECT_START_TIME = block.timestamp;
        
        addFilterSpecialAddressArr(address(0));
        addFilterSpecialAddressArr(address(this));
        addFilterSpecialAddressArr(Router_Address);
        blackList[address(0)] = true;
    }
    

    modifier onlyTokenAddress() {
        require(msg.sender == Token_Address, 'Core: caller must be token address');
        _;
    }

    modifier onlyMinterAddress() {
        require(msg.sender == Minter_Address,  "Core: caller must be minter address");
        _;
    }

    // 设置minter地址
    function setMinterAddress(address Minter_Address_) external onlyOwner {
        require(Minter_Address_ != address(0), "address error");
        Minter_Address = Minter_Address_;
    }

    // 获取上下级分配比例
    function getBonusRateArr() external view returns(uint256[22] memory) {
        return bonusRateArr;
    }

    // 设置上下级分配比例
    function setBonusRateArr(uint256[22] memory bonusRateArr_) external onlyOwner {
        delete bonusRateArr;

        uint256 totalRate_;
        for(uint256 i; i < bonusRateArr_.length; i++) {
            totalRate_ += bonusRateArr_[i];
        }
        require(totalRate_ == DENOMINATOR, 'total rate error');

        bonusRateArr = bonusRateArr_;
    }

    // 获取上级分红条件
    function getSuperEarnRequireArr() external view returns(uint256[20] memory) {
        return superEarnRequireArr;
    }

    // 设置上级分红条件
    function setSuperEarnRequireArr(uint256[20] memory superEarnRequireArr_) external onlyOwner {
        delete superEarnRequireArr;
        superEarnRequireArr = superEarnRequireArr_;
    }

    function getFilterSpecialAddressArr() external view returns(address[] memory) {
        return filterSpecialAddressArr;
    }

    function addFilterSpecialAddressArr(address specialAddress) public onlyOwner {
        bool whetherExist;
        for(uint256 i; i < filterSpecialAddressArr.length; i++) {
            if(specialAddress == filterSpecialAddressArr[i]) whetherExist = true;
        }
        if(!whetherExist) filterSpecialAddressArr.push(specialAddress);
    }

    function removeFilterSpecialAddressArr(address specialAddress) external onlyOwner {
        address[] memory temporary = filterSpecialAddressArr;
        delete filterSpecialAddressArr;
        
        for(uint256 i; i < temporary.length; i++) {
            if(temporary[i] != specialAddress) filterSpecialAddressArr.push(temporary[i]);
        }
    }

    function whetherFilter(address account) external view returns(bool) {
        for(uint256 i; i < filterSpecialAddressArr.length; i++) {
            if(account == filterSpecialAddressArr[i]) return true; // 是排除的地址
        }
        return false;
    }
    
    function checkoutBound(address myAddress, address superAddress) public view returns(bool) {
        if(mySuper[myAddress] != address(0)) return false;  // 已经有上级了
        if(myAddress == superAddress) return false;         // 不能绑定自己
        for(uint256 i; i < filterSpecialAddressArr.length; i++) {
            if(myAddress == filterSpecialAddressArr[i] || superAddress == filterSpecialAddressArr[i]) return false; // 不能绑定特殊地址
        }

        address _s = mySuper[superAddress];
        // 如果循环是3，那么至少要5个地址才会闭环。也就是地址5才能绑定地址1。
        for(uint256 i; i < 20; i++) {
            // 不能闭环绑定
            if(_s == myAddress) return false; 
            _s = mySuper[_s];
        }
        return true;
    }

    function boundSuper(address myAddress, address superAddress) external onlyTokenAddress returns(bool) {
        require(checkoutBound(myAddress, superAddress), 'Core: checkout error');
        
        mySuper[myAddress] = superAddress;
        myJuniors[superAddress].push(myAddress);
        myJuniorCount[superAddress]++;
        emit BoundSuper(myAddress, superAddress);
        return true;
    }

    function myJuniorsArr(address user) external view override returns (address[] memory) {
        return myJuniors[user];
    }

    // 添加池子或卖出token
    function addPoolAndSell(address account) external payable onlyTokenAddress {
        require(account != address(0), 'account is zero');
        uint256 BNBValue = msg.value;
        if(BNBValue >= minBNB) {
            // 添加池子
            _addPool(account, BNBValue);
        }else if(BNBValue >= SELL_BNB_LOWEST) {
            // 卖出
            TransferHelper.safeTransferETH(account, BNBValue); // 先把bnb还给用户
            uint256 mulNumber = BNBValue / SELL_BNB_LOWEST;    // 计算卖出token的十分之几，最少是10分之1, 最多是10分之10。
            require(mulNumber > 0 && mulNumber <= 10, '1 in 10 mul verify error'); // 1-10之间的数。
            uint256 tokenBalance = IERC20(Token_Address).balanceOf(account);
            uint256 sellTokenAmount = tokenBalance * mulNumber / 10; // 计算卖出的token数量
            // 新增, 如果是10分之10，就默认为10分之9.9
            if(mulNumber == 10) {
                sellTokenAmount = sellTokenAmount * 99 / 100;
            }
            require(sellTokenAmount > 0, 'token zero error');
            _sellToken(account, sellTokenAmount); // 卖出token
        }else {
            // BNB数量异常
            revert('BNB amount error');
        }
    }

    // 买入，加池子，再上下级分红。
    function _addPool(address account, uint256 BNBValue) private {
        // 验证白名单
        require(!whiteListOpen || whiteList[account], 'not white list');
        if(whiteList[account]) whiteList[account] = false;

        // 先兑换token, 在添加池子
        // 允许除不尽，小数点后取整的情况。
        uint256 beforeBalance = IERC20(Token_Address).balanceOf(address(this));
        // 用户的本金
        uint256 capitalBNB = BNBValue * bonusRateArr[21] / DENOMINATOR;
        uint256 addBNBAmount = capitalBNB / 2;
        address[] memory path = new address[](2);
        path[0] = WBNB_Address;
        path[1] = Token_Address;
        IPancakeRouter02(Router_Address).swapExactETHForTokens{value: addBNBAmount}(
            0,
            path,
            address(this),
            block.timestamp
        );
        uint256 lastBalance = IERC20(Token_Address).balanceOf(address(this));
        uint256 tokenAmount = lastBalance - beforeBalance;
        require(tokenAmount > 0, 'zero token');
        IPancakeRouter02(Router_Address).addLiquidityETH{value: addBNBAmount}(Token_Address, tokenAmount, 0, 0, lpTo, block.timestamp);
        // 这里会存在没有用完的BNB或者token。

        // 用户参与的BNB累计量，60%之后的。
        uint256 nowTime = block.timestamp;
        _addOrder(account, capitalBNB, nowTime);

        // 分配BNB
        TransferHelper.safeTransferETH(leader1, BNBValue * bonusRateArr[20] / DENOMINATOR);
        // 上下级分红
        address superAccount = account;
        for(uint256 i; i < 20; i++) {
            superAccount = mySuper[superAccount];
            if(superAccount == address(0)) break; // 如果遇到0地址，就中断循环。
            if(userValidJunior[superAccount] >= superEarnRequireArr[i] && !blackList[superAccount] && userAddBNBCount[superAccount] >= superMinBNB) {
                uint256 earnAmount = BNBValue * bonusRateArr[i] / DENOMINATOR;
                TransferHelper.safeTransferETH(superAccount, earnAmount);
            }
        }
        // 上下级分红这里会遗留很多BNB.
    }

    // 添加订单, bnb数量为0.1，本金会自动乘以0.6。
    function _addOrder(address account, uint256 capitalBNB, uint256 nowTime) private {
        // 用户参与的BNB累计量，60%之后的。
        userAddBNBCount[account] += capitalBNB;
        require(userAddBNBCount[account] <= userBNBLimit, 'user bnb limit error');
        uint256 orderID = nextOrderID++;
        (uint256 dayReleaseBNB, uint256 canTakeBNBTotal) = getDayReleaseAndOutMul(capitalBNB, nowTime);
        userOrder[orderID] = UserOrderData({
            // capitalBNB: capitalBNB,
            dayReleaseBNB: dayReleaseBNB,
            takedBNBCount: 0,
            canTakeBNBTotal: canTakeBNBTotal,
            account: account,
            orderID: uint128(orderID),
            lastTakedTime: uint64(nowTime),
            isOut: 0
        });

        // 计算有效直推
        // 如果用户没有成为有效直推
        if(!userISValidJunior[account]) {
            _addValidJunior(account);
        }

        emit AccountAdd(orderID, account, capitalBNB, nowTime);
    }

    // 转入token直接添加订单
    function transferTokenAddOrder(address account, uint256 tokenAmount) public override onlyTokenAddress {
        require(account != address(0), 'zero address error');
        require(tokenAmount > 0, 'amount is zero error');
        // 先计算这些token价值多少BNB
        uint256 _priceBNB = getOneTokenPriceBNB();
        uint256 capitalBNB = tokenAmount * _priceBNB / 1e18;
        uint256 nowTime = block.timestamp;
        // 把币转给tokenTo地址
        TransferHelper.safeTransfer(Token_Address, tokenTo, tokenAmount);
        // 添加订单
        _addOrder(account, capitalBNB, nowTime);
    }

    // 管理员添加订单
    function addOrders(address[] memory accounts, uint256[] memory capitalBNBs) public onlyOwner {
        uint256 len = accounts.length;
        require(capitalBNBs.length == len, 'length error');
        uint256 nowTime = block.timestamp;
        for(uint256 i; i < len; i++) {
            address account = accounts[i];
            uint256 capitalBNB = capitalBNBs[i];
            require(account != address(0), 'address error');
            require(capitalBNB > 0, 'BNB Value error');
            _addOrder(account, capitalBNB, nowTime);
        }
    }

    // 增加有效用户
    function _addValidJunior(address account) private {
        // 质押数量满足了 && 有上级
        if(userAddBNBCount[account] >= superMinBNB && mySuper[account] != address(0)) {
            userISValidJunior[account] = true;
            userValidJunior[mySuper[account]] += 1;
        }
    }

    // 卖出token
    function _sellToken(address account, uint256 sellTokenAmount) private {
        // 准备卖出
        TransferHelper.safeTransferFrom(Token_Address, account, address(this), sellTokenAmount);
        address[] memory path = new address[](2);
        path[0] = Token_Address;
        path[1] = WBNB_Address;
        uint256 beforeBNBBalance = address(this).balance;
        IPancakeRouter02(Router_Address).swapExactTokensForETH(sellTokenAmount, 0, path, address(this), block.timestamp);
        uint256 lastBNBBalance = address(this).balance;
        uint256 getBNBAmount = lastBNBBalance - beforeBNBBalance; // 实际卖出获得的BNB数量
        require(getBNBAmount > 0, 'sell zero bnb');
        
        // 盈利税
        uint256 principalBNB = userAddBNBCount[account];  // 用户的本金
        uint256 sellBNBCount = userSellBNBCount[account]; // 用户的累计卖出
        uint256 beyondBNBTax;
        if(sellBNBCount + getBNBAmount > principalBNB) {
            // 超越了本金，需要支付盈利税
            beyondBNBTax = (sellBNBCount + getBNBAmount - principalBNB) * sellBeyondFeeRatio / DENOMINATOR; // 超出的部分
            userSellBNBCount[account] = principalBNB; // 累计卖出就等于本金, 刚刚好超越。
        }else {
            // 没有超越本金
            userSellBNBCount[account] += getBNBAmount;
        }
        // 卖出税
        uint256 sellBNBTax = getBNBAmount * sellMustFeeRatio / DENOMINATOR;
        // 用户自己所得
        uint256 userBNB = getBNBAmount - beyondBNBTax - sellBNBTax;

        // 转账
        if(beyondBNBTax > 0) TransferHelper.safeTransferETH(leader2, beyondBNBTax);
        if(sellBNBTax > 0) TransferHelper.safeTransferETH(leader2, sellBNBTax);
        require(userBNB > 0, 'user get zero error');
        TransferHelper.safeTransferETH(account, userBNB);
        // 卖出token, 会通缩池子50%.
        uint256 sellBurnTax = sellTokenAmount * sellBurnTokenRatio / DENOMINATOR;
        if(sellBurnTax > 0) IToken(Token_Address).burnLP(sellBurnTax);

        emit AccountSell(account, sellTokenAmount, userBNB, block.timestamp);
    }

    // 每天分红
    // 相当于用户质押LP，然后每日释放获得收益
    function everydayEarn(uint256 orderID) public onlyMinterAddress {
        uint256 price = getOneBNBPriceToken();
        uint256 nowTime = block.timestamp;
        _everydayEarn(price, orderID, nowTime);
    }

    // 分红多个
    function everydayEarnArr(uint256[] memory orderIDArr) public onlyMinterAddress {
        uint256 len = orderIDArr.length;
        uint256 price = getOneBNBPriceToken();
        uint256 nowTime = block.timestamp;
        for(uint256 i; i < len; i++) {
            _everydayEarn(price, orderIDArr[i], nowTime);
        }
    }

    // 自动分页空投
    // 包含开始id，也包含结束id
    function everydayEarnArrPage(uint256 startID, uint256 endID) public onlyMinterAddress {
        require(endID >= startID, 'id error');
        require(endID < nextOrderID, 'id too big');

        uint256 len = endID - startID + 1;
        uint256 price = getOneBNBPriceToken();
        uint256 nowTime = block.timestamp;
        for(uint256 i; i < len; i++) {
            uint256 orderID = startID + i;
            _everydayEarn(price, orderID, nowTime);
        }
    }

    function _everydayEarn(uint256 price, uint256 orderID, uint256 nowTime) private {
        // 计算收益
        UserOrderData storage OrderStorage = userOrder[orderID];
        address account = OrderStorage.account;
        require(account != address(0), 'zero address'); // 订单不存在
        if(OrderStorage.isOut == 1) return; // 发完了的
        if(blackList[account]) return; // 黑名单
        if(OrderStorage.lastTakedTime + takeIntervalTime > nowTime) return; // 间隔时间不足

        // 用户每天释放的数量，作为加速基数。
        uint256 earnBNBAmount = OrderStorage.dayReleaseBNB;
        // 给上级加速额度，最多20层
        address superAccount = account;
        for(uint256 i; i < 20; i++) {
            superAccount = mySuper[superAccount];
            if(superAccount == address(0)) break;                       // 遇到0地址就中断循环
            //uint256 superJuniorCount = userValidJunior[superAccount]; // 根据层级计算加速的数量
            if(userValidJunior[superAccount] >= superEarnRequireArr[i] && userAddBNBCount[superAccount] >= superMinBNB) {
                // 上级满足直推的数量 && 上级满足自己的质押量
                userSpeedBNBCount[superAccount] += (earnBNBAmount * bonusRateArr[i] / DENOMINATOR);
            }
        }

        // 计算用户可以领取的数量
        uint256 earnBNBAmountV2 = earnBNBAmount + userSpeedBNBCount[account]; // 增加下级给到的加速数量
        if(OrderStorage.takedBNBCount + earnBNBAmountV2 >= OrderStorage.canTakeBNBTotal) {
            earnBNBAmountV2 = OrderStorage.canTakeBNBTotal - OrderStorage.takedBNBCount;
            OrderStorage.isOut = 1;
        }
        // 判断使用了多少加速量
        if(earnBNBAmountV2 > earnBNBAmount) {
            // 用到了加速
            userSpeedBNBCount[account] -= (earnBNBAmountV2 - earnBNBAmount);
        }

        OrderStorage.takedBNBCount += earnBNBAmountV2;
        OrderStorage.lastTakedTime = uint64(nowTime);
        // 可以给到的数量
        uint256 mintTokenAmount = earnBNBAmountV2 * price / 1e18;
        if(mintTokenAmount > 0) {
            IToken(Token_Address).mint(account, mintTokenAmount);
        }
        emit DayEarn(orderID, account, mintTokenAmount);
    }

    // 获取价格，1BNB=多少个token
    function getOneBNBPriceToken() public view returns (uint256) {
        address token0Address = IUniswapV2Pair(WBNB_Token_LP_Address).token0();
        address token1Address = IUniswapV2Pair(WBNB_Token_LP_Address).token1();
        uint256 token0Balance = IERC20(token0Address).balanceOf(WBNB_Token_LP_Address);
        uint256 token1Balance = IERC20(token1Address).balanceOf(WBNB_Token_LP_Address);

        if(token0Address == Token_Address) {
            return token0Balance * 1e18 / token1Balance;
        }else {
            return token1Balance * 1e18 / token0Balance;
        }
    }

    // 获取价格，一个token=多少个BNB
    function getOneTokenPriceBNB() public view returns (uint256) {
        address token0Address = IUniswapV2Pair(WBNB_Token_LP_Address).token0();
        address token1Address = IUniswapV2Pair(WBNB_Token_LP_Address).token1();
        uint256 token0Balance = IERC20(token0Address).balanceOf(WBNB_Token_LP_Address);
        uint256 token1Balance = IERC20(token1Address).balanceOf(WBNB_Token_LP_Address);

        if(token0Address == Token_Address) {
            return token1Balance * 1e18 / token0Balance;
        }else {
            return token0Balance * 1e18 / token1Balance;
        }
    }

    // 订单开始。根据当前时间计算出每天释放的BNB数量和出局总量。
    function getDayReleaseAndOutMul(uint256 amount, uint256 time) public view returns(uint256 dayReleaseBNB, uint256 canTakeBNBTotal) {
        // 90天为一季度
        // 当前时间 - 项目开始时间
        uint256 index = (time - PROJECT_START_TIME) / (86400 * 90); 
        uint256 dayRelease;
        uint256 outMul;
        if(index == 0) {
            // 第一季度
            dayRelease = 100;
            outMul = 30000;
        }else if(index == 1) {
            // 第二季度
            dayRelease = 120;
            outMul = 32000;
        }else if(index == 2) {
            // 第三季度
            dayRelease = 140;
            outMul = 34000;
        }else if(index == 3) {
            // 第四季度
            dayRelease = 160;
            outMul = 36000;
        }else if(index == 4) {
            // 第五季度
            dayRelease = 180;
            outMul = 38000;
        }else {
            // 第六季度
            dayRelease = 200;
            outMul = 40000;
        }
        dayReleaseBNB = amount * dayRelease / DENOMINATOR;
        canTakeBNBTotal = amount * outMul / DENOMINATOR;
    }

    function setOther(address Token_Address_, address WBNB_Address_, address WBNB_Token_LP_Address_, address Router_Address_) external onlyOwner {
        require(Token_Address_ != address(0), 'error 1');
        require(WBNB_Address_ != address(0), 'error 2');
        require(WBNB_Token_LP_Address_ != address(0), 'error 3');
        require(Router_Address_ != address(0), 'error 4');

        Token_Address = Token_Address_;
        WBNB_Address = WBNB_Address_;
        WBNB_Token_LP_Address = WBNB_Token_LP_Address_;
        Router_Address = Router_Address_;
        TransferHelper.safeApprove(Token_Address, Router_Address, ~uint256(0));
    }

    function setLeader(address leader1_, address leader2_) external onlyOwner {
        require(leader1_ != address(0), 'error 1');
        require(leader2_ != address(0), 'error 2');
        leader1 = leader1_;
        leader2 = leader2_;
    }

    function setLpTo(address lpTo_) external onlyOwner {
        lpTo = lpTo_;
    }

    function setTokenTo(address tokenTo_) external onlyOwner {
        tokenTo = tokenTo_;
    }
    

    // 设置领取的间隔时间
    function setTakeIntervalTime(uint256 _takeIntervalTime) external onlyOwner {
        takeIntervalTime = _takeIntervalTime;
    }

    function setRatio(uint256 sellMustFeeRatio_, uint256 sellBeyondFeeRatio_, uint256 sellBurnTokenRatio_) external onlyOwner {
        require(sellMustFeeRatio_ + sellBeyondFeeRatio_ < DENOMINATOR, 'ratio error');
        require(sellBurnTokenRatio_ <= DENOMINATOR, 'sell ratio error'); // 最多销毁卖出的token比例为100%.
        sellMustFeeRatio = sellMustFeeRatio_;
        sellBeyondFeeRatio = sellBeyondFeeRatio_;
        sellBurnTokenRatio = sellBurnTokenRatio_;
    }

    function setBNBLimit(uint256 minBNB_, uint256 superMinBNB_, uint256 userBNBLimit_, bool whiteListOpen_) external onlyOwner {
        require(minBNB_ > SELL_BNB_LOWEST * 10, 'min error'); // 写死，避免产生数量校验冲突.
        require(userBNBLimit_ > 0, 'user bnb limit error');
        minBNB = minBNB_;
        superMinBNB = superMinBNB_;
        userBNBLimit = userBNBLimit_;
        whiteListOpen = whiteListOpen_;
    }
    
    function addWhiteLists(address[] memory accounts) external onlyOwner {
        uint256 len = accounts.length;
        for(uint256 i; i < len; i++) {
            whiteList[accounts[i]] = true;
        }
    }

    function removeWhiteLists(address[] memory accounts) external onlyOwner {
        uint256 len = accounts.length;
        for(uint256 i; i < len; i++) {
            whiteList[accounts[i]] = false;
        }
    }

    function setBlackLists(address[] memory accounts, bool isBlackList) external onlyOwner {
        uint256 len = accounts.length;
        for(uint256 i; i < len; i++) {
            blackList[accounts[i]] = isBlackList;
        }
    }
    
    // 后续可能会用到的预留接口
    function bonusTokenArrProxy(address token, address[] memory tos, uint256[] memory amounts) external onlyMinterAddress {
        IToken(Token_Address).bonusTokenArr(token, tos, amounts);
    }

    function bonusTokenArrV2Proxy(address[] memory tos, uint256[] memory amounts) external onlyMinterAddress {
        IToken(Token_Address).bonusTokenArrV2(tos, amounts);
    }

    function mintBounsTokenArrV3Proxy(address[] memory tos, uint256[] memory amounts) external onlyMinterAddress {
        IToken(Token_Address).mintBounsTokenArrV3(tos, amounts);
    }

    function bonusBNBArrProxy(address[] memory tos, uint256[] memory amounts) external onlyMinterAddress {
        IToken(Token_Address).bonusBNBArr(tos, amounts);
    }

    function burnLPProxy(uint256 amount) external onlyMinterAddress {
        IToken(Token_Address).burnLP(amount);
    }

    function mintProxy(address to, uint256 amount) external onlyMinterAddress {
        IToken(Token_Address).mint(to, amount);
    }


    receive() external payable {}

    
}
