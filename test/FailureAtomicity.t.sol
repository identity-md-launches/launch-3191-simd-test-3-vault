// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {VaultTestBase} from "./helpers/VaultTestBase.sol";
import {StakeRewards} from "src/StakeRewards.sol";
import {JobsVault} from "src/JobsVault.sol";
import {IntakePayment} from "src/libraries/IntakePayment.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract FailureAtomicityTest is VaultTestBase {
    function test_failedJobsShareRevertsFeeCollectionNotificationAndCooldownTogether() public {
        _bind(false);
        _stake(alice, 1 ether);
        imd.mint(address(vault), 9000 ether);
        imd.mint(FACTORY, 1000 ether);
        launchedToken.mint(FACTORY, 13 ether);
        factory.configure(1000 ether, 13 ether, 1 ether, 0);
        vm.deal(FACTORY, 1 ether);
        vm.mockCall(IMD, abi.encodeCall(IERC20.transfer, (address(jobs), 2572 ether)), abi.encode(false));
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, IMD));
        vault.distribute();
        assertEq(factory.claimCalls(), 0);
        assertEq(factory.fee0(), 1000 ether);
        assertEq(factory.fee1(), 13 ether);
        assertEq(factory.nativeFee(), 1 ether);
        assertEq(imd.balanceOf(address(vault)), 9000 ether);
        assertEq(imd.balanceOf(FACTORY), 1000 ether);
        assertEq(launchedToken.balanceOf(FACTORY), 13 ether);
        assertEq(FACTORY.balance, 1 ether);
        assertEq(rewards.reserved(), 0);
        assertEq(rewards.rewardRate(), 0);
        assertEq(rewards.periodFinish(), 0);
        assertEq(imd.balanceOf(address(rewards)), 0);
        assertEq(imd.balanceOf(address(jobs)), 0);
        assertEq(imd.balanceOf(DEV), 0);
        assertEq(vault.nextDistributionAt(), 0);

        vm.clearMockedCalls();
        vault.distribute(); // No wait: the failed attempt did not consume this week's slot.
        assertEq(factory.claimCalls(), 1);
        assertEq(rewards.reserved(), 4000 ether);
        assertEq(imd.balanceOf(address(jobs)), 2572 ether);
        assertEq(launchedToken.balanceOf(DEAD), 13 ether);
        assertEq(MARKETING.balance, 1 ether);
    }

    function test_failedRewardPaymentDuringExitRestoresPrincipalAndAccruedRewards() public {
        _bind(false);
        _stake(alice, 3 ether);
        _deposit(604800 ether);
        _advance(WEEK);
        imd.configure(0, 2, false);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, IMD));
        rewards.exit();
        assertEq(rewards.stakeOf(alice), 3 ether);
        assertEq(rewards.totalStaked(), 3 ether);
        assertEq(launchedToken.balanceOf(alice), 0);
        assertEq(launchedToken.balanceOf(address(rewards)), 3 ether);
        assertEq(rewards.earned(alice), 604800 ether);
        assertEq(rewards.reserved(), 604800 ether);
        imd.configure(0, 0, false);
        vm.prank(alice);
        rewards.exit();
        assertEq(launchedToken.balanceOf(alice), 3 ether);
        assertEq(imd.balanceOf(alice), 604800 ether);
    }

    function test_unsoldJobDoesNotLockAndCanRetryAtChangedLivePrice() public {
        _bind(false);
        _stake(alice, 1_000_000 ether);
        imd.mint(address(jobs), 2 ether);
        intake.configure(0, false, false);
        vm.prank(alice);
        vm.expectRevert(IntakePayment.ActionNotSold.selector);
        jobs.requestJob("{}");
        assertEq(rewards.lockedUntil(alice), 0);
        assertEq(jobs.nextJobAt(alice), 0);
        assertEq(imd.balanceOf(address(jobs)), 2 ether);
        assertEq(imd.allowance(address(jobs), INTAKE), 0);
        intake.configure(0.75 ether, false, false);
        vm.prank(alice);
        jobs.requestJob("{}");
        assertEq(imd.balanceOf(treasury), 0.75 ether);
        assertEq(intake.allowanceObserved(), 0.75 ether);
        assertEq(imd.allowance(address(jobs), INTAKE), 0);
    }

    function test_failedJobAfterAnExpiredLockDoesNotExtendThatLock() public {
        _bind(false);
        _stake(alice, 1_000_000 ether);
        imd.mint(address(jobs), 2 * PRICE);
        vm.prank(alice);
        jobs.requestJob("{}");
        uint256 oldLock = rewards.lockedUntil(alice);
        _advance(1 days);
        intake.configure(PRICE, true, false);
        vm.prank(alice);
        vm.expectRevert("intake rejected");
        jobs.requestJob("{}");
        assertEq(rewards.lockedUntil(alice), oldLock);
        assertEq(jobs.nextJobAt(alice), oldLock);
        assertEq(imd.balanceOf(address(jobs)), PRICE);
        vm.prank(alice);
        rewards.withdraw(1_000_000 ether);
        assertEq(rewards.stakeOf(alice), 0);
    }

    function test_uninitializedChildrenRejectUnauthorizedSettersAndInvalidDependencies() public {
        StakeRewards fresh = new StakeRewards(address(this));
        JobsVault freshJobs = new JobsVault(address(this), fresh);
        vm.expectRevert(StakeRewards.TokenNotSet.selector);
        fresh.stake(1);
        vm.expectRevert(StakeRewards.InvalidAddress.selector);
        fresh.setToken(IMD);
        vm.expectRevert(StakeRewards.InvalidAddress.selector);
        fresh.setToken(alice);
        vm.expectRevert(StakeRewards.InvalidAddress.selector);
        fresh.setJobsVault(address(0));
        vm.expectRevert(JobsVault.InvalidToken.selector);
        freshJobs.setToken(IMD);
        vm.expectRevert(JobsVault.InvalidToken.selector);
        freshJobs.setToken(alice);
        fresh.setToken(address(launchedToken));
        fresh.setJobsVault(address(freshJobs));
        freshJobs.setToken(address(launchedToken));
        vm.expectRevert(StakeRewards.AlreadySet.selector);
        fresh.setToken(address(launchedToken));
        vm.expectRevert(StakeRewards.AlreadySet.selector);
        fresh.setJobsVault(address(freshJobs));
        vm.expectRevert(JobsVault.AlreadySet.selector);
        freshJobs.setToken(address(launchedToken));
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_jobThresholdUsesActualDecimalsAtBothSidesOfBoundary(uint8 rawDecimals) public {
        uint8 decimals = uint8(bound(uint256(rawDecimals), 0, 71));
        launchedToken = new MockERC20(decimals);
        factory.setPosition(NUMBER, IMD, address(launchedToken), address(vault));
        _bind(false);
        uint256 threshold = 1_000_000 * 10 ** uint256(decimals);
        assertEq(jobs.minimumStake(), threshold);
        imd.mint(address(jobs), PRICE);
        _stake(alice, threshold - 1);
        vm.prank(alice);
        vm.expectRevert(JobsVault.InsufficientStake.selector);
        jobs.requestJob("{}");
        assertEq(rewards.lockedUntil(alice), 0);
        _stake(alice, 1);
        vm.prank(alice);
        jobs.requestJob("{}");
        assertEq(imd.balanceOf(treasury), PRICE);
        assertEq(rewards.lockedUntil(alice), block.timestamp + 1 days);
    }
}
