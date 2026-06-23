// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/*//////////////////////////////////////////////////////////////
                            INTERFACES
//////////////////////////////////////////////////////////////*/

interface IERC20 {
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);
}

/*//////////////////////////////////////////////////////////////
                        SAFE TRANSFER LIB
//////////////////////////////////////////////////////////////*/

/// @dev Handles tokens that don't return a bool (USDT-style) and reverts on failure.
library SafeTransfer {
    function safeTransfer(IERC20 token, address to, uint256 amount) internal {
        (bool ok, bytes memory data) =
            address(token).call(abi.encodeWithSelector(token.transfer.selector, to, amount));
        require(ok && (data.length == 0 || abi.decode(data, (bool))), "TRANSFER_FAILED");
    }

    function safeTransferFrom(IERC20 token, address from, address to, uint256 amount) internal {
        (bool ok, bytes memory data) =
            address(token).call(abi.encodeWithSelector(token.transferFrom.selector, from, to, amount));
        require(ok && (data.length == 0 || abi.decode(data, (bool))), "TRANSFER_FROM_FAILED");
    }
}

/*//////////////////////////////////////////////////////////////
                          MINIMAL ERC20
                  (the pool's own LP-share token)
//////////////////////////////////////////////////////////////*/

contract LPToken is IERC20 {
    string public name = "AMM LP Token";
    string public symbol = "AMM-LP";
    uint8 public constant decimals = 18;

    uint256 public override totalSupply;
    mapping(address => uint256) public override balanceOf;
    mapping(address => mapping(address => uint256)) public override allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    function approve(address spender, uint256 amount) external override returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external override returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external override returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) {
            allowance[from][msg.sender] = allowed - amount;
        }
        _transfer(from, to, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) internal {
        balanceOf[from] -= amount;
        unchecked { balanceOf[to] += amount; }
        emit Transfer(from, to, amount);
    }

    function _mint(address to, uint256 amount) internal {
        totalSupply += amount;
        unchecked { balanceOf[to] += amount; }
        emit Transfer(address(0), to, amount);
    }

    function _burn(address from, uint256 amount) internal {
        balanceOf[from] -= amount;
        unchecked { totalSupply -= amount; }
        emit Transfer(from, address(0), amount);
    }
}

/*//////////////////////////////////////////////////////////////
                            AMM PAIR
//////////////////////////////////////////////////////////////*/

