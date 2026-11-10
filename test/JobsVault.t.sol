// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {VaultTestBase} from "./helpers/VaultTestBase.sol";
import {JobsVault} from "../src/JobsVault.sol";
import {StakeRewards} from "../src/StakeRewards.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract JobsVaultTest is VaultTestBase {
    function test_belowMillionWholeTokensRejectedWalletBalanceDoesNotQualify() public {
        _bind(false);
        imd.mint(address(jobs), PRICE);
        launchedToken.mint(alice, 10_000_000 ether);
        vm.prank(alice);
        vm.expectRevert(JobsVault.InsufficientStake.selector);
        jobs.requestJob("{}");
        _stake(alice, 1_000_000 ether - 1);
        vm.prank(alice);
        vm.expectRevert(JobsVault.InsufficientStake.selector);
        jobs.requestJob("{}");
        assertEq(rewards.lockedUntil(alice), 0);
        _stake(alice, 1);
        vm.prank(alice);
        jobs.requestJob("{}");
        assertEq(intake.lastPayer(), address(jobs));
    }

    function test_onlyOneJobPerDayPerWalletLockKeepsEarning() public {
        _bind(false);
        _stake(alice, 1_000_000 ether);
        _stake(bob, 1_000_000 ether);
        imd.mint(address(jobs), 5 ether);
        _deposit(604800 ether);
        bytes memory body = bytes('{"objective":"Report on SIMD TEST 3","template":"research"}');
        vm.prank(alice);
        jobs.requestJob(body);
        assertEq(intake.lastBody(), body);
        assertEq(intake.lastAction(), bytes32("job.open@job-1"));
        assertEq(intake.lastAmount(), PRICE);
        assertEq(intake.lastTarget(), address(0));
        assertEq(intake.lastSelector(), bytes4(0));
        assertEq(imd.allowance(address(jobs), INTAKE), 0);
        uint256 until = block.timestamp + 1 days;
        assertEq(rewards.lockedUntil(alice), until);
        vm.prank(bob);
        jobs.requestJob(body);
        _advance(1 days - 1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(JobsVault.TooSoon.selector, until));
        jobs.requestJob(body);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(StakeRewards.StakeLocked.selector, until));
        rewards.exit();
        _advance(1);
        _claim(alice);
        assertEq(imd.balanceOf(alice), 43200 ether);
        vm.prank(alice);
        jobs.requestJob(body);
        assertEq(rewards.lockedUntil(alice), until + 1 days);
        _advance(1 days);
        vm.prank(alice);
        rewards.exit();
        assertEq(launchedToken.balanceOf(alice), 1_000_000 ether);
    }

    function test_failureRollsBackCooldownLockAndApproval() public {
        _bind(false);
        _stake(alice, 1_000_000 ether);
        vm.prank(alice);
        vm.expectRevert();
        jobs.requestJob("{}");
        assertEq(jobs.nextJobAt(alice), 0);
        assertEq(rewards.lockedUntil(alice), 0);
        imd.mint(address(jobs), PRICE);
        intake.configure(PRICE, true, false);
        vm.prank(alice);
        vm.expectRevert("intake rejected");
        jobs.requestJob("{}");
        assertEq(jobs.nextJobAt(alice), 0);
        assertEq(rewards.lockedUntil(alice), 0);
        assertEq(imd.allowance(address(jobs), INTAKE), 0);
        intake.configure(PRICE, false, true);
        vm.prank(alice);
        jobs.requestJob("{}");
        assertEq(imd.allowance(address(jobs), INTAKE), 0);
    }

    function test_bodyBoundsAndUnconfiguredToken() public {
        vm.expectRevert(JobsVault.TokenNotSet.selector);
        jobs.requestJob("{}");
        _bind(false);
        _stake(alice, 1_000_000 ether);
        imd.mint(address(jobs), PRICE);
        vm.startPrank(alice);
        vm.expectRevert(JobsVault.InvalidBody.selector);
        jobs.requestJob("");
        vm.expectRevert(JobsVault.InvalidBody.selector);
        jobs.requestJob(new bytes(16_385));
        jobs.requestJob(new bytes(16_384));
        vm.stopPrank();
        assertEq(intake.lastBody().length, 16_384);
    }

    function test_thresholdUsesSixDecimalsAndOnlyVaultSetsOnce() public {
        launchedToken = new MockERC20(6);
        factory.setPosition(NUMBER, IMD, address(launchedToken), address(vault));
        vm.expectRevert(JobsVault.NotVault.selector);
        jobs.setToken(address(launchedToken));
        _bind(false);
        assertEq(jobs.minimumStake(), 1_000_000 * 1e6);
        _stake(alice, 1_000_000 * 1e6);
        imd.mint(address(jobs), PRICE);
        vm.prank(alice);
        jobs.requestJob("{}");
        vm.prank(address(vault));
        vm.expectRevert(JobsVault.AlreadySet.selector);
        jobs.setToken(address(launchedToken));
    }

    function test_impossibleDecimalsRejectBindingAtomically() public {
        launchedToken = new MockERC20(72);
        factory.setPosition(NUMBER, IMD, address(launchedToken), address(vault));
        vm.prank(DEV);
        vm.expectRevert(JobsVault.InvalidToken.selector);
        vault.bindLaunch(NUMBER, address(launchedToken));
        assertEq(vault.token(), address(0));
        assertEq(rewards.token(), address(0));
    }

    function test_intakeReentryCannotBuyExtraJob() public {
        _bind(false);
        _stake(alice, 1_000_000 ether);
        _stake(INTAKE, 1_000_000 ether);
        imd.mint(address(jobs), 5 ether);
        intake.setReentry(address(jobs), abi.encodeCall(jobs.requestJob, (bytes("{}"))));
        vm.prank(alice);
        jobs.requestJob("{}");
        assertTrue(intake.reentryBlocked());
        assertEq(intake.nonce(), 1);
        assertEq(imd.balanceOf(address(jobs)), 5 ether - PRICE);
    }
}
