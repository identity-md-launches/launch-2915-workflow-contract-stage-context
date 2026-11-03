// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseTest} from "./Base.t.sol";
import {UnlockV2Hook} from "../src/UnlockV2Hook.sol";
import {MigrationVault} from "../src/MigrationVault.sol";
import {RewardPot} from "../src/RewardPot.sol";

/// @notice MOCK checks (local PoolManager, mock IMD / V1 / feed): adversarial scenarios not covered by
///         the earlier suites — migration exhaustion, mixed origins across gates, recycling attempts,
///         late migration, founder credit, gate races, epoch boundaries, idle periods, concurrent claims.
contract ScenariosTest is BaseTest {
    address internal carol = makeAddr("carol");
    address internal dave = makeAddr("dave");
    uint256 internal t0;

    function setUp() public override {
        super.setUp();
        fullLaunch();
        t0 = vm.getBlockTimestamp();
        giveImd(alice, 1e26);
        giveImd(bob, 1e26);
        giveImd(carol, 1e27);
    }

    function _migrate(address who, uint256 amount) internal {
        v1.mint(who, amount);
        vm.startPrank(who);
        v1.approve(address(vault), amount);
        vault.migrate(amount);
        vm.stopPrank();
    }

    function _warp(uint256 t) internal {
        vm.warp(t);
        feed.set(ETH_USD, t);
    }

    function _openGate1ByContribution() internal {
        vm.prank(OWNER);
        token.contribute(1, 25_000_000e18);
        assertEq(hook.gatesOpen(), 1);
    }

    // ------------------------------------------------------------------ activation / founder

    function test_activateTwiceRevertsAndFounderCreditIsExactly50m() public {
        vm.prank(OWNER);
        vm.expectRevert(UnlockV2Hook.Sealed.selector);
        hook.activate();
        // owner holds 50m after funding the vault, credited exactly 50m (never the 750m remainder)
        UnlockV2Hook.Rights memory r = hook.rightsOf(OWNER);
        assertEq(r.otherCredited, 50_000_000e18);
        assertEq(hook.sellAllowance(OWNER), 0, "founder has 0% before gate 1");
        _openGate1ByContribution();
        // contribution burned 25m of the founder's credited tokens (conservative debit)
        r = hook.rightsOf(OWNER);
        assertEq(r.otherCredited, 25_000_000e18);
        assertEq(hook.sellAllowance(OWNER), 25_000_000e18 * 25 / 100);
    }

    // ------------------------------------------------------------------ migration

    function test_migrationExhaustion_firstComeAndNoDoubleCredit() public {
        _migrate(alice, 600_000_000e18);
        assertEq(hook.rightsOf(alice).otherCredited, 600_000_000e18);
        // bob asks for more than what is left: rejected, nothing pulled
        v1.mint(bob, 200_000_000e18);
        vm.startPrank(bob);
        v1.approve(address(vault), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(MigrationVault.ExceedsCapacity.selector, 100_000_000e18));
        vault.migrate(100_000_000e18 + 1);
        assertEq(v1.balanceOf(bob), 200_000_000e18);
        vault.migrate(100_000_000e18);
        vm.expectRevert(abi.encodeWithSelector(MigrationVault.ExceedsCapacity.selector, 0));
        vault.migrate(1);
        vm.stopPrank();
        assertEq(hook.rightsOf(bob).otherCredited, 100_000_000e18);
        assertEq(vault.totalMigrated(), 700_000_000e18);
        assertEq(vault.lockedV1(), 700_000_000e18);
        assertEq(token.balanceOf(address(vault)), 0);
        // tokens donated to the exhausted vault do not reopen capacity
        vm.prank(OWNER);
        token.transfer(address(vault), 1e18);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(MigrationVault.ExceedsCapacity.selector, 0));
        vault.migrate(1);
        // migrated V2 passed around does not create a second credit
        vm.prank(alice);
        token.transfer(dave, 1000e18);
        assertEq(hook.rightsOf(dave).otherCredited, 0);
    }

    function test_lateMigrationAfterGatesGetsCurrentGlobalPercent() public {
        _openGate1ByContribution();
        _migrate(alice, 1000e18);
        assertEq(hook.sellAllowance(alice), 250e18, "late migration respects current 25%");
        sell(alice, -250e18);
        assertEq(hook.sellAllowance(alice), 0);
        vm.expectRevert();
        sell(alice, -1);
    }

    // ------------------------------------------------------------------ mixed origins / cumulative sales

    function test_mixedOriginsAndCumulativeSalesAcrossGates() public {
        buy(alice, -1000e18);
        vm.roll(vm.getBlockNumber() + 1);
        uint256 bought = hook.rightsOf(alice).buyCredited;
        _migrate(alice, 1000e18);
        // before gate 1 only the buy bucket sells (20%); migrated bucket 0%
        assertEq(hook.sellAllowance(alice), bought * 20 / 100);
        sell(alice, -int256(bought * 20 / 100));
        assertEq(hook.sellAllowance(alice), 0);
        vm.expectRevert();
        sell(alice, -1e18);

        // gate 1: both buckets at 25%; previous sales still count, nothing resets
        _openGate1ByContribution();
        UnlockV2Hook.Rights memory r = hook.rightsOf(alice);
        assertEq(r.buySold, bought * 20 / 100);
        uint256 expected = (bought * 25 / 100 - bought * 20 / 100) + 1000e18 * 25 / 100;
        assertEq(hook.sellAllowance(alice), expected);
        sell(alice, -int256(expected));
        r = hook.rightsOf(alice);
        assertEq(uint256(r.buySold) + r.otherSold, bought * 20 / 100 + expected);
        assertEq(hook.sellAllowance(alice), 0);
    }

    // ------------------------------------------------------------------ recycling attempts

    function test_transferRoundTripDoesNotCreateNewRights() public {
        buy(alice, -1000e18);
        vm.roll(vm.getBlockNumber() + 1);
        uint256 bal = token.balanceOf(alice);
        uint256 allowance = hook.sellAllowance(alice);
        vm.prank(alice);
        token.transfer(bob, bal);
        assertEq(hook.sellAllowance(bob), 0, "incoming transfer grants nothing");
        assertEq(hook.sellAllowance(alice), allowance, "outgoing transfer does not touch rights");
        vm.prank(bob);
        token.transfer(alice, bal);
        assertEq(hook.sellAllowance(alice), allowance, "round trip grants nothing");
        sell(alice, -int256(allowance));
        assertEq(hook.sellAllowance(alice), 0);
        // bob cannot sell what he briefly held
        vm.prank(alice);
        token.transfer(bob, 10e18);
        vm.expectRevert();
        sell(bob, -10e18);
    }

    function test_burnAfterPartialSaleCannotRecycleEligibility() public {
        buy(alice, -1000e18);
        vm.roll(vm.getBlockNumber() + 1);
        uint256 bought = token.balanceOf(alice);
        sell(alice, -int256(bought * 20 / 100));
        assertEq(hook.sellAllowance(alice), 0);
        vm.startPrank(alice);
        token.burn(token.balanceOf(alice) / 2);
        vm.stopPrank();
        assertEq(hook.sellAllowance(alice), 0, "burn never creates allowance");
        _openGate1ByContribution();
        UnlockV2Hook.Rights memory r = hook.rightsOf(alice);
        uint256 cap = uint256(r.buyCredited) * 25 / 100;
        assertEq(hook.sellAllowance(alice), cap > r.buySold ? cap - r.buySold : 0);
        assertLe(hook.sellAllowance(alice), bought * 25 / 100 - bought * 20 / 100);
    }

    /// forge-config: default.fuzz.runs = 256
    function testFuzz_burnNeverIncreasesAllowance(uint96 buyIn, uint96 migrated, uint96 sold, uint96 burnAmt, bool gate)
        public
    {
        buyIn = uint96(bound(buyIn, 1e18, 1500e18));
        migrated = uint96(bound(migrated, 0, 1e24));
        buy(alice, -int256(uint256(buyIn)));
        vm.roll(vm.getBlockNumber() + 1);
        if (migrated > 0) _migrate(alice, migrated);
        if (gate) _openGate1ByContribution();
        uint256 a0 = hook.sellAllowance(alice);
        uint256 s = bound(sold, 0, a0);
        if (s > 0) sell(alice, -int256(s));
        buy(alice, -1e18); // pending credit in this block
        uint256 a1 = hook.sellAllowance(alice);
        uint256 b = bound(burnAmt, 1, token.balanceOf(alice));
        (,,,, uint256 previewAfter) = hook.previewBurn(alice, b);
        vm.prank(alice);
        token.burn(b);
        assertEq(hook.sellAllowance(alice), previewAfter, "preview matches burn");
        assertLe(previewAfter, a1, "burn increased allowance");
        vm.roll(vm.getBlockNumber() + 1);
        UnlockV2Hook.Rights memory r = hook.rightsOf(alice);
        assertEq(uint256(r.buySold) + r.otherSold, s, "sales never reset by burn");
    }

    // ------------------------------------------------------------------ one-block buys / shared router

    function test_sameBlockBuyCannotBeSold_evenWithOtherCredits() public {
        _openGate1ByContribution();
        buy(alice, -1000e18);
        assertEq(hook.sellAllowance(alice), 0);
        vm.expectRevert();
        sell(alice, -1);
        vm.roll(vm.getBlockNumber() + 1);
        assertGt(hook.sellAllowance(alice), 0);
    }

    function test_sharedRouterUsersShareOneBucket() public {
        // unregistered router: every user is the router account (documented limitation)
        buyShared(alice, -1000e18);
        vm.roll(vm.getBlockNumber() + 1);
        uint256 shared = hook.sellAllowance(address(swapRouter));
        assertGt(shared, 0);
        assertEq(hook.sellAllowance(alice), 0);
        // bob, who never bought, spends the shared allowance created by alice's buy
        vm.prank(alice);
        token.transfer(bob, shared);
        sellShared(bob, -int256(shared));
        assertEq(hook.sellAllowance(address(swapRouter)), 0);
        vm.expectRevert();
        sellShared(alice, -1e18);
    }

    // ------------------------------------------------------------------ gates

    function test_gateRace_secondContributorWithStaleQuoteIsRejected() public {
        token.transfer(alice, 30_000_000e18);
        token.transfer(bob, 30_000_000e18);
        (uint8 g, uint256 maxAmount) = hook.contributionQuote();
        assertEq(g, 1);
        // both read the same quote; alice lands first and opens gate 1
        vm.prank(alice);
        token.contribute(g, maxAmount);
        assertEq(hook.gatesOpen(), 1);
        uint256 bobBal = token.balanceOf(bob);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(UnlockV2Hook.StaleGate.selector, 1, 2));
        token.contribute(g, maxAmount);
        assertEq(token.balanceOf(bob), bobBal, "rejected contribution burns nothing");
        // bob on gate 2 with more than the target: rejected; exact target opens gate 2
        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(UnlockV2Hook.ExceedsGateRemaining.selector, 22_000_000e18 + 1, 22_000_000e18)
        );
        token.contribute(2, 22_000_000e18 + 1);
        vm.prank(bob);
        token.contribute(2, 22_000_000e18);
        assertEq(hook.gatesOpen(), 2);
        assertEq(hook.burnProgress(), 0);
    }

    /// Re-check of finding 3284f846 (spot FDV + gate-10 bypass in one transaction): after the fix the
    /// spike opens nothing inside its own block and the buyer cannot sell it back there.
    function test_inBlockSpikeOpensNothingAndCannotBeSoldBack() public {
        uint256 imdBefore = imd.balanceOf(carol);
        buy(carol, -5000e18);
        (uint256 spotFdv,) = hook.fdvUsd();
        (, uint256 fdvT10,,) = hook.gate(10);
        assertGe(spotFdv, fdvT10, "spot FDV is past gate 10");
        assertEq(hook.gatesOpen(), 0, "spike read in its own block");
        assertEq(hook.sellAllowance(OWNER), 0);
        uint256 bal = token.balanceOf(carol);
        vm.expectRevert();
        sell(carol, -int256(bal));
        // the block's one reading was taken before the spike; nothing in this block re-reads it
        assertEq(hook.lastFdvBlock(), vm.getBlockNumber());
        assertEq(hook.gatesOpen(), 0);
        assertEq(token.balanceOf(carol), bal);
        assertLt(imd.balanceOf(carol), imdBefore, "the spike's IMD stays at risk");
    }

    function test_gatesNeverRelockWhenPriceFalls() public {
        // one buy that exhausts the mock pool's in-range liquidity spikes the spot FDV past every gate;
        // it is read at the next block's first swap (price held across one block boundary, disclosed)
        buy(carol, -5000e18);
        assertEq(hook.gatesOpen(), 0);
        vm.roll(vm.getBlockNumber() + 1);
        // carol's sell is the next block's first swap: the settled reading opens every gate first
        sell(carol, -int256(token.balanceOf(carol) / 2));
        assertEq(hook.gatesOpen(), 10);
        // price and ETH/USD then collapse: gates stay open forever
        feed.set(1e8, vm.getBlockTimestamp());
        vm.roll(vm.getBlockNumber() + 1);
        sell(carol, -int256(token.balanceOf(carol)));
        (uint256 fdv,) = hook.fdvUsd();
        (, uint256 fdvT1,,) = hook.gate(1);
        assertLt(fdv, fdvT1);
        assertEq(hook.gatesOpen(), 10);
        assertEq(hook.sellAllowance(alice), type(uint256).max);
    }

    /// Re-check of finding e4f2d829 (views did not preview the block's pending FDV reading), fixed by
    /// pendingGatesOpen(): the original reproduction — a spike held over a block boundary, then a sell
    /// above the stored allowance as the next block's first swap.
    function test_pendingGatesOpen_previewsHeldSpikeBeforeFirstSwap() public {
        buy(carol, -5000e18);
        // same block: the reading already happened, the preview does not re-read the spiked price
        assertEq(hook.lastFdvBlock(), vm.getBlockNumber());
        assertEq(hook.pendingGatesOpen(), 0, "no second reading inside the spike's block");

        vm.roll(vm.getBlockNumber() + 1);
        assertEq(hook.gatesOpen(), 0, "stored state");
        uint256 bal = token.balanceOf(carol);
        assertLt(hook.sellAllowance(carol), bal, "stored allowance: 20% of the matured buy before gate 1");
        (uint8 quoted,) = hook.contributionQuote();
        assertEq(quoted, 1, "stored quote");
        assertEq(hook.pendingGatesOpen(), 10, "preview: the reading opens every gate");

        // the sell beyond the stored allowance is judged under the previewed gates
        sell(carol, -int256(bal));
        assertEq(token.balanceOf(carol), 0);
        assertEq(hook.gatesOpen(), 10);
        assertEq(hook.pendingGatesOpen(), 10);

        // a contribution quoted from the stored state is rejected once the reading has opened gate 10
        vm.prank(OWNER);
        vm.expectRevert(UnlockV2Hook.GoldenVaultOpen.selector);
        token.contribute(quoted, 1e18);
    }

    function test_pendingGatesOpen_staleFeedPreviewsNothing() public {
        // ETH/USD jumps 10x (settled FDV ~ 1m USD: gates 1-3) but the update is a day old: invalid reading
        _warp(t0 + 1 days);
        feed.set(30_000e8, t0);
        vm.roll(vm.getBlockNumber() + 1);
        assertEq(hook.pendingGatesOpen(), 0, "invalid reading previews nothing");
        buy(alice, -1e15);
        assertEq(hook.gatesOpen(), 0, "and opens nothing");
        // same price, fresh: the next block's reading opens what it supports, as previewed
        feed.set(30_000e8, vm.getBlockTimestamp());
        assertEq(hook.pendingGatesOpen(), 0, "already read in this block");
        vm.roll(vm.getBlockNumber() + 1);
        assertEq(hook.pendingGatesOpen(), 3);
        buy(alice, -1e15);
        assertEq(hook.gatesOpen(), 3);
    }

    /// The preview over a gate that had burn progress: the progress belongs to the gate collecting burns
    /// and must not be counted again toward the gates an FDV reading opens after it (_advanceGates
    /// restarts it at zero). Kept below the smallest burn target (2m), where the preview is exact; the
    /// case above it is a reported finding (.imd-findings.json), not asserted here.
    function test_pendingGatesOpen_withSmallBurnProgressMatchesReading() public {
        vm.prank(OWNER);
        token.contribute(1, 1_000_000e18);
        feed.set(9_000e8, vm.getBlockTimestamp()); // settled FDV ~ 300k: gate 1 only
        vm.roll(vm.getBlockNumber() + 1);
        assertEq(hook.pendingGatesOpen(), 1);
        buy(alice, -1e15);
        assertEq(hook.gatesOpen(), 1);
        assertEq(hook.burnProgress(), 0, "gate 2 starts its burn count from zero");
    }

    // ------------------------------------------------------------------ stale feeds / idle

    function test_staleFeedVariants_noVolumeButTradesAndContributionsWork() public {
        uint256 vol = hook.cumulativeVolumeUsd();
        // stale by age
        _warp(t0 + 1 days);
        feed.set(ETH_USD, t0);
        buy(alice, -100e18);
        assertEq(hook.cumulativeVolumeUsd(), vol);
        // future timestamp, negative answer, incomplete round, reverting feed
        feed.set(ETH_USD, vm.getBlockTimestamp() + 1);
        buy(alice, -100e18);
        feed.set(-1, vm.getBlockTimestamp());
        buy(alice, -100e18);
        feed.set(ETH_USD, vm.getBlockTimestamp());
        feed.setRounds(5, 4);
        buy(alice, -100e18);
        feed.setRounds(1, 1);
        feed.setRevert(true);
        buy(alice, -100e18);
        assertEq(hook.cumulativeVolumeUsd(), vol, "invalid prices never add volume");
        // contributions still open gates on a dead feed
        _openGate1ByContribution();
        feed.setRevert(false);
        buy(alice, -100e18);
        assertGt(hook.cumulativeVolumeUsd(), vol);
    }

    function test_longIdle_rewardsSurviveAndPrePointStreamCompletes() public {
        buy(carol, -1000e18); // 10 IMD pre-point fee
        assertEq(pot.prePointPot(), 10e18);
        token.transfer(alice, 1000e18);
        vm.prank(alice);
        token.burn(1000e18);
        // nobody touches anything for ~3 years (150+ epochs)
        _warp(t0 + 1100 days);
        (uint256 claimableNow, uint256 maturing) = pot.rewardsOf(alice);
        assertEq(maturing, 0);
        assertApproxEqAbs(claimableNow, 10e18, 1e6);
        vm.prank(alice);
        uint256 got = pot.claim();
        assertEq(got, claimableNow);
        assertEq(imd.balanceOf(alice) - 1e26, got);
        assertTrue(pot.isSolvent());
    }

    function test_lateBurnerGetsNothingFromFinishedPrePointStream() public {
        buy(carol, -1000e18);
        token.transfer(alice, 1000e18);
        token.transfer(bob, 1000e18);
        vm.prank(alice);
        token.burn(1000e18);
        _warp(t0 + 8 days);
        vm.prank(bob);
        token.burn(1000e18);
        _warp(t0 + 30 days);
        assertEq(pot.claimable(bob), 0);
        assertApproxEqAbs(pot.claimable(alice), 10e18, 1e6);
    }

    // ------------------------------------------------------------------ epochs / claims

    function test_weeklyBoundary_feeOneSecondBeforeVsAtBoundary() public {
        token.transfer(alice, 1000e18);
        vm.prank(alice);
        token.burn(1000e18);
        _warp(t0 + 7 days - 1);
        buy(carol, -1000e18); // 10 IMD in epoch 0
        _warp(t0 + 7 days);
        assertEq(pot.currentEpoch(), 1);
        assertApproxEqAbs(pot.claimable(alice), 10e18, 1e6);
        buy(carol, -1000e18); // 10 IMD in epoch 1, matures only at t0 + 14 days
        (uint256 c, uint256 m) = pot.rewardsOf(alice);
        assertApproxEqAbs(c, 10e18, 1e6);
        assertApproxEqAbs(m, 10e18, 1e6);
        vm.prank(alice);
        pot.claim();
        vm.prank(alice);
        vm.expectRevert(RewardPot.NothingToClaim.selector);
        pot.claim();
        _warp(t0 + 14 days - 1);
        assertEq(pot.claimable(alice), 0);
        _warp(t0 + 14 days);
        assertApproxEqAbs(pot.claimable(alice), 10e18, 1e6);
    }

    function test_concurrentClaims_sameBlock_neverOverpay() public {
        token.transfer(alice, 3000e18);
        token.transfer(bob, 1000e18);
        vm.prank(alice);
        token.burn(3000e18);
        vm.prank(bob);
        token.burn(1000e18);
        buy(carol, -2000e18); // 20 IMD split 3:1
        _warp(t0 + 7 days);
        // nobody redeemed: the first claim redeems, the second is paid from the same transfer
        assertEq(imd.balanceOf(address(pot)), 0);
        vm.prank(bob);
        uint256 b = pot.claim();
        vm.prank(alice);
        uint256 a = pot.claim();
        assertApproxEqAbs(a, 15e18, 1e6);
        assertApproxEqAbs(b, 5e18, 1e6);
        assertLe(a + b, pot.totalAccrued());
        (uint256 accrued,,, uint256 paid, uint256 unredeemed, uint256 held,) = pot.solvency();
        assertEq(held + unredeemed, accrued - paid);
        // the owner and non-burners have nothing to claim
        vm.prank(OWNER);
        vm.expectRevert(RewardPot.NothingToClaim.selector);
        pot.claim();
    }

    function test_feeConservation_everySwapShape() public {
        buy(alice, -1000e18); // exact-in buy
        buy(alice, 1000e18); // exact-out buy
        vm.roll(vm.getBlockNumber() + 1);
        uint256 a = hook.sellAllowance(alice);
        sell(alice, -int256(a / 4)); // exact-in sell
        sell(alice, 1e15); // exact-out sell (IMD out)
        // every fee the hook minted itself is attributed to the pot, and nothing else
        assertEq(hook.pendingFees(), pot.totalAccrued());
        assertEq(pot.prePointPot(), pot.totalAccrued(), "no points yet: all fees pre-point");
        hook.redeemFees();
        assertEq(imd.balanceOf(address(pot)), pot.totalAccrued());
        vm.expectRevert(UnlockV2Hook.NothingToRedeem.selector);
        hook.redeemFees();
    }
}