/// @title AMMPair
/// @notice Constant-product (x * y = k) market maker for a single token pair.
///         The contract IS the LP token: depositors receive shares proportional
///         to their contribution, and the 0.3% swap fee accrues to the pool,
///         increasing the value of every share.
contract AMMPair is LPToken {
    using SafeTransfer for IERC20;

    /*//////////////////// CONSTANTS ////////////////////*/

    /// @dev Permanently locked on the first deposit to block the
    ///      "first depositor" share-price inflation/donation attack.
    uint256 public constant MINIMUM_LIQUIDITY = 1_000;

    /// @dev Fee numerator/denominator: 997/1000 => 0.30% fee.
    uint256 private constant FEE_NUM = 997;
    uint256 private constant FEE_DEN = 1000;

    /*//////////////////// STATE ////////////////////*/

    IERC20 public immutable token0;
    IERC20 public immutable token1;

    // Cached reserves. Updated after every state-changing action so that
    // direct token donations to the contract don't silently skew pricing.
    uint112 private reserve0;
    uint112 private reserve1;

    /*//////////////////// REENTRANCY GUARD ////////////////////*/

    uint256 private locked = 1;
    modifier nonReentrant() {
        require(locked == 1, "REENTRANT");
        locked = 2;
        _;
        locked = 1;
    }

    /*//////////////////// EVENTS ////////////////////*/

    event Mint(address indexed sender, uint256 amount0, uint256 amount1, uint256 liquidity);
    event Burn(address indexed sender, uint256 amount0, uint256 amount1, address indexed to);
    event Swap(
        address indexed sender,
        uint256 amount0In,
        uint256 amount1In,
        uint256 amount0Out,
        uint256 amount1Out,
        address indexed to
    );
    event Sync(uint112 reserve0, uint112 reserve1);

    constructor(address _token0, address _token1) {
        require(_token0 != _token1, "IDENTICAL_TOKENS");
        require(_token0 != address(0) && _token1 != address(0), "ZERO_ADDRESS");
        // Order tokens deterministically so a pair has a canonical (token0, token1).
        (token0, token1) = _token0 < _token1
            ? (IERC20(_token0), IERC20(_token1))
            : (IERC20(_token1), IERC20(_token0));
    }

    /*//////////////////// VIEWS ////////////////////*/

    function getReserves() public view returns (uint112 _reserve0, uint112 _reserve1) {
        return (reserve0, reserve1);
    }

    /// @notice Pure pricing function: how many output tokens for a given input,
    ///         applying the 0.3% fee. This is the heart of x*y=k.
    ///
    ///         Without fees: (x + dx)(y - dy) = x*y  =>  dy = y*dx / (x + dx)
    ///         With fee on input dx' = dx*997/1000:
    ///             dy = (dx*997 * y) / (x*1000 + dx*997)
    function getAmountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut)
        public
        pure
        returns (uint256 amountOut)
    {
        require(amountIn > 0, "INSUFFICIENT_INPUT");
        require(reserveIn > 0 && reserveOut > 0, "INSUFFICIENT_LIQUIDITY");
        uint256 amountInWithFee = amountIn * FEE_NUM;
        uint256 numerator = amountInWithFee * reserveOut;
        uint256 denominator = reserveIn * FEE_DEN + amountInWithFee;
        amountOut = numerator / denominator;
    }

    /// @notice Inverse: input required to receive an exact `amountOut`.
    function getAmountIn(uint256 amountOut, uint256 reserveIn, uint256 reserveOut)
        public
        pure
        returns (uint256 amountIn)
    {
        require(amountOut > 0, "INSUFFICIENT_OUTPUT");
        require(reserveIn > 0 && reserveOut > 0, "INSUFFICIENT_LIQUIDITY");
        require(amountOut < reserveOut, "OUTPUT_EXCEEDS_RESERVE");
        uint256 numerator = reserveIn * amountOut * FEE_DEN;
        uint256 denominator = (reserveOut - amountOut) * FEE_NUM;
        amountIn = (numerator / denominator) + 1; // round up in pool's favor
    }

    /*//////////////////// LIQUIDITY ////////////////////*/

    /// @notice Add liquidity. Caller must approve this contract for both tokens first.
    /// @param amount0Desired / amount1Desired  Amounts the caller is willing to deposit.
    /// @param amount0Min / amount1Min          Slippage guards (reverts if ratio moved).
    /// @param to                               Recipient of the minted LP shares.
    function addLiquidity(
        uint256 amount0Desired,
        uint256 amount1Desired,
        uint256 amount0Min,
        uint256 amount1Min,
        address to
    ) external nonReentrant returns (uint256 amount0, uint256 amount1, uint256 liquidity) {
        (uint112 _reserve0, uint112 _reserve1) = getReserves();

        if (_reserve0 == 0 && _reserve1 == 0) {
            // First deposit defines the initial price; take the desired amounts as-is.
            (amount0, amount1) = (amount0Desired, amount1Desired);
        } else {
            // Keep the pool ratio constant. Compute the optimal counter-amount.
            uint256 amount1Optimal = (amount0Desired * _reserve1) / _reserve0;
            if (amount1Optimal <= amount1Desired) {
                require(amount1Optimal >= amount1Min, "INSUFFICIENT_1_AMOUNT");
                (amount0, amount1) = (amount0Desired, amount1Optimal);
            } else {
                uint256 amount0Optimal = (amount1Desired * _reserve0) / _reserve1;
                assert(amount0Optimal <= amount0Desired);
                require(amount0Optimal >= amount0Min, "INSUFFICIENT_0_AMOUNT");
                (amount0, amount1) = (amount0Optimal, amount1Desired);
            }
        }

        // Pull tokens in.
        token0.safeTransferFrom(msg.sender, address(this), amount0);
        token1.safeTransferFrom(msg.sender, address(this), amount1);

        uint256 _totalSupply = totalSupply;
        if (_totalSupply == 0) {
            // Geometric mean of deposits; lock MINIMUM_LIQUIDITY forever.
            liquidity = _sqrt(amount0 * amount1) - MINIMUM_LIQUIDITY;
            _mint(address(0xdead), MINIMUM_LIQUIDITY);
        } else {
            // Proportional to the smaller-side contribution to avoid free shares.
            liquidity = _min(
                (amount0 * _totalSupply) / _reserve0,
                (amount1 * _totalSupply) / _reserve1
            );
        }
        require(liquidity > 0, "INSUFFICIENT_LIQUIDITY_MINTED");
        _mint(to, liquidity);

        _update();
        emit Mint(msg.sender, amount0, amount1, liquidity);
    }

    /// @notice Burn LP shares and withdraw the underlying pro-rata.
    function removeLiquidity(
        uint256 liquidity,
        uint256 amount0Min,
        uint256 amount1Min,
        address to
    ) external nonReentrant returns (uint256 amount0, uint256 amount1) {
        require(liquidity > 0, "ZERO_LIQUIDITY");

        uint256 bal0 = token0.balanceOf(address(this));
        uint256 bal1 = token1.balanceOf(address(this));
        uint256 _totalSupply = totalSupply;

        // Pro-rata claim on actual balances.
        amount0 = (liquidity * bal0) / _totalSupply;
        amount1 = (liquidity * bal1) / _totalSupply;
        require(amount0 > 0 && amount1 > 0, "INSUFFICIENT_LIQUIDITY_BURNED");
        require(amount0 >= amount0Min && amount1 >= amount1Min, "SLIPPAGE");

        _burn(msg.sender, liquidity);
        token0.safeTransfer(to, amount0);
        token1.safeTransfer(to, amount1);

        _update();
        emit Burn(msg.sender, amount0, amount1, to);
    }

    /*//////////////////// SWAP ////////////////////*/

    /// @notice Swap an exact input amount of one token for the other.
    /// @param zeroForOne   true: sell token0 for token1; false: the reverse.
    /// @param amountIn     exact input amount (caller must have approved).
    /// @param amountOutMin slippage guard.
    function swapExactIn(
        bool zeroForOne,
        uint256 amountIn,
        uint256 amountOutMin,
        address to
    ) external nonReentrant returns (uint256 amountOut) {
        require(amountIn > 0, "ZERO_INPUT");
        require(to != address(token0) && to != address(token1), "INVALID_TO");
        (uint112 _reserve0, uint112 _reserve1) = getReserves();

        (IERC20 tokenIn, IERC20 tokenOut, uint256 reserveIn, uint256 reserveOut) = zeroForOne
            ? (token0, token1, uint256(_reserve0), uint256(_reserve1))
            : (token1, token0, uint256(_reserve1), uint256(_reserve0));

        amountOut = getAmountOut(amountIn, reserveIn, reserveOut);
        require(amountOut >= amountOutMin, "SLIPPAGE");

        tokenIn.safeTransferFrom(msg.sender, address(this), amountIn);
        tokenOut.safeTransfer(to, amountOut);

        // Verify the constant-product invariant did not decrease (defense in depth).
        _checkK(_reserve0, _reserve1);
        _update();

        (uint256 a0In, uint256 a1In, uint256 a0Out, uint256 a1Out) = zeroForOne
            ? (amountIn, uint256(0), uint256(0), amountOut)
            : (uint256(0), amountIn, amountOut, uint256(0));
        emit Swap(msg.sender, a0In, a1In, a0Out, a1Out, to);
    }

    /*//////////////////// INTERNAL ////////////////////*/

    /// @dev Sync cached reserves to real balances.
    function _update() private {
        uint256 bal0 = token0.balanceOf(address(this));
        uint256 bal1 = token1.balanceOf(address(this));
        require(bal0 <= type(uint112).max && bal1 <= type(uint112).max, "OVERFLOW");
        reserve0 = uint112(bal0);
        reserve1 = uint112(bal1);
        emit Sync(reserve0, reserve1);
    }

    /// @dev After a swap, (bal0*1000 - in0*3)(bal1*1000 - in1*3) >= reserve0*reserve1*1000^2.
    ///      This re-derives k from real balances so a malformed swap can't drain the pool.
    function _checkK(uint112 _reserve0, uint112 _reserve1) private view {
        uint256 bal0 = token0.balanceOf(address(this));
        uint256 bal1 = token1.balanceOf(address(this));
        uint256 in0 = bal0 > _reserve0 ? bal0 - _reserve0 : 0;
        uint256 in1 = bal1 > _reserve1 ? bal1 - _reserve1 : 0;
        uint256 adj0 = bal0 * FEE_DEN - in0 * (FEE_DEN - FEE_NUM);
        uint256 adj1 = bal1 * FEE_DEN - in1 * (FEE_DEN - FEE_NUM);
        require(
            adj0 * adj1 >= uint256(_reserve0) * uint256(_reserve1) * (FEE_DEN * FEE_DEN),
            "K"
        );
    }

    function _sqrt(uint256 y) internal pure returns (uint256 z) {
        if (y > 3) {
            z = y;
            uint256 x = y / 2 + 1;
            while (x < z) {
                z = x;
                x = (y / x + x) / 2;
            }
        } else if (y != 0) {
            z = 1;
        }
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }
}
