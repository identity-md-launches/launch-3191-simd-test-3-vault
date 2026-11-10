// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Network} from "src/Network.sol";
import {SIMDVault} from "src/SIMDVault.sol";
import {StakeRewards} from "src/StakeRewards.sol";
import {JobsVault} from "src/JobsVault.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockIntake} from "../mocks/MockIntake.sol";
import {MockFactory, RejectNative} from "../mocks/MockFactory.sol";

/// @dev Ghost ledgers record external funding and successful authorized outflows. No application
/// storage is edited. Unexpected success/revert latches a failure, even with fail_on_revert=false.
contract VaultSystemHandler is Test, Network {
    SIMDVault public immutable vault;
    StakeRewards public immutable rewards;
    JobsVault public immutable jobs;
    MockERC20 public immutable token;
    MockERC20 public immutable imd = MockERC20(IMD);
    MockIntake public immutable intake = MockIntake(INTAKE);
    MockFactory public immutable factory = MockFactory(payable(FACTORY));
    address internal immutable rejectNative;
    address[3] public actors;

    bool public violated;
    bool public launchPaid;
    uint256 public issuedIMD;
    uint256 public rewardNotified;
    uint256 public rewardPaid;
    uint256 public jobsFunded;
    uint256 public jobsSpent;
    uint256 public launchSpent;
    uint256 public beneficiariesPaid;
    uint256 public nativeFunded;
    uint256 public nativePaid;
    uint256 public burnFunding;
    uint256 public principalDonations;
    uint256 public nextDistribution;
    uint256 public successfulDistributions;
    uint256 public successfulJobs;
    uint256 public rejectedCalls;
    mapping(address => uint256) public principalIn;
    mapping(address => uint256) public principalOut;
    mapping(address => uint256) public paidTo;
    mapping(address => uint256) public lockUntil;

    constructor(SIMDVault vault_, MockERC20 token_) {
        vault = vault_;
        rewards = vault_.stakeRewards();
        jobs = vault_.jobsVault();
        token = token_;
        rejectNative = address(new RejectNative());
        for (uint256 i; i < actors.length; ++i) {
            actors[i] = makeAddr(string.concat("invariant staker ", vm.toString(i)));
        }
    }

    function _check(bool condition) internal {
        if (!condition) violated = true;
    }

    function _as(address who, address target, bytes memory data) internal returns (bool ok, bytes memory result) {
        vm.prank(who);
        (ok, result) = target.call(data);
    }

    function _outcome(bool ok, bool expected) internal {
        _check(ok == expected);
        if (!ok) ++rejectedCalls;
    }

    function fund(uint256 raw, uint8 destination) public {
        uint256 amount = bound(raw, 0, 1e28);
        address to;
        if (destination % 4 == 0) {
            to = address(vault);
        } else if (destination % 4 == 1) {
            to = address(rewards);
        } else if (destination % 4 == 2) {
            to = address(jobs);
            jobsFunded += amount;
        } else {
            to = FACTORY;
            factory.configure(factory.fee0() + amount, 0, 0, 0);
        }
        imd.mint(to, amount);
        issuedIMD += amount;
    }

    function donateOtherAssets(uint256 raw, uint8 destination) public {
        uint256 amount = bound(raw, 0, 1e25);
        if (destination % 3 == 0) {
            vm.deal(address(this), amount);
            (bool ok,) = address(vault).call{value: amount}("");
            _check(ok);
            nativeFunded += amount;
        } else if (destination % 3 == 1) {
            token.mint(address(vault), amount);
            burnFunding += amount;
        } else {
            token.mint(address(rewards), amount);
            principalDonations += amount;
        }
    }

    function advance(uint32 raw) public {
        uint256 elapsed = uint256(raw) % (8 days + 1);
        vm.warp(block.timestamp + elapsed);
        vm.roll(block.number + elapsed / 12 + 1);
    }

    function stake(uint8 actor, uint256 raw) public {
        address who = actors[actor % 3];
        uint256 amount = bound(raw, 1, 2_000_000 ether);
        token.mint(who, amount);
        vm.prank(who);
        token.approve(address(rewards), amount);
        (bool ok,) = _as(who, address(rewards), abi.encodeCall(rewards.stake, (amount)));
        _outcome(ok, true);
        if (ok) principalIn[who] += amount;
    }

    function withdraw(uint8 actor, uint256 raw, bool all) public {
        address who = actors[actor % 3];
        uint256 principal = principalIn[who] - principalOut[who];
        // Includes zero, entire principal, and one unit more than the account owns.
        uint256 amount = all ? principal : bound(raw, 0, principal + 1);
        uint256 beforeToken = token.balanceOf(who);
        uint256 beforeIMD = imd.balanceOf(who);
        bool expected = block.timestamp >= lockUntil[who] && amount <= principal;
        (bool ok,) = _as(
            who, address(rewards), all ? abi.encodeCall(rewards.exit, ()) : abi.encodeCall(rewards.withdraw, (amount))
        );
        _outcome(ok, expected);
        if (ok) {
            principalOut[who] += amount;
            uint256 paid = imd.balanceOf(who) - beforeIMD;
            rewardPaid += paid;
            paidTo[who] += paid;
            _check(token.balanceOf(who) - beforeToken == amount);
            if (!all) _check(paid == 0);
        } else {
            _check(token.balanceOf(who) == beforeToken && imd.balanceOf(who) == beforeIMD);
        }
    }

    function claim(uint8 actor) public {
        address who = actors[actor % 3];
        uint256 beforeIMD = imd.balanceOf(who);
        uint256 expected = rewards.earned(who);
        (bool ok,) = _as(who, address(rewards), abi.encodeCall(rewards.claim, ()));
        _outcome(ok, true);
        if (ok) {
            uint256 paid = imd.balanceOf(who) - beforeIMD;
            _check(paid == expected);
            rewardPaid += paid;
            paidTo[who] += paid;
        }
    }

    function notify() public {
        uint256 unnotified = imd.balanceOf(address(rewards)) - (rewardNotified - rewardPaid);
        (bool ok,) = _as(address(vault), address(rewards), abi.encodeCall(rewards.notifyDeposit, ()));
        _outcome(ok, true);
        if (ok) rewardNotified += unnotified;
    }

    function distribute(uint8 feeMode, bool failBurn, bool rejectETH) public {
        factory.configure(factory.fee0(), 0, 0, feeMode % 3);
        token.configure(0, failBurn ? 1 : 0, false);
        vm.etch(MARKETING, rejectETH ? rejectNative.code : bytes(""));
        uint256 expectedBalance = imd.balanceOf(address(vault));
        if (feeMode % 3 == 0) expectedBalance += factory.fee0();
        uint256 beforeNative = address(vault).balance;
        uint256 beforeToken = token.balanceOf(address(vault));
        uint256 beforeRewards = imd.balanceOf(address(rewards));
        bool expected = block.timestamp >= nextDistribution;
        (bool ok,) = address(vault).call{gas: 2_500_000}(abi.encodeCall(vault.distribute, ()));
        _outcome(ok, expected);
        if (ok) {
            uint256 staking = expectedBalance * 4000 / 10_000;
            uint256 jobShare = expectedBalance * 2572 / 10_000;
            rewardNotified += beforeRewards + staking - (rewardNotified - rewardPaid);
            jobsFunded += jobShare;
            beneficiariesPaid += expectedBalance - staking - jobShare;
            if (!rejectETH) nativePaid += beforeNative;
            nextDistribution = block.timestamp + 7 days;
            ++successfulDistributions;
            _check(imd.balanceOf(address(vault)) == 0);
            _check(token.balanceOf(address(vault)) == (failBurn ? beforeToken : 0));
            _check(address(vault).balance == (rejectETH ? beforeNative : 0));
        }
        token.configure(0, 0, false);
        vm.etch(MARKETING, "");
    }

    function requestJob(uint8 actor, uint8 bodyMode, uint96 rawPrice, bool reject) public {
        address who = actors[actor % 3];
        uint256 price = uint256(rawPrice) % (2 ether + 1);
        intake.configure(price, reject, false);
        bytes memory body = bodyMode % 8 == 0 ? bytes("") : bodyMode % 8 == 1 ? new bytes(16_385) : bytes("{}");
        uint256 beforeBalance = imd.balanceOf(address(jobs));
        uint256 oldLock = lockUntil[who];
        bool expected = body.length > 0 && body.length <= 16_384
            && principalIn[who] - principalOut[who] >= 1_000_000 ether && block.timestamp >= oldLock && price != 0
            && !reject && beforeBalance >= price;
        (bool ok,) = _as(who, address(jobs), abi.encodeCall(jobs.requestJob, (body)));
        _outcome(ok, expected);
        if (ok) {
            jobsSpent += price;
            lockUntil[who] = block.timestamp + 1 days;
            ++successfulJobs;
            _check(intake.lastPayer() == address(jobs));
            _check(intake.lastAction() == bytes32("job.open@job-1"));
            _check(intake.lastTarget() == address(0) && intake.lastSelector() == bytes4(0));
            _check(intake.allowanceObserved() == price);
        } else {
            _check(imd.balanceOf(address(jobs)) == beforeBalance);
            _check(rewards.lockedUntil(who) == oldLock && jobs.nextJobAt(who) == oldLock);
        }
    }

    function launch(bool authorized, uint96 rawPrice, bool reject) public {
        uint256 price = uint256(rawPrice) % (2 ether + 1);
        intake.configure(price, reject, false);
        bool expected = authorized && !launchPaid && price != 0 && !reject && imd.balanceOf(address(vault)) >= price;
        (bool ok,) = _as(authorized ? DEV : actors[0], address(vault), abi.encodeCall(vault.launch, (bytes("{}"))));
        _outcome(ok, expected);
        if (ok) {
            launchPaid = true;
            launchSpent += price;
            _check(intake.lastPayer() == address(vault));
            _check(intake.lastAction() == bytes32("launch.open@launch-1"));
            _check(intake.allowanceObserved() == price);
        }
    }

    function unauthorized(uint8 actor, uint8 operation) public {
        address who = actors[actor % 3];
        address target;
        bytes memory data;
        if (operation % 5 == 0) {
            target = address(rewards);
            data = abi.encodeCall(rewards.notifyDeposit, ());
        } else if (operation % 5 == 1) {
            target = address(rewards);
            data = abi.encodeCall(rewards.lock, (who, block.timestamp + 100 days));
        } else if (operation % 5 == 2) {
            target = address(rewards);
            data = abi.encodeCall(rewards.setJobsVault, (who));
        } else if (operation % 5 == 3) {
            target = address(jobs);
            data = abi.encodeCall(jobs.setToken, (address(token)));
        } else {
            target = address(vault);
            data = abi.encodeCall(vault.bindLaunch, (uint64(3200), address(token)));
        }
        (bool ok,) = _as(who, target, data);
        _outcome(ok, false);
    }

    /// @dev Not fuzz-targeted: all actors must recover principal after every randomized sequence.
    function settle() external {
        vm.warp(block.timestamp + 8 days);
        for (uint8 i; i < 3; ++i) {
            withdraw(i, 0, true);
        }
    }
}
