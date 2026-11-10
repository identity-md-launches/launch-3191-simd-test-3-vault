// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {VaultTestBase} from "./helpers/VaultTestBase.sol";
import {StakeRewards} from "../src/StakeRewards.sol";

contract StakeRewardsTest is VaultTestBase {
    function setUp() public override {
        super.setUp();
        _bind(false);
    }

    function test_soleStakerEarnsWholeDepositOverSevenDays() public {
        _stake(alice, 1 ether);
        _deposit(604800 ether);
        _advance(WEEK / 2);
        assertEq(rewards.earned(alice), 302400 ether);
        _claim(alice);
        _advance(WEEK / 2);
        _claim(alice);
        assertEq(imd.balanceOf(alice), 604800 ether);
        assertEq(rewards.reserved(), 0);
        _advance(WEEK);
        _claim(alice);
        assertEq(imd.balanceOf(alice), 604800 ether);
    }

    function test_twoStakersSplitByStake() public {
        _stake(alice, 1 ether);
        _stake(bob, 3 ether);
        _deposit(604800 ether);
        _advance(WEEK);
        _claim(alice);
        _claim(bob);
        assertEq(imd.balanceOf(alice), 151200 ether);
        assertEq(imd.balanceOf(bob), 453600 ether);
    }

    function test_stakingJustBeforeDepositAndExitingAfterHourGetsOne168thOfShare() public {
        _stake(alice, 1 ether);
        _advance(1 days);
        _stake(bob, 1 ether);
        _deposit(604800 ether);
        _advance(1 hours);
        vm.prank(bob);
        rewards.exit();
        assertEq(imd.balanceOf(bob), 1800 ether); // half of 604800 / 168
        assertEq(launchedToken.balanceOf(bob), 1 ether);
        _advance(WEEK - 1 hours);
        _claim(alice);
        assertEq(imd.balanceOf(alice), 603000 ether);
    }

    function test_nobodyStakedCarriesIntoNextDeposit() public {
        _deposit(604800 ether);
        _advance(WEEK);
        _stake(alice, 1 ether);
        assertEq(rewards.earned(alice), 0);
        assertEq(rewards.carryScaled(), 604800 ether * 1e36);
        _deposit(604800 ether);
        _advance(WEEK);
        _claim(alice);
        assertEq(imd.balanceOf(alice), 1209600 ether);
        assertEq(rewards.reserved(), 0);
    }

    function test_midStreamDepositKeepsUnstreamedRemainder() public {
        _stake(alice, 1 ether);
        _deposit(604800 ether);
        _advance(WEEK / 2);
        _deposit(604800 ether);
        assertEq(rewards.earned(alice), 302400 ether);
        assertEq(rewards.rewardRate(), 1.5 ether * 1e36);
        _advance(WEEK);
        _claim(alice);
        assertEq(imd.balanceOf(alice), 1209600 ether);
        assertEq(rewards.reserved(), 0);
    }

    function test_noStakersDuringPartOfStreamIsCarriedWithoutRetroactiveRewards() public {
        _stake(alice, 1 ether);
        _deposit(604800 ether);
        _advance(1 days);
        vm.prank(alice);
        rewards.exit();
        assertEq(imd.balanceOf(alice), 86400 ether);
        _advance(2 days);
        _stake(bob, 1 ether);
        assertEq(rewards.earned(bob), 0);
        assertEq(rewards.carryScaled(), 172800 ether * 1e36);
        _advance(4 days);
        _claim(bob);
        assertEq(imd.balanceOf(bob), 345600 ether);
        _deposit(604800 ether);
        _advance(WEEK);
        _claim(bob);
        assertApproxEqAbs(imd.balanceOf(bob), 1123200 ether, 1);
    }

    function test_emptyNotifyDoesNotExtendOrRecycleReservedAndClaimDoesNotBecomeDeposit() public {
        _stake(alice, 1 ether);
        _deposit(604800 ether);
        uint256 end = rewards.periodFinish();
        _advance(1 days);
        _claim(alice);
        _deposit(0);
        assertEq(rewards.periodFinish(), end);
        assertEq(rewards.rewardRate(), 1 ether * 1e36);
        assertEq(rewards.reserved(), 518400 ether);
        assertEq(imd.balanceOf(address(rewards)), rewards.reserved());
    }

    function test_directDonationOnlyStartsEarningAfterVaultNotification() public {
        _stake(alice, 1 ether);
        imd.mint(address(rewards), 604800 ether);
        _advance(WEEK);
        assertEq(rewards.earned(alice), 0);
        _deposit(0);
        _advance(WEEK);
        _claim(alice);
        assertEq(imd.balanceOf(alice), 604800 ether);
    }

    function test_rateDivisionDustIsKeptAsScaledCarry() public {
        _deposit(1);
        assertEq(rewards.rewardRate(), uint256(1e36) / WEEK);
        assertEq(rewards.carryScaled(), uint256(1e36) % WEEK);
        _advance(WEEK);
        _deposit(1);
        assertEq(rewards.rewardRate(), uint256(2e36) / WEEK);
        assertEq(rewards.carryScaled(), uint256(2e36) % WEEK);
        assertEq(rewards.reserved(), 2);
    }

    function test_feeOnTransferStakeCountsOnlyReceived() public {
        launchedToken.configure(1000, 0, false);
        _stake(alice, 100 ether);
        assertEq(rewards.stakeOf(alice), 90 ether);
        assertEq(rewards.totalStaked(), 90 ether);
        assertEq(launchedToken.balanceOf(address(rewards)), 90 ether);
        vm.prank(alice);
        rewards.withdraw(90 ether);
        assertEq(rewards.totalStaked(), 0);
        assertEq(launchedToken.balanceOf(alice), 81 ether);
    }

    function test_zeroStakeZeroReceivedAndOverWithdrawalRejected() public {
        vm.prank(alice);
        vm.expectRevert(StakeRewards.ZeroAmount.selector);
        rewards.stake(0);
        launchedToken.configure(10000, 0, false);
        launchedToken.mint(alice, 100);
        vm.startPrank(alice);
        launchedToken.approve(address(rewards), 100);
        vm.expectRevert(StakeRewards.ZeroAmount.selector);
        rewards.stake(100);
        vm.stopPrank();
        launchedToken.configure(0, 0, false);
        _stake(alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert(StakeRewards.InsufficientStake.selector);
        rewards.withdraw(1 ether + 1);
    }

    function test_accessControlAndSettersCannotBeReused() public {
        vm.expectRevert(StakeRewards.NotVault.selector);
        rewards.setToken(address(launchedToken));
        vm.expectRevert(StakeRewards.NotVault.selector);
        rewards.setJobsVault(alice);
        vm.expectRevert(StakeRewards.NotVault.selector);
        rewards.notifyDeposit();
        vm.expectRevert(StakeRewards.NotJobsVault.selector);
        rewards.lock(alice, block.timestamp + WEEK);
        vm.startPrank(address(vault));
        vm.expectRevert(StakeRewards.AlreadySet.selector);
        rewards.setToken(address(launchedToken));
        vm.expectRevert(StakeRewards.AlreadySet.selector);
        rewards.setJobsVault(alice);
        vm.stopPrank();
    }

    function test_lockOnlyExtendsDoesNotStopClaimingAndExactExpiryAllowsExit() public {
        _stake(alice, 1 ether);
        _deposit(604800 ether);
        uint256 until = block.timestamp + 2 days;
        vm.prank(address(jobs));
        rewards.lock(alice, until);
        vm.prank(address(jobs));
        rewards.lock(alice, until - 1 days);
        assertEq(rewards.lockedUntil(alice), until);
        _advance(1 days);
        _claim(alice);
        assertEq(imd.balanceOf(alice), 86400 ether);
        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(StakeRewards.StakeLocked.selector, until));
        rewards.withdraw(1);
        vm.expectRevert(abi.encodeWithSelector(StakeRewards.StakeLocked.selector, until));
        rewards.exit();
        vm.stopPrank();
        _advance(1 days);
        vm.prank(alice);
        rewards.exit();
        assertEq(imd.balanceOf(alice), 172800 ether);
        assertEq(launchedToken.balanceOf(alice), 1 ether);
    }

    function test_tokenCallbacksCannotReenterStakeWithdrawClaimOrExit() public {
        bytes[4] memory calls = [
            abi.encodeCall(rewards.stake, (1)),
            abi.encodeCall(rewards.withdraw, (0)),
            abi.encodeCall(rewards.claim, ()),
            abi.encodeCall(rewards.exit, ())
        ];
        for (uint256 i; i < calls.length; ++i) {
            launchedToken.setCallback(address(rewards), calls[i]);
            _stake(alice, 1 ether);
            assertTrue(launchedToken.callbackBlocked());
            vm.prank(alice);
            rewards.withdraw(1 ether);
            assertTrue(launchedToken.callbackBlocked());
        }
        launchedToken.setCallback(address(0), "");
        _stake(alice, 1 ether);
        _deposit(604800 ether);
        _advance(WEEK);
        imd.setCallback(address(rewards), abi.encodeCall(rewards.claim, ()));
        _claim(alice);
        assertTrue(imd.callbackBlocked());
        assertEq(imd.balanceOf(alice), 604800 ether);
    }

    function test_failedClaimAndWithdrawalRestoreAllAccounting() public {
        _stake(alice, 1 ether);
        _deposit(604800 ether);
        _advance(WEEK);
        imd.configure(0, 2, false);
        vm.prank(alice);
        vm.expectRevert();
        rewards.claim();
        assertEq(rewards.earned(alice), 604800 ether);
        assertEq(rewards.reserved(), 604800 ether);
        imd.configure(0, 0, false);
        launchedToken.configure(0, 1, false);
        vm.prank(alice);
        vm.expectRevert("transfer rejected");
        rewards.exit();
        assertEq(rewards.stakeOf(alice), 1 ether);
        assertEq(rewards.totalStaked(), 1 ether);
        launchedToken.configure(0, 0, false);
        vm.prank(alice);
        rewards.exit();
        assertEq(rewards.reserved(), 0);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_sequencesNeverOverpayAndAlwaysCoverReserved(bytes32 seed) public {
        uint256 deposited;
        address[3] memory users = [alice, bob, carol];
        for (uint256 i; i < 48; ++i) {
            uint256 word = uint256(keccak256(abi.encode(seed, i)));
            address user = users[word % 3];
            uint256 op = (word >> 8) % 6;
            uint256 amount = (word >> 16) % 1e26 + 1;
            if (op == 0) {
                _stake(user, amount);
            } else if (op == 1) {
                _deposit(amount);
                deposited += amount;
            } else if (op == 2) {
                _advance((word >> 32) % (2 * WEEK));
            } else if (op == 3) {
                _claim(user);
            } else if (op == 4) {
                uint256 staked = rewards.stakeOf(user);
                vm.prank(user);
                rewards.withdraw(amount % (staked + 1));
            } else {
                vm.prank(user);
                rewards.exit();
            }
            uint256 paid = imd.balanceOf(alice) + imd.balanceOf(bob) + imd.balanceOf(carol);
            uint256 held = imd.balanceOf(address(rewards));
            assertLe(paid, deposited);
            assertEq(paid + held, deposited);
            assertGe(held, rewards.reserved());
            assertEq(rewards.reserved() + paid, deposited);
            assertEq(rewards.totalStaked(), rewards.stakeOf(alice) + rewards.stakeOf(bob) + rewards.stakeOf(carol));
            assertEq(launchedToken.balanceOf(address(rewards)), rewards.totalStaked());
            assertLe(rewards.earned(alice) + rewards.earned(bob) + rewards.earned(carol), rewards.reserved());
        }
        _advance(WEEK);
        for (uint256 i; i < users.length; ++i) {
            vm.prank(users[i]);
            rewards.exit();
        }
        assertLe(imd.balanceOf(alice) + imd.balanceOf(bob) + imd.balanceOf(carol), deposited);
        assertGe(imd.balanceOf(address(rewards)), rewards.reserved());
        assertEq(rewards.totalStaked(), 0);
    }
}
