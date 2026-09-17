// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title DAOStaking
/// @notice Single-pool staking with fixed-duration reward epochs, funded up front.
/// @dev Reward liability is strictly bounded: the contract pays at most what was
///      funded via `notifyRewardAmount` (no minting — compatible with fixed-supply
///      tokens like `DAOGovernanceToken`). Intended owner is the TimelockController,
///      so rates, durations, and rescues all pass governance. The owner can NEVER
///      move user stakes: no function exists for it (pinned by test).
///
///      VOTING-POWER CAVEAT: staked tokens pool under this contract's address, which
///      never delegates. Staked tokens earn yield but cast no votes until withdrawn.
///      This is inherent to ERC20Votes checkpointing, not a bug — frontends must say
///      so before a user stakes.
contract DAOStaking is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IERC20 public immutable stakingToken;
    IERC20 public immutable rewardsToken;

    uint256 public periodFinish;
    uint256 public rewardRate;
    uint256 public rewardsDuration;
    uint256 public lastUpdateTime;
    uint256 public rewardPerTokenStored;

    /// @dev Explicit reward-only balance. NEVER inferred from `balanceOf`:
    ///      when staking and reward tokens are the same contract, the raw
    ///      balance includes user stakes, so a balance-derived solvency check
    ///      would let an under-collateralized epoch pay "rewards" out of
    ///      pooled principal (first claimants drain later stakers).
    uint256 private _rewardBudget;

    mapping(address account => uint256 paid) public userRewardPerTokenPaid;
    mapping(address account => uint256 accrued) public rewards;

    uint256 private _totalSupply;
    mapping(address account => uint256 staked) private _balances;

    event Staked(address indexed account, uint256 amount);
    event Withdrawn(address indexed account, uint256 amount);
    event RewardPaid(address indexed account, uint256 amount);
    event RewardAdded(uint256 amount, uint256 newRate, uint256 newFinish);
    event RewardsDurationUpdated(uint256 newDuration);
    event Recovered(address indexed token, uint256 amount);

    error ZeroAmount();
    error InvalidDuration();
    error PeriodActive();
    error InsufficientRewardBudget(uint256 budget, uint256 required);
    error RewardRateZero();
    error CannotRecoverStakingToken();
    error RescueExceedsWithdrawable(uint256 available, uint256 requested);
    error InvalidAddress();

    constructor(IERC20 stakingToken_, IERC20 rewardsToken_, address timelockOwner, uint256 rewardsDuration_)
        Ownable(timelockOwner)
    {
        if (address(stakingToken_) == address(0) || address(rewardsToken_) == address(0)) revert InvalidAddress();
        if (timelockOwner == address(0)) revert InvalidAddress();
        if (rewardsDuration_ == 0) revert InvalidDuration();
        stakingToken = stakingToken_;
        rewardsToken = rewardsToken_;
        rewardsDuration = rewardsDuration_;
    }

    // ------------------------------------------------------------------
    // Views
    // ------------------------------------------------------------------

    function totalSupply() external view returns (uint256) {
        return _totalSupply;
    }

    function balanceOf(address account) external view returns (uint256) {
        return _balances[account];
    }

    function lastTimeRewardApplicable() public view returns (uint256) {
        return block.timestamp < periodFinish ? block.timestamp : periodFinish;
    }

    function rewardPerToken() public view returns (uint256) {
        if (_totalSupply == 0) return rewardPerTokenStored;
        return rewardPerTokenStored + ((lastTimeRewardApplicable() - lastUpdateTime) * rewardRate * 1e18) / _totalSupply;
    }

    function earned(address account) public view returns (uint256) {
        return (_balances[account] * (rewardPerToken() - userRewardPerTokenPaid[account])) / 1e18 + rewards[account];
    }

    // ------------------------------------------------------------------
    // User actions
    // ------------------------------------------------------------------

    modifier updateReward(address account) {
        rewardPerTokenStored = rewardPerToken();
        lastUpdateTime = lastTimeRewardApplicable();
        if (account != address(0)) {
            rewards[account] = earned(account);
            userRewardPerTokenPaid[account] = rewardPerTokenStored;
        }
        _;
    }

    /// @notice Lock `amount` of staking tokens. Caller must approve first.
    function stake(uint256 amount) external nonReentrant updateReward(msg.sender) {
        if (amount == 0) revert ZeroAmount();
        _totalSupply += amount;
        _balances[msg.sender] += amount;
        stakingToken.safeTransferFrom(msg.sender, address(this), amount);
        emit Staked(msg.sender, amount);
    }

    /// @notice Unlock staked tokens. Accrued rewards stay claimable via `getReward`.
    function withdraw(uint256 amount) external nonReentrant updateReward(msg.sender) {
        if (amount == 0) revert ZeroAmount();
        _totalSupply -= amount;
        _balances[msg.sender] -= amount;
        stakingToken.safeTransfer(msg.sender, amount);
        emit Withdrawn(msg.sender, amount);
    }

    /// @notice Claim all accrued reward tokens. Permissionless poke, pays the account.
    function getReward() external nonReentrant updateReward(msg.sender) {
        uint256 reward = rewards[msg.sender];
        if (reward > 0) {
            rewards[msg.sender] = 0;
            // Budget check is structural (solvent epochs only), not a trust
            // boundary: claims can never exceed what was actually funded.
            _rewardBudget -= reward;
            rewardsToken.safeTransfer(msg.sender, reward);
            emit RewardPaid(msg.sender, reward);
        }
    }

    /// @notice Withdraw everything and claim in one call.
    function exit() external nonReentrant updateReward(msg.sender) {
        uint256 staked = _balances[msg.sender];
        if (staked > 0) {
            _totalSupply -= staked;
            _balances[msg.sender] = 0;
            stakingToken.safeTransfer(msg.sender, staked);
            emit Withdrawn(msg.sender, staked);
        }
        uint256 reward = rewards[msg.sender];
        if (reward > 0) {
            rewards[msg.sender] = 0;
            _rewardBudget -= reward;
            rewardsToken.safeTransfer(msg.sender, reward);
            emit RewardPaid(msg.sender, reward);
        }
    }

    // ------------------------------------------------------------------
    // Governance (owner = timelock)
    // ------------------------------------------------------------------

    /// @notice Fund a reward epoch. Unspent leftover from a live epoch rolls over.
    /// @dev Caller must have transferred `reward` tokens here first (typically a
    ///      treasury package executed just before this call in the same proposal).
    ///      Funding is verified on-chain against `_availableRewards()` — physical
    ///      reward tokens net of staked principal and of the budget already
    ///      backing accrued-unpaid and unspent rewards — NEVER against a raw
    ///      `balanceOf`: with same-token staking the raw balance also holds user
    ///      stakes, which would silently back an unfunded epoch and drain staker
    ///      principal through "reward" payouts. Dust epochs that round to a zero
    ///      rate revert instead of paying nothing.
    function notifyRewardAmount(uint256 reward) external onlyOwner updateReward(address(0)) {
        if (reward == 0) revert ZeroAmount();
        if (block.timestamp >= periodFinish) {
            rewardRate = reward / rewardsDuration;
        } else {
            uint256 remaining = periodFinish - block.timestamp;
            uint256 leftover = remaining * rewardRate;
            rewardRate = (reward + leftover) / rewardsDuration;
        }
        if (rewardRate == 0) revert RewardRateZero();
        uint256 available = _availableRewards();
        if (available < reward) revert InsufficientRewardBudget(available, reward);
        _rewardBudget += reward;
        lastUpdateTime = block.timestamp;
        periodFinish = block.timestamp + rewardsDuration;
        emit RewardAdded(reward, rewardRate, periodFinish);
    }

    /// @notice Retarget epoch length. Only between epochs, so live rates never shift.
    function setRewardsDuration(uint256 rewardsDuration_) external onlyOwner {
        if (block.timestamp <= periodFinish) revert PeriodActive();
        if (rewardsDuration_ == 0) revert InvalidDuration();
        rewardsDuration = rewardsDuration_;
        emit RewardsDurationUpdated(rewardsDuration_);
    }

    /// @notice Rescue tokens sent here by mistake. Staking tokens are untouchable —
    ///         user stakes can never be recovered, only withdrawn by their owners.
    ///         Reward tokens are rescuable only ABOVE the unspent `_rewardBudget`
    ///         (genuine stray, e.g. an over-delivered funding transfer): the budget
    ///         backs accrued-but-unclaimed and in-flight epoch rewards, so a rescue
    ///         can never drain earned rewards — nor staked principal when staking
    ///         and reward tokens are the same contract (that balance is guarded by
    ///         the staking-token block).
    function recoverERC20(address token, uint256 amount) external onlyOwner {
        if (token == address(stakingToken)) revert CannotRecoverStakingToken();
        if (token == address(rewardsToken)) {
            uint256 balance = rewardsToken.balanceOf(address(this));
            uint256 available = balance > _rewardBudget ? balance - _rewardBudget : 0;
            if (amount > available) revert RescueExceedsWithdrawable(available, amount);
        }
        IERC20(token).safeTransfer(owner(), amount);
        emit Recovered(token, amount);
    }

    /// @notice Unspent reward funding backing future claims (audit view).
    function rewardBudget() external view returns (uint256) {
        return _rewardBudget;
    }

    /// @dev Physically available reward tokens: raw balance net of staked
    ///      principal (same-token config) and of the budget already backing
    ///      accrued-unpaid and unspent rewards. Never use raw `balanceOf`.
    function _availableRewards() private view returns (uint256) {
        uint256 balance = rewardsToken.balanceOf(address(this));
        uint256 staked = address(stakingToken) == address(rewardsToken) ? _totalSupply : 0;
        return balance > staked + _rewardBudget ? balance - staked - _rewardBudget : 0;
    }
}
