// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Network} from "../../src/Network.sol";
import {SIMDVault} from "../../src/SIMDVault.sol";
import {StakeRewards} from "../../src/StakeRewards.sol";
import {JobsVault} from "../../src/JobsVault.sol";
import {SimdAirdrop} from "../../src/SimdAirdrop.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockIntake} from "../mocks/MockIntake.sol";
import {MockFactory} from "../mocks/MockFactory.sol";

abstract contract VaultTestBase is Test, Network {
    uint64 internal constant NUMBER = 3200; // Local fixture, never a deployment parameter.
    uint256 internal constant WEEK = 7 days;
    uint256 internal constant PRICE = 0.5 ether;
    SIMDVault internal vault;
    StakeRewards internal rewards;
    JobsVault internal jobs;
    SimdAirdrop internal drop;
    MockERC20 internal imd;
    MockERC20 internal launchedToken;
    MockIntake internal intake;
    MockFactory internal factory;
    address internal alice;
    address internal bob;
    address internal carol;
    address internal treasury;

    function setUp() public virtual {
        vm.chainId(4663);
        vm.warp(1_800_000_000);
        vm.roll(1000);
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        carol = makeAddr("carol");
        treasury = makeAddr("mock treasury");
        vm.etch(IMD, address(new MockERC20(18)).code);
        imd = MockERC20(IMD);
        vm.etch(INTAKE, address(new MockIntake(treasury)).code);
        intake = MockIntake(INTAKE);
        intake.configure(PRICE, false, false);
        vm.etch(FACTORY, address(new MockFactory()).code);
        factory = MockFactory(payable(FACTORY));
        launchedToken = new MockERC20(18);
        vault = new SIMDVault();
        rewards = vault.stakeRewards();
        jobs = vault.jobsVault();
        drop = vault.airdrop();
        factory.setPosition(NUMBER, IMD, address(launchedToken), address(vault));
    }

    function _bind(bool fundDrop) internal {
        if (fundDrop) launchedToken.mint(address(drop), drop.TOTAL_WEIGHT());
        vm.prank(DEV);
        vault.bindLaunch(NUMBER, address(launchedToken));
    }

    function _stake(address user, uint256 amount) internal {
        launchedToken.mint(user, amount);
        vm.startPrank(user);
        launchedToken.approve(address(rewards), amount);
        rewards.stake(amount);
        vm.stopPrank();
    }

    function _deposit(uint256 amount) internal {
        imd.mint(address(rewards), amount);
        vm.prank(address(vault));
        rewards.notifyDeposit();
    }

    function _advance(uint256 elapsed) internal {
        vm.warp(block.timestamp + elapsed);
        vm.roll(block.number + elapsed / 12 + 1);
    }

    function _claim(address user) internal {
        vm.prank(user);
        rewards.claim();
    }
}
