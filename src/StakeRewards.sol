// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Network} from "./Network.sol";

/// @notice Seven-day IMD streams. Unstaked time and rate-division dust carry into the next deposit.
contract StakeRewards is Network, ReentrancyGuard {
    using SafeERC20 for IERC20;

    error NotVault();
    error NotJobsVault();
    error AlreadySet();
    error InvalidAddress();
    error TokenNotSet();
    error ZeroAmount();
    error StakeLocked(uint256 until);
    error InsufficientStake();

    event TokenSet(address indexed token);
    event JobsVaultSet(address indexed jobsVault);
    event Staked(address indexed account, uint256 received);
    event Withdrawn(address indexed account, uint256 amount);
    event RewardPaid(address indexed account, uint256 amount);
    event DepositNotified(uint256 received, uint256 rewardRate, uint256 periodFinish);
    event Locked(address indexed account, uint256 until);

    uint256 public constant SCALE = 1e36;
    uint256 public constant DURATION = 7 days;
    address public immutable vault;
    address public token;
    address public jobsVault;
    uint256 public totalStaked;
    uint256 public periodFinish;
    uint256 public lastUpdate;
    /// @notice Scaled IMD per second (not raw token units per second).
    uint256 public rewardRate;
    uint256 public rewardPerTokenStored;
    uint256 public carryScaled;
    /// @notice All notified IMD less paid claims, including carry and rounding dust.
    uint256 public reserved;
    mapping(address => uint256) public stakeOf;
    mapping(address => uint256) public rewards;
    mapping(address => uint256) public rewardPerTokenPaid;
    mapping(address => uint256) public lockedUntil;

    constructor(address vault_) {
        if (vault_ == address(0)) revert InvalidAddress();
        vault = vault_;
    }

    modifier onlyVault() {
        if (msg.sender != vault) revert NotVault();
        _;
    }

    function setToken(address token_) external onlyVault {
        if (token != address(0)) revert AlreadySet();
        if (token_ == IMD || token_.code.length == 0) revert InvalidAddress();
        token = token_;
        emit TokenSet(token_);
    }

    function setJobsVault(address jobsVault_) external onlyVault {
        if (jobsVault != address(0)) revert AlreadySet();
        if (jobsVault_ == address(0)) revert InvalidAddress();
        jobsVault = jobsVault_;
        emit JobsVaultSet(jobsVault_);
    }

    function lock(address account, uint256 until) external {
        if (msg.sender != jobsVault) revert NotJobsVault();
        if (until > lockedUntil[account]) {
            lockedUntil[account] = until;
            emit Locked(account, until);
        }
    }

    function rewardPerToken() public view returns (uint256) {
        uint256 t = Math.min(block.timestamp, periodFinish);
        if (totalStaked == 0 || t <= lastUpdate) return rewardPerTokenStored;
        return rewardPerTokenStored + (t - lastUpdate) * rewardRate / totalStaked;
    }

    function earned(address account) public view returns (uint256) {
        return rewards[account] + Math.mulDiv(stakeOf[account], rewardPerToken() - rewardPerTokenPaid[account], SCALE);
    }

    function notifyDeposit() external onlyVault nonReentrant {
        _update(address(0));
        uint256 received = IERC20(IMD).balanceOf(address(this)) - reserved;
        if (received == 0) return;
        reserved += received;
        uint256 total = received * SCALE + carryScaled;
        if (block.timestamp < periodFinish) total += (periodFinish - block.timestamp) * rewardRate;
        rewardRate = total / DURATION;
        carryScaled = total % DURATION;
        lastUpdate = block.timestamp;
        periodFinish = block.timestamp + DURATION;
        emit DepositNotified(received, rewardRate, periodFinish);
    }

    function stake(uint256 amount) external nonReentrant {
        if (token == address(0)) revert TokenNotSet();
        if (amount == 0) revert ZeroAmount();
        _update(msg.sender);
        uint256 beforeBalance = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = IERC20(token).balanceOf(address(this)) - beforeBalance;
        if (received == 0) revert ZeroAmount();
        stakeOf[msg.sender] += received;
        totalStaked += received;
        emit Staked(msg.sender, received);
    }

    function withdraw(uint256 amount) external nonReentrant {
        _withdraw(amount);
    }

    function claim() external nonReentrant {
        _update(msg.sender);
        _claim();
    }

    function exit() external nonReentrant {
        _withdraw(stakeOf[msg.sender]);
        _claim();
    }

    function _update(address account) private {
        uint256 t = Math.min(block.timestamp, periodFinish);
        if (t > lastUpdate) {
            uint256 streamed = (t - lastUpdate) * rewardRate;
            if (totalStaked == 0) carryScaled += streamed;
            else rewardPerTokenStored += streamed / totalStaked;
            lastUpdate = t;
        }
        if (account != address(0)) {
            rewards[account] = earned(account);
            rewardPerTokenPaid[account] = rewardPerTokenStored;
        }
    }

    function _withdraw(uint256 amount) private {
        if (block.timestamp < lockedUntil[msg.sender]) revert StakeLocked(lockedUntil[msg.sender]);
        _update(msg.sender);
        if (amount > stakeOf[msg.sender]) revert InsufficientStake();
        stakeOf[msg.sender] -= amount;
        totalStaked -= amount;
        if (amount != 0) IERC20(token).safeTransfer(msg.sender, amount);
        emit Withdrawn(msg.sender, amount);
    }

    function _claim() private {
        uint256 amount = rewards[msg.sender];
        if (amount == 0) return;
        rewards[msg.sender] = 0;
        reserved -= amount;
        IERC20(IMD).safeTransfer(msg.sender, amount);
        emit RewardPaid(msg.sender, amount);
    }
}
