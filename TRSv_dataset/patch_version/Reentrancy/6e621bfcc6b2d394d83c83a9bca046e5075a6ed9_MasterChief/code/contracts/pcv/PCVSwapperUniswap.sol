// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;

import "./IPCVSwapper.sol";
import "../utils/Incentivized.sol";
import "../refs/OracleRef.sol";
import "../utils/Timed.sol";
import "../external/UniswapV2Library.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@uniswap/v2-periphery/contracts/interfaces/IWETH.sol";
import "@uniswap/v2-core/contracts/interfaces/IUniswapV2Pair.sol";

/// @title implementation for PCV Swapper that swaps ERC20 tokens on Uniswap
/// @author eswak
contract PCVSwapperUniswap is IPCVSwapper, OracleRef, Timed, Incentivized {
    using SafeERC20 for ERC20;
    using Decimal for Decimal.D256;

    // ----------- Events -----------	
    event UpdateMaximumSlippage(uint256 maximumSlippage);	
    event UpdateMaxSpentPerSwap(uint256 maxSpentPerSwap);	
    event UpdateInvertOraclePrice(bool invertOraclePrice);	
    event UpdateSwapIncentiveAmount(uint256 swapIncentiveAmount);

    /// @notice the token to spend on swap (outbound)
    address public immutable override tokenSpent;
    /// @notice the token to receive on swap (inbound)
    address public immutable override tokenReceived;
    /// @notice the address that will receive the inbound tokens
    address public override tokenReceivingAddress;
    /// @notice the maximum amount of tokens to spend on every swap
    uint256 public maxSpentPerSwap;
    /// @notice should we use (1 / oraclePrice) instead of oraclePrice ?
    bool public invertOraclePrice;
    /// @notice the maximum amount of slippage vs oracle price
    uint256 public maximumSlippageBasisPoints;
    uint256 public constant BASIS_POINTS_GRANULARITY = 10_000;

    /// @notice Uniswap pair to swap on
    IUniswapV2Pair public immutable pair;

    // solhint-disable-next-line var-name-mixedcase
    address public immutable WETH;

    constructor(
        address _core,
        IUniswapV2Pair _pair,
        // solhint-disable-next-line var-name-mixedcase
        address _WETH,
        address _oracle,
        uint256 _swapFrequency,
        address _tokenSpent,
        address _tokenReceived,
        address _tokenReceivingAddress,
        uint256 _maxSpentPerSwap,
        uint256 _maximumSlippageBasisPoints,
        bool _invertOraclePrice,
        uint256 _swapIncentiveAmount
    ) OracleRef(_core, _oracle) Timed(_swapFrequency) Incentivized(_swapIncentiveAmount) {
        pair = _pair;
        WETH = _WETH;
        tokenSpent = _tokenSpent;
        tokenReceived = _tokenReceived;
        tokenReceivingAddress = _tokenReceivingAddress;
        maxSpentPerSwap = _maxSpentPerSwap;
        maximumSlippageBasisPoints = _maximumSlippageBasisPoints;
        invertOraclePrice = _invertOraclePrice;

        // start timer
        _initTimed();
    }

	  /// @notice Empty callback on ETH reception	
    receive() external payable {}	

    // =======================================================================	
    // WETH management	
    // =======================================================================	

    /// @notice Wraps all ETH held by the contract to WETH	
    /// Anyone can call it	
    function wrapETH() public {	
        IWETH(WETH).deposit{value: address(this).balance}();	
    }

    // =======================================================================
    // IPCVDeposit interface override
    // =======================================================================

    /// @notice deposit tokenSpent
    function deposit() external override {
      // wrap any ETH
      if (address(this).balance != 0) {
        wrapETH();
      }
    }

    /// @notice withdraw tokenReceived from the contract
    /// @param to address destination of the ERC20
    /// @param amount quantity of tokenReceived to send
    function withdraw(address to, uint256 amount) external override onlyPCVController {
        withdrawERC20(tokenReceived, to, amount);
    }

    /// @notice Reads the balance of tokenReceived held in the contract
    function balance() external view override returns(uint256) {
      return ERC20(tokenReceived).balanceOf(address(this));
    }

    // =======================================================================
    // IPCVSwapper interface override
    // =======================================================================

    /// @notice withdraw ETH from the contract
    /// @param to address to send ETH
    /// @param amountOut amount of ETH to send
    function withdrawETH(address payable to, uint256 amountOut) external override onlyPCVController {
        IWETH(WETH).withdraw(amountOut);
        Address.sendValue(to, amountOut);
        emit WithdrawETH(msg.sender, to, amountOut);
    }

    /// @notice withdraw ERC20 from the contract
    /// @param token address of the ERC20 to send
    /// @param to address destination of the ERC20
    /// @param amount quantity of ERC20 to send
    function withdrawERC20(
      address token, 
      address to, 
      uint256 amount
    ) public override onlyPCVController {
        ERC20(token).safeTransfer(to, amount);
        emit WithdrawERC20(msg.sender, token, to, amount);
    }

    /// @notice Sets the address receiving swap's inbound tokens
    /// @param _tokenReceivingAddress the address that will receive tokens
    function setReceivingAddress(address _tokenReceivingAddress) external override onlyGovernor {
      tokenReceivingAddress = _tokenReceivingAddress;
      emit UpdateReceivingAddress(_tokenReceivingAddress);
    }

    // =======================================================================
    // Setters
    // =======================================================================

    /// @notice Sets the maximum slippage vs Oracle price accepted during swaps
    /// @param _maximumSlippageBasisPoints the maximum slippage expressed in basis points (1/10_000)
    function setMaximumSlippage(uint256 _maximumSlippageBasisPoints) external onlyGovernor {
        require(_maximumSlippageBasisPoints <= BASIS_POINTS_GRANULARITY, "PCVSwapperUniswap: Exceeds bp granularity.");
        maximumSlippageBasisPoints = _maximumSlippageBasisPoints;
        emit UpdateMaximumSlippage(_maximumSlippageBasisPoints);
    }

    /// @notice Sets the maximum tokens spent on each swap
    /// @param _maxSpentPerSwap the maximum number of tokens to be swapped on each call
    function setMaxSpentPerSwap(uint256 _maxSpentPerSwap) external onlyGovernor {
        require(_maxSpentPerSwap != 0, "PCVSwapperUniswap: Cannot swap 0.");
        maxSpentPerSwap = _maxSpentPerSwap;
        emit UpdateMaxSpentPerSwap(_maxSpentPerSwap);	
    }

    /// @notice sets the minimum time between swaps
    function setSwapFrequency(uint256 _duration) external onlyGovernor {
       _setDuration(_duration);
    }

    /// @notice sets invertOraclePrice : use (1 / oraclePrice) if true
    function setInvertOraclePrice(bool _invertOraclePrice) external onlyGovernor {
        invertOraclePrice = _invertOraclePrice;
	        emit UpdateInvertOraclePrice(_invertOraclePrice);	
    }

    // =======================================================================
    // External functions
    // =======================================================================

    /// @notice Swap tokenSpent for tokenReceived
    function swap() external override afterTime whenNotPaused {
	    // Reset timer	
      _initTimed();	
      // Update oracle, if necessary	
      if (oracle.isOutdated()) {	
        bool updated = updateOracle();	
        require(updated, "PCVSwapperUniswap: cannot update outdated oracle.");	
      }

      uint256 amountIn = _getExpectedAmountIn();
      uint256 amountOut = _getExpectedAmountOut(amountIn);
      uint256 minimumAcceptableAmountOut = _getMinimumAcceptableAmountOut(amountIn);

      // Check spot price vs oracle price discounted by max slippage
      // E.g. for a max slippage of 3%, spot price must be >= 97% oraclePrice
      require(minimumAcceptableAmountOut <= amountOut, "PCVSwapperUniswap: slippage too high.");

      // Perform swap
      ERC20(tokenSpent).safeTransfer(address(pair), amountIn);
      (uint256 amount0Out, uint256 amount1Out) =
          pair.token0() == address(tokenSpent)
              ? (uint256(0), amountOut)
              : (amountOut, uint256(0));
      pair.swap(amount0Out, amount1Out, tokenReceivingAddress, new bytes(0));

      // Emit event
      emit Swap(
        msg.sender,
        tokenSpent,
        tokenReceived,
        amountIn,
        amountOut
      );

      // Incentivize call with FEI rewards
      _incentivize();
    }

    // =======================================================================
    // Internal functions
    // =======================================================================

    /// @notice see external function getNextAmountSpent()
    function _getExpectedAmountIn() internal view returns (uint256) {
      uint256 balance = ERC20(tokenSpent).balanceOf(address(this));
      require(balance != 0, "PCVSwapperUniswap: no tokenSpent left.");
      return Math.min(maxSpentPerSwap, balance);
    }

    /// @notice see external function getNextAmountReceived()
    function _getExpectedAmountOut(uint256 amountIn) internal view returns (uint256) {
      // Get pair reserves
      (uint256 _token0, uint256 _token1, ) = pair.getReserves();
      (uint256 tokenSpentReserves, uint256 tokenReceivedReserves) =
          pair.token0() == tokenSpent
              ? (_token0, _token1)
              : (_token1, _token0);

      // Prepare swap
      uint256 amountOut = UniswapV2Library.getAmountOut(
        amountIn,
        tokenSpentReserves,
        tokenReceivedReserves
      );

      return amountOut;
    }

    /// @notice see external function getNextAmountReceivedThreshold()
    function _getMinimumAcceptableAmountOut(uint256 amountIn) internal view returns (uint256) {
      Decimal.D256 memory twap = readOracle();
      if (invertOraclePrice) {
        twap = invert(twap);
      }
      Decimal.D256 memory oracleAmountOut = twap.mul(amountIn);
      Decimal.D256 memory maxSlippage = Decimal.ratio(BASIS_POINTS_GRANULARITY - maximumSlippageBasisPoints, BASIS_POINTS_GRANULARITY);
      (uint256 decimalNormalizer, bool normalizerDirection) = _getDecimalNormalizer();
      Decimal.D256 memory oraclePriceMinusSlippage;
      if (normalizerDirection) {
        oraclePriceMinusSlippage = maxSlippage.mul(oracleAmountOut).div(decimalNormalizer);
      } else {
        oraclePriceMinusSlippage = maxSlippage.mul(oracleAmountOut).mul(decimalNormalizer);
      }
      return oraclePriceMinusSlippage.asUint256();
    }

    /// @notice see external function getDecimalNormalizer()
    function _getDecimalNormalizer() internal view returns (uint256, bool) {
      uint8 decimalsTokenSpent = ERC20(tokenSpent).decimals();
      uint8 decimalsTokenReceived = ERC20(tokenReceived).decimals();

      uint256 n;
      bool direction;
      if (decimalsTokenSpent >= decimalsTokenReceived) {
        direction = true;
        n = uint256(10) ** uint256(decimalsTokenSpent - decimalsTokenReceived);
      } else {
        direction = false;
        n = uint256(10) ** uint256(decimalsTokenReceived - decimalsTokenSpent);
      }
      return (n, direction);
    }
}
