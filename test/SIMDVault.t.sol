// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {VaultTestBase} from "./helpers/VaultTestBase.sol";
import {SIMDVault} from "../src/SIMDVault.sol";
import {StakeRewards} from "../src/StakeRewards.sol";
import {LaunchPool} from "../src/libraries/LaunchPool.sol";
import {IntakePayment} from "../src/libraries/IntakePayment.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {RejectNative, ExhaustNative} from "./mocks/MockFactory.sol";

contract SIMDVaultTest is VaultTestBase {
    event Distributed(uint256 staking, uint256 jobs, uint256 dev, uint256 marketing);

    function test_individualDevMarketingSharesAndDustAreReportedSeparately() public {
        _bind(false);
        imd.mint(address(vault), 10_003);
        vm.expectEmit(false, false, false, true, address(vault));
        emit Distributed(4001, 2572, 1714, 1716);
        vault.distribute();
        assertEq(imd.balanceOf(DEV), 3430);
    }

    function test_constructorLinksChildrenWithNoExternalDependencies() public {
        vm.etch(IMD, "");
        vm.etch(INTAKE, "");
        vm.etch(FACTORY, "");
        SIMDVault v = new SIMDVault();
        assertEq(v.stakeRewards().vault(), address(v));
        assertEq(v.jobsVault().vault(), address(v));
        assertEq(v.airdrop().vault(), address(v));
        assertEq(address(v.jobsVault().stakeRewards()), address(v.stakeRewards()));
        assertEq(v.stakeRewards().jobsVault(), address(v.jobsVault()));
        assertEq(v.NOTICE(), NOTICE);
        assertEq(v.stakeRewards().NOTICE(), NOTICE);
        assertEq(v.jobsVault().NOTICE(), NOTICE);
        assertEq(v.airdrop().NOTICE(), NOTICE);
        assertLt(address(v).code.length, 24_577);
        assertLt(type(SIMDVault).creationCode.length, 49_153);
    }

    function test_launchOnlyDevOnceExactPaymentAndReset() public {
        imd.mint(address(vault), 10 ether);
        bytes memory body = bytes('{"objective":"SIMD TEST 3 - DO NOT BUY","onchain":"custom_token"}');
        vm.expectRevert(SIMDVault.NotDev.selector);
        vault.launch(body);
        vm.prank(DEV);
        bytes32 id = vault.launch(body);
        assertTrue(id != bytes32(0));
        assertEq(intake.lastBody(), body);
        assertEq(intake.lastPayer(), address(vault));
        assertEq(intake.lastAction(), bytes32("launch.open@launch-1"));
        assertEq(intake.lastAsset(), IMD);
        assertEq(intake.lastAmount(), PRICE);
        assertEq(intake.allowanceObserved(), PRICE);
        assertEq(intake.lastTarget(), address(0));
        assertEq(intake.lastSelector(), bytes4(0));
        assertEq(imd.allowance(address(vault), INTAKE), 0);
        assertEq(imd.balanceOf(treasury), PRICE);
        vm.prank(DEV);
        vm.expectRevert(SIMDVault.AlreadyLaunched.selector);
        vault.launch(body);
    }

    function test_rejectedLaunchRollsBackAndCanRetryAtNewPrice() public {
        imd.mint(address(vault), 10 ether);
        intake.configure(PRICE, true, false);
        vm.prank(DEV);
        vm.expectRevert("intake rejected");
        vault.launch("{}");
        assertFalse(vault.launched());
        assertEq(imd.allowance(address(vault), INTAKE), 0);
        intake.configure(2 ether, false, false);
        vm.prank(DEV);
        vault.launch("{}");
        assertEq(imd.balanceOf(treasury), 2 ether);
    }

    function test_unsoldActionAndInsufficientFundingFailWithoutConsumingLaunch() public {
        intake.configure(0, false, false);
        vm.prank(DEV);
        vm.expectRevert(IntakePayment.ActionNotSold.selector);
        vault.launch("{}");
        intake.configure(PRICE, false, false);
        vm.prank(DEV);
        vm.expectRevert();
        vault.launch("{}");
        assertFalse(vault.launched());
    }

    function test_resetEvenIfIntakeDoesNotSpendFullApproval() public {
        imd.mint(address(vault), PRICE);
        intake.configure(PRICE, false, true);
        vm.prank(DEV);
        vault.launch("{}");
        assertEq(imd.allowance(address(vault), INTAKE), 0);
    }

    function test_bindingOnlyDevOnceAndBindsFundedAirdropAtomically() public {
        vm.expectRevert(SIMDVault.NotDev.selector);
        vault.bindLaunch(NUMBER, address(launchedToken));
        _bind(true);
        assertEq(vault.token(), address(launchedToken));
        assertEq(vault.launchNumber(), NUMBER);
        assertEq(rewards.token(), address(launchedToken));
        assertEq(jobs.token(), address(launchedToken));
        assertEq(drop.token(), address(launchedToken));
        assertEq(drop.claimEnd(), block.timestamp + 30 days);
        vm.prank(DEV);
        vm.expectRevert(SIMDVault.AlreadyBound.selector);
        vault.bindLaunch(NUMBER + 1, address(launchedToken));
    }

    function test_bindRejectsForeignRequesterWrongTokenAndEveryBadPair() public {
        factory.setPosition(NUMBER, IMD, address(launchedToken), alice);
        vm.prank(DEV);
        vm.expectRevert(LaunchPool.WrongRequester.selector);
        vault.bindLaunch(NUMBER, address(launchedToken));
        factory.setPosition(NUMBER, IMD, address(launchedToken), address(vault));
        vm.prank(DEV);
        vm.expectRevert(SIMDVault.WrongToken.selector);
        vault.bindLaunch(NUMBER, IMD);
        address[4] memory a = [address(launchedToken), IMD, IMD, IMD];
        address[4] memory b = [address(launchedToken), IMD, alice, address(0)];
        for (uint256 i; i < a.length; ++i) {
            factory.setPosition(NUMBER, a[i], b[i], address(vault));
            vm.prank(DEV);
            vm.expectRevert(LaunchPool.InvalidPair.selector);
            vault.bindLaunch(NUMBER, b[i]);
        }
        assertEq(vault.token(), address(0));
        assertEq(rewards.token(), address(0));
    }

    function test_bindAcceptsReverseCurrencyOrder() public {
        factory.setPosition(NUMBER, address(launchedToken), IMD, address(vault));
        _bind(true);
        assertEq(drop.token(), address(launchedToken));
    }

    function test_failedAirdropBindDoesNotBlockAndAnyoneRetries() public {
        vm.expectRevert(SIMDVault.NotBound.selector);
        vault.bindAirdrop();
        _bind(false);
        assertEq(drop.token(), address(0));
        assertEq(rewards.token(), address(launchedToken));
        launchedToken.mint(address(drop), drop.TOTAL_WEIGHT());
        vm.prank(alice);
        vault.bindAirdrop();
        assertEq(drop.startBalance(), drop.TOTAL_WEIGHT());
        vm.expectRevert();
        vault.bindAirdrop();
    }

    function test_firstDistributionImmediateClaimsFeesSplitsAndBurns() public {
        _bind(false);
        imd.mint(address(vault), 9000 ether);
        imd.mint(FACTORY, 1000 ether);
        launchedToken.mint(address(vault), 12 ether);
        launchedToken.mint(FACTORY, 3 ether);
        factory.configure(1000 ether, 3 ether, 1 ether, 0);
        vm.deal(FACTORY, 1 ether);
        uint256 nativeBefore = MARKETING.balance;
        vault.distribute();
        assertEq(factory.claimCalls(), 1);
        assertEq(imd.balanceOf(address(vault)), 0);
        assertEq(imd.balanceOf(address(rewards)), 4000 ether);
        assertEq(rewards.reserved(), 4000 ether);
        assertEq(imd.balanceOf(address(jobs)), 2572 ether);
        // The brief names the same wallet twice, so it receives both distinct payments.
        assertEq(imd.balanceOf(DEV), 3428 ether);
        assertEq(launchedToken.balanceOf(DEAD), 15 ether);
        assertEq(MARKETING.balance - nativeBefore, 1 ether);
        assertEq(address(vault).balance, 0);
    }

    function test_distributionBeforeBindAndBeforeSevenDaysFailsExactBoundaryWorks() public {
        vm.expectRevert(SIMDVault.NotBound.selector);
        vault.distribute();
        _bind(false);
        vault.distribute();
        uint256 next = vault.nextDistributionAt();
        _advance(WEEK - 1);
        vm.expectRevert(abi.encodeWithSelector(SIMDVault.TooSoon.selector, next));
        vault.distribute();
        _advance(1);
        vault.distribute();
        assertEq(vault.nextDistributionAt(), next + WEEK);
    }

    function test_failedFeeCollectionIncludingExhaustedGasStillSplitsAndBurns() public {
        _bind(false);
        for (uint8 mode = 1; mode <= 2; ++mode) {
            factory.configure(0, 0, 0, mode);
            imd.mint(address(vault), 10000);
            launchedToken.mint(address(vault), 7);
            vault.distribute{gas: 2_000_000}();
            assertEq(imd.balanceOf(address(vault)), 0);
            assertEq(launchedToken.balanceOf(address(vault)), 0);
            _advance(WEEK);
        }
        assertEq(imd.balanceOf(address(jobs)), 5144);
        assertEq(launchedToken.balanceOf(DEAD), 14);
    }

    function test_revertingFalseNoReturnOutOfGasMalformedBurnDoesNotBlockSplit() public {
        _bind(false);
        launchedToken.mint(address(vault), 100);
        for (uint8 mode = 1; mode <= 5; ++mode) {
            imd.mint(address(vault), 10000);
            launchedToken.configure(0, mode, false);
            vault.distribute{gas: 2_000_000}();
            assertEq(imd.balanceOf(address(vault)), 0);
            if (mode < 3) assertEq(launchedToken.balanceOf(address(vault)), 100);
            if (mode == 3) assertEq(launchedToken.balanceOf(DEAD), 100);
            if (mode >= 3) launchedToken.mint(address(vault), 100);
            _advance(WEEK);
        }
    }

    function test_badTokenBalanceCannotBlockIMDOrNativePayments() public {
        _bind(false);
        launchedToken.configure(0, 0, true);
        imd.mint(address(vault), 10000);
        vm.deal(address(vault), 1 ether);
        uint256 before = MARKETING.balance;
        vault.distribute();
        assertEq(imd.balanceOf(address(jobs)), 2572);
        assertEq(MARKETING.balance - before, 1 ether);
    }

    function test_nativeRejectionAndExhaustedStipendNeverBlockBurnOrSplit() public {
        _bind(false);
        address[2] memory rejectors = [address(new RejectNative()), address(new ExhaustNative())];
        for (uint256 i; i < rejectors.length; ++i) {
            vm.etch(MARKETING, rejectors[i].code);
            imd.mint(address(vault), 10000);
            launchedToken.mint(address(vault), 7);
            vm.deal(address(vault), 1 ether);
            vault.distribute{gas: 2_000_000}();
            assertEq(address(vault).balance, 1 ether);
            assertEq(launchedToken.balanceOf(address(vault)), 0);
            assertEq(imd.balanceOf(address(vault)), 0);
            _advance(WEEK);
        }
        vm.etch(MARKETING, "");
        vault.distribute();
        assertEq(address(vault).balance, 0);
    }

    function test_feeCallbackCannotDistributeTwice() public {
        _bind(false);
        factory.configure(0, 0, 0, 3);
        imd.mint(address(vault), 10000);
        vault.distribute();
        assertTrue(factory.reentryBlocked());
        assertEq(factory.claimCalls(), 1);
    }

    function test_receiveNative() public {
        vm.deal(address(this), 1 ether);
        (bool ok,) = address(vault).call{value: 1 ether}("");
        assertTrue(ok);
        assertEq(address(vault).balance, 1 ether);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_splitConservesEveryWei(uint256 balance) public {
        balance = bound(balance, 0, 1e34);
        _bind(false);
        imd.mint(address(vault), balance);
        vault.distribute();
        uint256 s = imd.balanceOf(address(rewards));
        uint256 j = imd.balanceOf(address(jobs));
        uint256 d = imd.balanceOf(DEV);
        assertEq(s, balance * 4000 / 10000);
        assertEq(j, balance * 2572 / 10000);
        assertEq(s + j + d, balance);
        assertEq(imd.balanceOf(address(vault)), 0);
    }
}
