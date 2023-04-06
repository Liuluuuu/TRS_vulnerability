// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;

import "../refs/CoreRef.sol";
import "../utils/Incentivized.sol";
import "../utils/Timed.sol";
import "./IRewardsDistributor.sol";
import "../external/Decimal.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

/// @title Distributor for TRIBE rewards to the staking contract
/// @author Fei Protocol
/// @notice distributes TRIBE over time at a linearly decreasing rate
contract FeiRewardsDistributor is IRewardsDistributor, CoreRef, Timed, Incentivized {
    using Decimal for Decimal.D256;

    uint256 public override distributedRewards;

    IStakingRewards public override stakingContract;

    uint256 public override lastDistributionTime;

    uint256 public override dripFrequency;

    constructor(
        address _core,
        address _stakingContract,
        uint256 _duration,
        uint256 _frequency,
        uint256 _incentiveAmount
    ) 
        CoreRef(_core) 
        Timed(_duration)
        Incentivized(_incentiveAmount)
    {
        require(_duration >= _frequency, "FeiRewardsDistributor: frequency exceeds duration");
        stakingContract = IStakingRewards(_stakingContract);
        dripFrequency = _frequency;

        lastDistributionTime = block.timestamp;

        _initTimed();
    }

    /// @notice sends the unlocked amount of TRIBE to the stakingRewards contract
    /// @return amount of TRIBE sent
    function drip() public override whenNotPaused returns(uint256) {
        require(isDripAvailable(), "FeiRewardsDistributor: Not passed drip frequency");
        lastDistributionTime = block.timestamp;

        uint256 amount = releasedReward();
        require(amount != 0, "FeiRewardsDistributor: no rewards");
        distributedRewards = distributedRewards + amount;

        tribe().transfer(address(stakingContract), amount);
        stakingContract.notifyRewardAmount(amount);

        _incentivize();
        
        emit Drip(msg.sender, amount);
        return amount;
    }

    /// @notice sends tokens back to governance treasury. Only callable by governance
    /// @param amount the amount of tokens to send back to treasury
    function governorWithdrawTribe(uint256 amount) external override onlyGovernor {
        tribe().transfer(address(core()), amount);
        emit TribeWithdraw(amount);
    }

    /// @notice sends tokens back to governance treasury. Only callable by governance
    /// @param amount the amount of tokens to send back to treasury
    function governorRecover(address tokenAddress, address to, uint256 amount) external override onlyGovernor {
        stakingContract.recoverERC20(tokenAddress, to, amount);
    }

    /// @notice sets the drip frequency
    function setDripFrequency(uint256 _frequency) external override onlyGovernor {
        dripFrequency = _frequency;
        emit FrequencyUpdate(_frequency);
    }

    /// @notice sets the staking contract to send TRIBE rewards to
    function setStakingContract(address _stakingContract) external override onlyGovernor {
        stakingContract = IStakingRewards(_stakingContract);
        emit StakingContractUpdate(_stakingContract);
    }

    /// @notice returns the block timestamp when drip will next be available
    function nextDripAvailable() public view override returns (uint256) {
        return lastDistributionTime + dripFrequency;
    }

    /// @notice return true if the dripFrequency has passed since the last drip
    function isDripAvailable() public view override returns (bool) {
        return block.timestamp >= nextDripAvailable();
    }

    /// @notice the total amount of rewards owned by contract and unlocked for release
    function releasedReward() public view override returns (uint256) {
        uint256 total = rewardBalance();
        uint256 unreleased = unreleasedReward();
        return total - unreleased;
    }
    
    /// @notice the total amount of rewards distributed by the contract over entire period
    function totalReward() public view override returns (uint256) {
        return rewardBalance() + distributedRewards;
    }

    /// @notice the total balance of rewards owned by contract, locked or unlocked
    function rewardBalance() public view override returns (uint256) {
        return tribeBalance();
    }

    /// @notice the total amount of rewards owned by contract and locked
    function unreleasedReward() public view override returns (uint256) {
        if (isTimeEnded()) {
            return 0;
        }
        
        return
            _unreleasedReward(
                totalReward(),
                duration,
                timeSinceStart()
            );
    }

    // Represents the integral of 2R/d - 2R/d^2 x dx from t to d
    // Integral equals 2Rx/d - Rx^2/d^2
    // Evaluated at t = 2R*t/d (start) - R*t^2/d^2 (end)
    // Evaluated at d = 2R - R = R
    // Solution = R - (start - end) or equivalently end + R - start (latter more convenient to code)
    function _unreleasedReward(
        uint256 _totalReward,
        uint256 _duration,
        uint256 _time
    ) internal pure returns (uint256) {
        // 2R*t/d
        Decimal.D256 memory start =
            Decimal.ratio(_totalReward, _duration).mul(2).mul(_time);

        // R*t^2/d^2
        Decimal.D256 memory end =
            Decimal.ratio(_totalReward, _duration).div(_duration).mul(
                _time * _time
            );

        return end.add(_totalReward).sub(start).asUint256();
    }
}
