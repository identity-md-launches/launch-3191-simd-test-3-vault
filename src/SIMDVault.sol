// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Network} from "./Network.sol";
import {StakeRewards} from "./StakeRewards.sol";
import {JobsVault} from "./JobsVault.sol";
import {SimdAirdrop} from "./SimdAirdrop.sol";
import {ILaunchFactory} from "./interfaces/ILaunchFactory.sol";
import {IntakePayment} from "./libraries/IntakePayment.sol";
import {LaunchPool} from "./libraries/LaunchPool.sol";

/// @notice Pays for the test launch and permanently receives and splits its requester fees.
contract SIMDVault is Network, ReentrancyGuard {
    using SafeERC20 for IERC20;

    error NotDev();
    error AlreadyLaunched();
    error AlreadyBound();
    error NotBound();
    error WrongToken();
    error TooSoon(uint256 availableAt);

    event LaunchRequested(bytes32 indexed requestId, uint256 price);
    event LaunchBound(uint64 indexed launchNumber, address indexed token);
    event AirdropBindAttempt(bool success);
    event FeesClaimAttempt(bool success);
    event Distributed(uint256 staking, uint256 jobs, uint256 dev, uint256 marketing);
    event TokenBurnAttempt(uint256 amount, bool success);
    event NativePushAttempt(uint256 amount, bool success);

    bytes32 public constant ACTION = bytes32("launch.open@launch-1");
    uint256 public constant INTERVAL = 7 days;
    uint256 public constant CLAIM_GAS = 1_000_000;
    uint256 public constant NATIVE_GAS = 50_000;
    uint256 public constant TOKEN_BALANCE_GAS = 50_000;
    uint256 public constant TOKEN_BURN_GAS = 200_000;
    StakeRewards public immutable stakeRewards;
    JobsVault public immutable jobsVault;
    SimdAirdrop public immutable airdrop;
    bool public launched;
    address public token;
    uint64 public launchNumber;
    uint256 public nextDistributionAt;

    constructor() {
        StakeRewards rewards = new StakeRewards(address(this));
        stakeRewards = rewards;
        JobsVault jobs = new JobsVault(address(this), rewards);
        jobsVault = jobs;
        airdrop = new SimdAirdrop(address(this));
        rewards.setJobsVault(address(jobs));
    }

    modifier onlyDev() {
        if (msg.sender != DEV) revert NotDev();
        _;
    }

    function launch(bytes calldata body) external onlyDev nonReentrant returns (bytes32 requestId) {
        if (launched) revert AlreadyLaunched();
        launched = true;
        uint256 price;
        (requestId, price) = IntakePayment.request(INTAKE, IMD, ACTION, body);
        emit LaunchRequested(requestId, price);
    }

    function bindLaunch(uint64 number, address token_) external onlyDev nonReentrant {
        if (token != address(0)) revert AlreadyBound();
        if (LaunchPool.tokenOf(FACTORY, number, address(this), IMD) != token_) revert WrongToken();
        token = token_;
        launchNumber = number;
        stakeRewards.setToken(token_);
        jobsVault.setToken(token_);
        emit LaunchBound(number, token_);
        try airdrop.bind(number) {
            emit AirdropBindAttempt(true);
        } catch {
            emit AirdropBindAttempt(false);
        }
    }

    function bindAirdrop() external nonReentrant {
        if (token == address(0)) revert NotBound();
        airdrop.bind(launchNumber);
        emit AirdropBindAttempt(true);
    }

    function distribute() external nonReentrant {
        if (token == address(0)) revert NotBound();
        if (block.timestamp < nextDistributionAt) revert TooSoon(nextDistributionAt);
        nextDistributionAt = block.timestamp + INTERVAL;
        try ILaunchFactory(FACTORY).claimFees{gas: CLAIM_GAS}(launchNumber) returns (uint256, uint256) {
            emit FeesClaimAttempt(true);
        } catch {
            emit FeesClaimAttempt(false);
        }

        IERC20 imd = IERC20(IMD);
        uint256 balance = imd.balanceOf(address(this));
        uint256 staking = Math.mulDiv(balance, 4000, 10_000);
        uint256 jobs = Math.mulDiv(balance, 2572, 10_000);
        uint256 dev = Math.mulDiv(balance, 1714, 10_000);
        uint256 marketing = Math.mulDiv(balance, 1714, 10_000);
        // Send all units: at most three wei of rounding dust goes to the final recipient.
        marketing += balance - staking - jobs - dev - marketing;
        if (staking != 0) imd.safeTransfer(address(stakeRewards), staking);
        stakeRewards.notifyDeposit();
        if (jobs != 0) imd.safeTransfer(address(jobsVault), jobs);
        if (dev != 0) imd.safeTransfer(DEV, dev);
        if (marketing != 0) imd.safeTransfer(MARKETING, marketing);
        emit Distributed(staking, jobs, dev, marketing);

        _burnToken();
        uint256 nativeBalance = address(this).balance;
        if (nativeBalance != 0) {
            (bool sent,) = MARKETING.call{value: nativeBalance, gas: NATIVE_GAS}("");
            emit NativePushAttempt(nativeBalance, sent);
        }
    }

    /// @dev Bound gas and copy at most one return word: even a hostile token cannot return-bomb
    /// the split. A failing balance read or transfer leaves the token for a later distribution.
    function _burnToken() private {
        address to = token;
        bytes memory data = abi.encodeCall(IERC20.balanceOf, (address(this)));
        bool ok;
        uint256 amount;
        assembly ("memory-safe") {
            let output := mload(0x40)
            ok := staticcall(TOKEN_BALANCE_GAS, to, add(data, 32), mload(data), output, 32)
            ok := and(ok, iszero(lt(returndatasize(), 32)))
            amount := mload(output)
        }
        if (!ok) {
            emit TokenBurnAttempt(0, false);
            return;
        }
        if (amount == 0) return;
        data = abi.encodeCall(IERC20.transfer, (DEAD, amount));
        assembly ("memory-safe") {
            let output := mload(0x40)
            ok := call(TOKEN_BURN_GAS, to, 0, add(data, 32), mload(data), output, 32)
            if returndatasize() {
                ok := and(ok, and(iszero(lt(returndatasize(), 32)), eq(mload(output), 1)))
            }
        }
        emit TokenBurnAttempt(amount, ok);
    }

    receive() external payable {}
}
