// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, Vm} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Network} from "../../src/Network.sol";
import {SIMDVault} from "../../src/SIMDVault.sol";
import {StakeRewards} from "../../src/StakeRewards.sol";
import {JobsVault} from "../../src/JobsVault.sol";
import {SimdAirdrop} from "../../src/SimdAirdrop.sol";
import {IIntake} from "../../src/interfaces/IIntake.sol";
import {PoolKey} from "../../src/interfaces/ILaunchFactory.sol";
import {LaunchPool} from "../../src/libraries/LaunchPool.sol";
import {MerkleFixture} from "../helpers/MerkleFixture.sol";
import {ILiveFactory, ForkLaunchToken, ForkInitHook, ForkSwapActor} from "./LiveFactory.sol";

/// @notice Uses ROBINHOOD_RPC_URL at the assignment's fixed block, or skips when absent.
/// Factory, Intake, IMD and PoolManager code/storage are never replaced or mocked.
contract RobinhoodForkTest is Test, Network, MerkleFixture {
    event Requested(
        bytes32 indexed requestId,
        address indexed payer,
        bytes32 indexed action,
        bytes body,
        address callbackTarget,
        bytes4 callbackSelector,
        address asset,
        uint256 amount
    );

    uint64 internal constant FIXTURE_NUMBER = 9_994_663;
    uint256 internal constant WEEK = 7 days;
    SIMDVault internal vault;
    StakeRewards internal rewards;
    JobsVault internal jobs;
    SimdAirdrop internal drop;
    IERC20 internal token;
    ILiveFactory internal factory = ILiveFactory(FACTORY);
    address internal alice;
    address internal bob;
    address internal carol;

    function setUp() public {
        string memory url = vm.envOr("ROBINHOOD_RPC_URL", string(""));
        if (bytes(url).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(url, 111189501);
        assertEq(block.chainid, 4663, "fork must be Robinhood Chain");
        assertGt(IMD.code.length, 0);
        assertGt(INTAKE.code.length, 0);
        assertGt(FACTORY.code.length, 0);
        alice = makeAddr("fork alice");
        bob = makeAddr("fork bob");
        carol = makeAddr("fork carol");
        vault = new SIMDVault();
        rewards = vault.stakeRewards();
        jobs = vault.jobsVault();
        drop = vault.airdrop();
        _createRealFactoryLaunch();
    }

    function _createRealFactoryLaunch() internal {
        ILiveFactory.LaunchParams memory p;
        p.launchNumber = FIXTURE_NUMBER;
        p.kind = bytes32("univ4_hook");
        p.tokenCreationCode = type(ForkLaunchToken).creationCode;
        p.hookCreationCode = type(ForkInitHook).creationCode;
        p.hookFlags = 1 << 13; // beforeInitialize only
        bytes32 codeHash = keccak256(p.hookCreationCode);
        for (uint256 salt;; ++salt) {
            address predicted =
                address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), FACTORY, bytes32(salt), codeHash)))));
            if (uint160(predicted) & ((1 << 14) - 1) == p.hookFlags) {
                p.hookSalt = bytes32(salt);
                break;
            }
        }
        p.totalSupply = 1e30;
        p.poolBps = 1000;
        p.remainderTo = address(drop);
        p.merkleRoot = keccak256("fork-only contributor fixture");
        p.sweepDelaySeconds = 30 days;
        p.pairedCurrency = IMD;
        p.fee = 3000;
        p.tickSpacing = 60;
        p.sqrtPriceX96 = uint160(1 << 96);
        p.liquidity = 1e24;
        address predictedToken = factory.predictToken(FIXTURE_NUMBER, p.tokenCreationCode);
        bool token0 = predictedToken < IMD;
        p.tickLower = token0 ? int24(60) : int24(-120);
        p.tickUpper = token0 ? int24(120) : int24(-60);
        p.requester = address(vault);
        p.record.sourceRepoUrl = "local fork fixture";
        address deployer = factory.deployer();
        vm.prank(deployer);
        (address created,,) = factory.launch(p);
        token = IERC20(created);
        assertEq(created, predictedToken);
        assertGe(token.balanceOf(address(drop)), drop.TOTAL_WEIGHT());
    }

    function _bind() internal {
        vm.prank(DEV);
        vault.bindLaunch(FIXTURE_NUMBER, address(token));
    }

    function _stake(address account, uint256 amount) internal {
        deal(address(token), account, token.balanceOf(account) + amount);
        vm.startPrank(account);
        token.approve(address(rewards), amount);
        rewards.stake(amount);
        vm.stopPrank();
    }

    function _deposit(uint256 amount) internal {
        deal(IMD, address(rewards), IERC20(IMD).balanceOf(address(rewards)) + amount);
        vm.prank(address(vault));
        rewards.notifyDeposit();
    }

    function _advance(uint256 elapsed) internal {
        vm.warp(block.timestamp + elapsed);
        vm.roll(block.number + elapsed / 12 + 1);
    }

    function _claim(address account) internal {
        vm.prank(account);
        rewards.claim();
    }

    function testFork_blocksAloneCannotAdvanceWeeklyCooldown() public {
        _bind();
        vault.distribute();
        uint256 next = vault.nextDistributionAt();
        vm.roll(block.number + 10_000_000);
        vm.expectRevert(abi.encodeWithSelector(SIMDVault.TooSoon.selector, next));
        vault.distribute();
        vm.warp(next);
        vault.distribute();
    }

    function testFork_realIntakeLaunchOnlyDevOnceAndApprovalReset() public {
        uint256 price = IIntake(INTAKE).priceOf(bytes32("launch.open@launch-1"), IMD);
        assertGt(price, 0);
        deal(IMD, address(vault), price);
        // Intake checks bytes/payment. Actual off-chain admission and deployment do not run on a fork.
        bytes memory body = bytes(
            '{"objective":"SIMD TEST 3 - DO NOT BUY fork payment fixture","onchain":"evm_contracts","chainId":4663}'
        );
        vm.expectRevert(SIMDVault.NotDev.selector);
        vault.launch(body);
        vm.expectEmit(false, true, true, true, INTAKE);
        emit Requested(
            bytes32(0), address(vault), bytes32("launch.open@launch-1"), body, address(0), bytes4(0), IMD, price
        );
        vm.prank(DEV);
        bytes32 id = vault.launch(body);
        assertTrue(id != bytes32(0));
        assertEq(IERC20(IMD).balanceOf(address(vault)), 0);
        assertEq(IERC20(IMD).allowance(address(vault), INTAKE), 0);
        vm.prank(DEV);
        vm.expectRevert(SIMDVault.AlreadyLaunched.selector);
        vault.launch(body);
    }

    function testFork_realIntakeRejectedLaunchPreservesFundsAllowanceAndOneTimeFlag() public {
        uint256 price = IIntake(INTAKE).priceOf(bytes32("launch.open@launch-1"), IMD);
        assertGt(price, 0);
        deal(IMD, address(vault), price - 1);
        vm.prank(DEV);
        vm.expectRevert(); // The real IMD refuses an underfunded transferFrom.
        vault.launch("{}");
        assertFalse(vault.launched());
        assertEq(IERC20(IMD).balanceOf(address(vault)), price - 1);
        assertEq(IERC20(IMD).allowance(address(vault), INTAKE), 0);

        deal(IMD, address(vault), price);
        vm.prank(DEV);
        vm.expectRevert(); // The real Intake rejects an empty body.
        vault.launch("");
        assertFalse(vault.launched());
        assertEq(IERC20(IMD).balanceOf(address(vault)), price);
        assertEq(IERC20(IMD).allowance(address(vault), INTAKE), 0);
        vm.prank(DEV);
        vault.launch("{}");
        assertTrue(vault.launched());
        assertEq(IERC20(IMD).balanceOf(address(vault)), 0);
    }

    function testFork_bindingWrongTokenRollsBackAndUnfundedAirdropCanBeRetriedByAnyone() public {
        vm.prank(DEV);
        vm.expectRevert(SIMDVault.WrongToken.selector);
        vault.bindLaunch(FIXTURE_NUMBER, IMD);
        assertEq(vault.token(), address(0));
        assertEq(rewards.token(), address(0));
        assertEq(jobs.token(), address(0));

        uint256 required = drop.TOTAL_WEIGHT();
        deal(address(token), address(drop), required - 1);
        _bind();
        assertEq(vault.token(), address(token));
        assertEq(rewards.token(), address(token));
        assertEq(jobs.token(), address(token));
        assertEq(drop.token(), address(0));
        assertEq(drop.claimEnd(), 0);
        vm.prank(bob);
        vm.expectRevert(SimdAirdrop.InsufficientRemainder.selector);
        vault.bindAirdrop();
        _advance(2 days);
        deal(address(token), address(drop), required);
        vm.prank(bob);
        vault.bindAirdrop();
        assertEq(drop.token(), address(token));
        assertEq(drop.startBalance(), required);
        assertEq(drop.claimEnd(), block.timestamp + 30 days);
        vm.prank(carol);
        vm.expectRevert(SimdAirdrop.AlreadyBound.selector);
        vault.bindAirdrop();
    }

    function testFork_bindOnlyDevOnceRejectsForeignRequesterAndBindsRemainderInSameCall() public {
        vm.expectRevert(SIMDVault.NotDev.selector);
        vault.bindLaunch(FIXTURE_NUMBER, address(token));
        vm.prank(address(vault));
        factory.setRequester(FIXTURE_NUMBER, alice);
        vm.prank(DEV);
        vm.expectRevert(LaunchPool.WrongRequester.selector);
        vault.bindLaunch(FIXTURE_NUMBER, address(token));
        vm.prank(alice);
        factory.setRequester(FIXTURE_NUMBER, address(vault));
        _bind();
        assertEq(drop.token(), address(token));
        assertEq(drop.startBalance(), token.balanceOf(address(drop)));
        assertEq(rewards.token(), address(token));
        assertEq(jobs.token(), address(token));
        vm.prank(DEV);
        vm.expectRevert(SIMDVault.AlreadyBound.selector);
        vault.bindLaunch(FIXTURE_NUMBER, address(token));
    }

    function testFork_realSwapFeesSplitBurnAndWeeklyBoundary() public {
        _bind();
        (PoolKey memory key,,,) = factory.positionOf(FIXTURE_NUMBER);
        ForkSwapActor actor = new ForkSwapActor(factory.poolManager());
        deal(IMD, address(actor), 1e24);
        bool zeroForOne = key.currency0 == IMD;
        uint160 limit =
            zeroForOne ? uint160((uint256(1) << 96) * 995 / 1000) : uint160((uint256(1) << 96) * 1005 / 1000);
        actor.swap(key, zeroForOne, limit);
        // Preview the real factory's fee payout on an isolated snapshot, then restore it.
        uint256 snapshot = vm.snapshotState();
        factory.claimFees(FIXTURE_NUMBER);
        uint256 fees = IERC20(IMD).balanceOf(address(vault));
        assertGt(fees, 0, "real swap must accrue requester fees");
        assertTrue(vm.revertToState(snapshot));
        deal(IMD, address(vault), 10000 ether);
        deal(address(token), address(vault), 10 ether);
        uint256 walletBefore = IERC20(IMD).balanceOf(DEV);
        uint256 nativeBefore = MARKETING.balance;
        vm.deal(address(vault), 1 ether);
        vault.distribute();
        uint256 total = 10000 ether + fees;
        uint256 staking = total * 4000 / 10000;
        uint256 jobShare = total * 2572 / 10000;
        assertEq(IERC20(IMD).balanceOf(address(rewards)), staking);
        assertEq(rewards.reserved(), staking);
        assertEq(IERC20(IMD).balanceOf(address(jobs)), jobShare);
        assertEq(IERC20(IMD).balanceOf(DEV) - walletBefore, total - staking - jobShare);
        assertEq(IERC20(IMD).balanceOf(address(vault)), 0);
        assertEq(token.balanceOf(DEAD), 10 ether);
        assertEq(MARKETING.balance - nativeBefore, 1 ether);
        _advance(WEEK - 1);
        vm.expectRevert(abi.encodeWithSelector(SIMDVault.TooSoon.selector, vault.nextDistributionAt()));
        vault.distribute();
        _advance(1);
        vault.distribute();
    }

    function testFork_soleStakerGetsWholeWeek() public {
        _bind();
        _stake(alice, 1 ether);
        _deposit(604800 ether);
        _advance(WEEK);
        _claim(alice);
        assertEq(IERC20(IMD).balanceOf(alice), 604800 ether);
    }

    function testFork_twoStakersSplitByStake() public {
        _bind();
        _stake(alice, 1 ether);
        _stake(bob, 3 ether);
        _deposit(604800 ether);
        _advance(WEEK);
        _claim(alice);
        _claim(bob);
        assertEq(IERC20(IMD).balanceOf(alice), 151200 ether);
        assertEq(IERC20(IMD).balanceOf(bob), 453600 ether);
    }

    function testFork_oneHourStakerGetsOne168thOfShare() public {
        _bind();
        _stake(alice, 1 ether);
        _advance(1 days);
        _stake(bob, 1 ether);
        _deposit(604800 ether);
        _advance(1 hours);
        vm.prank(bob);
        rewards.exit();
        assertEq(IERC20(IMD).balanceOf(bob), 1800 ether);
    }

    function testFork_noStakersCarryIntoNextDeposit() public {
        _bind();
        _deposit(604800 ether);
        _advance(WEEK);
        _stake(alice, 1 ether);
        _deposit(604800 ether);
        _advance(WEEK);
        _claim(alice);
        assertEq(IERC20(IMD).balanceOf(alice), 1209600 ether);
    }

    function testFork_midStreamDepositKeepsRemainder() public {
        _bind();
        _stake(alice, 1 ether);
        _deposit(604800 ether);
        _advance(WEEK / 2);
        _deposit(604800 ether);
        _advance(WEEK);
        _claim(alice);
        assertEq(IERC20(IMD).balanceOf(alice), 1209600 ether);
    }

    function testFork_jobsRealIntakeThresholdCooldownAndEarningWhileLocked() public {
        _bind();
        _stake(alice, 1_000_000 ether - 1);
        deal(IMD, address(jobs), 5 ether);
        bytes memory body = bytes('{"objective":"Explain the SIMD TEST 3 disclaimer","template":"research"}');
        vm.prank(alice);
        vm.expectRevert(JobsVault.InsufficientStake.selector);
        jobs.requestJob(body);
        _stake(alice, 1);
        _deposit(604800 ether);
        uint256 price = IIntake(INTAKE).priceOf(bytes32("job.open@job-1"), IMD);
        vm.prank(alice);
        jobs.requestJob(body);
        uint256 until = rewards.lockedUntil(alice);
        assertEq(until, block.timestamp + 1 days);
        assertEq(IERC20(IMD).allowance(address(jobs), INTAKE), 0);
        assertEq(IERC20(IMD).balanceOf(address(jobs)), 5 ether - price);
        _advance(1 days - 1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(JobsVault.TooSoon.selector, until));
        jobs.requestJob(body);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(StakeRewards.StakeLocked.selector, until));
        rewards.exit();
        _advance(1);
        _claim(alice);
        assertEq(IERC20(IMD).balanceOf(alice), 86400 ether);
        vm.prank(alice);
        jobs.requestJob(body);
        _advance(1 days);
        vm.prank(alice);
        rewards.exit();
    }

    function testFork_realIntakeFailedJobRestoresStakeLockCooldownBudgetAndAllowance() public {
        _bind();
        _stake(alice, 1_000_000 ether);
        uint256 price = IIntake(INTAKE).priceOf(bytes32("job.open@job-1"), IMD);
        assertGt(price, 0);
        deal(IMD, address(jobs), price - 1);
        bytes memory body = bytes('{"objective":"Explain the SIMD TEST 3 disclaimer","template":"research"}');
        vm.prank(alice);
        vm.expectRevert();
        jobs.requestJob(body);
        assertEq(rewards.lockedUntil(alice), 0);
        assertEq(jobs.nextJobAt(alice), 0);
        assertEq(rewards.stakeOf(alice), 1_000_000 ether);
        assertEq(IERC20(IMD).balanceOf(address(jobs)), price - 1);
        assertEq(IERC20(IMD).allowance(address(jobs), INTAKE), 0);

        deal(IMD, address(jobs), price);
        vm.prank(alice);
        vm.expectRevert(JobsVault.InvalidBody.selector);
        jobs.requestJob(new bytes(16_385));
        assertEq(rewards.lockedUntil(alice), 0);
        vm.expectEmit(false, true, true, true, INTAKE);
        emit Requested(bytes32(0), address(jobs), bytes32("job.open@job-1"), body, address(0), bytes4(0), IMD, price);
        vm.prank(alice);
        jobs.requestJob(body);
        assertEq(rewards.lockedUntil(alice), block.timestamp + 1 days);
        assertEq(jobs.nextJobAt(alice), block.timestamp + 1 days);
        assertEq(IERC20(IMD).balanceOf(address(jobs)), 0);
        assertEq(IERC20(IMD).allowance(address(jobs), INTAKE), 0);
    }

    function testFork_originalAirdropCommitmentRejectsForgedClaimAndBurnsAtExpiry() public {
        _bind();
        assertEq(drop.MERKLE_ROOT(), 0xe1fc34a5aee64c3cd01e62934929bc57511b5718c2f5ae80072ae25045e50cb4);
        uint256 balance = token.balanceOf(address(drop));
        uint256 weight = drop.TOTAL_WEIGHT();
        vm.prank(alice);
        vm.expectRevert(SimdAirdrop.InvalidProof.selector);
        drop.claim(weight, new bytes32[](0));
        assertFalse(drop.claimed(alice));
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(address(drop)), balance);
        vm.warp(drop.claimEnd() - 1);
        vm.expectRevert(SimdAirdrop.ClaimStillOpen.selector);
        drop.burnUnclaimed();
        _advance(1);
        vm.prank(alice);
        vm.expectRevert(SimdAirdrop.ClaimClosed.selector);
        drop.claim(1, new bytes32[](0));
        vm.prank(bob);
        drop.burnUnclaimed();
        assertEq(token.balanceOf(address(drop)), 0);
        assertEq(token.balanceOf(DEAD), balance);
    }

    function testFork_airdropFixtureProofsDeadlineAndBurn() public {
        uint256 weight = drop.TOTAL_WEIGHT() / 2;
        _installFixtureRoot(drop, _pair(_leaf(alice, weight), _leaf(bob, weight)));
        _bind();
        bytes32[] memory proof = _proof(_leaf(bob, weight));
        uint256 amount = drop.amountOf(weight);
        vm.prank(carol);
        vm.expectRevert(SimdAirdrop.InvalidProof.selector);
        drop.claim(weight, proof);
        vm.prank(alice);
        vm.expectRevert(SimdAirdrop.InvalidProof.selector);
        drop.claim(weight + 1, proof);
        vm.prank(alice);
        drop.claim(weight, proof);
        assertEq(token.balanceOf(alice), amount);
        vm.prank(alice);
        vm.expectRevert(SimdAirdrop.AlreadyClaimed.selector);
        drop.claim(weight, proof);
        vm.warp(drop.claimEnd() - 1);
        vm.expectRevert(SimdAirdrop.ClaimStillOpen.selector);
        drop.burnUnclaimed();
        _advance(1);
        vm.prank(bob);
        vm.expectRevert(SimdAirdrop.ClaimClosed.selector);
        drop.claim(weight, _proof(_leaf(alice, weight)));
        uint256 remaining = token.balanceOf(address(drop));
        drop.burnUnclaimed();
        assertEq(token.balanceOf(DEAD), remaining);
    }

    /// forge-config: default.fuzz.runs = 256
    function testFuzz_forkNeverOverpaysAndBalanceCoversReserved(uint128 a, uint128 b, uint32 elapsed) public {
        _bind();
        uint256 amountA = bound(uint256(a), 1, 1e28);
        uint256 amountB = bound(uint256(b), 1, 1e28);
        _stake(alice, amountA);
        _stake(bob, amountB);
        _deposit(amountA);
        _advance(uint256(elapsed) % (2 * WEEK));
        _claim(alice);
        _deposit(amountB);
        _advance(WEEK);
        _claim(bob);
        _claim(alice);
        uint256 paid = IERC20(IMD).balanceOf(alice) + IERC20(IMD).balanceOf(bob);
        assertLe(paid, amountA + amountB);
        assertGe(IERC20(IMD).balanceOf(address(rewards)), rewards.reserved());
        assertEq(paid + rewards.reserved(), amountA + amountB);
    }
}
