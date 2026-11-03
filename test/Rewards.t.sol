// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseTest} from "./Base.t.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/types/PoolOperation.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {UnlockV2Hook} from "../src/UnlockV2Hook.sol";
import {UnlockV2Token} from "../src/UnlockV2Token.sol";
import {RewardPot} from "../src/RewardPot.sol";

/// @dev Rewards are checked against the brief, not the implementation:
///      pre-point pot streamed linearly over 7 days from the first point to the points present in each
///      slice; later fees split at the time earned; epochs of 7 days from activation; closed-epoch
///      entitlements claimable forever; only the beneficiary claims.
contract RewardsTest is BaseTest {
    address internal carol = makeAddr("carol"); // trader generating fees
    address internal dave = makeAddr("dave");
    uint256 internal t0; // activation time = epoch 0 start

    function setUp() public override {
        super.setUp();
        fullLaunch();
        t0 = vm.getBlockTimestamp();
        giveImd(carol, 1e27);
        // the test contract (factory stand-in) still holds the 100m swarm share minus seeded liquidity
        token.transfer(alice, 10_000_000e18);
        token.transfer(bob, 10_000_000e18);
        token.transfer(dave, 10_000_000e18);
    }

    // ------------------------------------------------------------------ helpers

    /// @dev Exact-input buy of `imdIn` IMD by carol: earns exactly floor(imdIn / 100) reward fee.
    function fee(uint256 imdIn) internal {
        buy(carol, -int256(imdIn));
    }

    function burnAs(address who, uint256 amount) internal {
        vm.prank(who);
        token.burn(amount);
    }

    function warpTo(uint256 t) internal {
        vm.warp(t);
        // keep the price feed fresh so swaps keep observing valid prices
        feed.set(ETH_USD, t);
    }

    function totals(address who) internal view returns (uint256) {
        (uint256 c, uint256 m) = pot.rewardsOf(who);
        return c + m;
    }

    // ------------------------------------------------------------------ pre-point pot

    function test_feesBeforeFirstPointGoToSeparatePrePointPot() public {
        fee(1000e18);
        assertEq(pot.totalPoints(), 0);
        assertEq(pot.prePointPot(), 10e18);
        assertEq(pot.totalAccrued(), 10e18);
        assertEq(pot.totalVested(), 0);
        assertEq(pot.accRewardPerPoint(), 0);
        assertEq(hook.pendingFees(), 10e18);
    }

    function test_firstBurnStartsLinearSevenDayRelease_notWholePotToFirstBurner() public {
        fee(1000e18); // 10 IMD pre-point
        warpTo(t0 + 1 days);
        burnAs(alice, 1e18);
        assertEq(pot.firstPointTime(), t0 + 1 days);
        // nothing released at the first burn itself
        assertEq(totals(alice), 0);

        // half the release period: 5 IMD, all to the only point holder
        warpTo(t0 + 1 days + 3.5 days);
        assertApproxEqAbs(totals(alice), 5e18, 10);
        burnAs(bob, 1e18); // checkpoint before the point change
        assertApproxEqAbs(totals(alice), 5e18, 10);
        assertEq(totals(bob), 0);

        // second half split 1:1
        warpTo(t0 + 1 days + 7 days);
        assertApproxEqAbs(totals(alice), 7.5e18, 10);
        assertApproxEqAbs(totals(bob), 2.5e18, 10);
        // the pot is fully released, nothing more later
        warpTo(t0 + 30 days);
        assertApproxEqAbs(totals(alice), 7.5e18, 10);
        assertApproxEqAbs(totals(bob), 2.5e18, 10);
        assertEq(pot.prePointReleasedAt(t0 + 30 days), 10e18);
    }

    function test_prePointReleaseSplitAtEpochBoundary() public {
        fee(700e18); // 7 IMD pre-point -> 1 IMD per day once released
        warpTo(t0 + 3 days);
        burnAs(alice, 1e18); // release runs t0+3d .. t0+10d; epoch 1 starts at t0+7d
        warpTo(t0 + 8 days);
        (uint256 c, uint256 m) = pot.rewardsOf(alice);
        // released inside epoch 0 (4 days) is claimable; the day inside epoch 1 is still maturing
        assertApproxEqAbs(c, 4e18, 10);
        assertApproxEqAbs(m, 1e18, 10);
        pot.checkpoint(); // the stored state agrees with the view
        (uint256 c2, uint256 m2) = pot.rewardsOf(alice);
        assertEq(c2, c);
        assertEq(m2, m);
        vm.prank(alice);
        assertApproxEqAbs(pot.claim(), 4e18, 10);
    }

    // ------------------------------------------------------------------ normal accrual

    function test_feesAfterFirstPointAccrueImmediately_noRetroactiveRewards() public {
        burnAs(alice, 1e18); // first point; empty pre-point pot
        fee(1000e18); // 10 IMD to alice right now
        assertEq(totals(alice), 10e18);
        // bob burns later in the same epoch: no share of earlier fees, no end-of-week snapshot
        burnAs(bob, 3e18);
        assertEq(totals(bob), 0);
        fee(1000e18); // split 1:3
        assertApproxEqAbs(totals(alice), 12.5e18, 10);
        assertApproxEqAbs(totals(bob), 7.5e18, 10);
    }

    function test_delayedRedemptionCannotGiveOldFeesToNewPoints() public {
        burnAs(alice, 1e18);
        fee(1000e18); // earned now, IMD still a PoolManager claim
        assertEq(hook.pendingFees(), 10e18);
        warpTo(t0 + 2 days);
        burnAs(bob, 1_000_000e18); // huge late burner
        hook.redeemFees(); // redemption long after the fee was earned
        warpTo(t0 + 7 days);
        assertEq(pot.claimable(alice), 10e18);
        assertEq(totals(bob), 0);
    }

    function test_pointsShareFeesIndefinitely_afterAllGates() public {
        // open all gates by FDV (ETH price spike)
        burnAs(alice, 1e18);
        feed.set(1_000_000e8, vm.getBlockTimestamp());
        fee(1000e18);
        assertEq(hook.gatesOpen(), 10);
        assertTrue(hook.goldenVaultOpen());
        assertEq(pot.points(alice), 1e18); // points survive gates opening through FDV
        // Golden Vault: no more contributions, voluntary burns still earn points
        vm.prank(bob);
        vm.expectRevert(UnlockV2Hook.GoldenVaultOpen.selector);
        token.contribute(10, 1e18);
        burnAs(bob, 1e18);
        assertEq(pot.points(bob), 1e18);
        uint256 aliceBefore = totals(alice);
        fee(1000e18);
        assertApproxEqAbs(totals(alice) - aliceBefore, 5e18, 10);
        assertApproxEqAbs(totals(bob), 5e18, 10);
        // a year later, fees are still shared
        warpTo(t0 + 365 days);
        fee(1000e18);
        assertApproxEqAbs(totals(bob), 10e18, 10);
    }

    // ------------------------------------------------------------------ epochs and claims

    function test_rewardsMatureInClosedEpochsOnly() public {
        burnAs(alice, 1e18);
        fee(1000e18);
        assertEq(pot.currentEpoch(), 0);
        (uint256 c, uint256 m) = pot.rewardsOf(alice);
        assertEq(c, 0);
        assertEq(m, 10e18);
        vm.prank(alice);
        vm.expectRevert(RewardPot.NothingToClaim.selector);
        pot.claim();

        warpTo(t0 + 7 days - 1);
        assertEq(pot.claimable(alice), 0);
        warpTo(t0 + 7 days);
        assertEq(pot.currentEpoch(), 1);
        assertEq(pot.claimable(alice), 10e18);
        fee(500e18); // epoch-1 fee: not claimable until epoch 2
        (c, m) = pot.rewardsOf(alice);
        assertEq(c, 10e18);
        assertEq(m, 5e18);

        vm.prank(alice);
        assertEq(pot.claim(), 10e18);
        assertEq(imd.balanceOf(alice), 10e18);
        // no double claim
        vm.prank(alice);
        vm.expectRevert(RewardPot.NothingToClaim.selector);
        pot.claim();

        warpTo(t0 + 14 days);
        vm.prank(alice);
        assertEq(pot.claim(), 5e18);
    }

    function test_unclaimedRewardsNeverExpire() public {
        burnAs(alice, 1e18);
        fee(1000e18);
        warpTo(t0 + 520 weeks);
        assertEq(pot.claimable(alice), 10e18);
        vm.prank(alice);
        assertEq(pot.claim(), 10e18);
    }

    function test_claimRedeemsPendingClaimsPermissionlessly() public {
        burnAs(alice, 1e18);
        fee(1000e18);
        warpTo(t0 + 7 days);
        assertEq(imd.balanceOf(address(pot)), 0);
        vm.prank(alice);
        assertEq(pot.claim(), 10e18);
        assertEq(hook.pendingFees(), 0);
        assertEq(pot.totalRedeemed(), 10e18);
        assertEq(pot.totalPaid(), 10e18);
        assertTrue(pot.isSolvent());
    }

    function test_onlyBeneficiaryClaims_ownerHasNoAccess() public {
        burnAs(alice, 1e18);
        fee(1000e18);
        warpTo(t0 + 7 days);
        hook.redeemFees();
        // bob and the owner hold no points: nothing for them, alice's entitlement untouched
        vm.prank(bob);
        vm.expectRevert(RewardPot.NothingToClaim.selector);
        pot.claim();
        vm.prank(OWNER);
        vm.expectRevert(RewardPot.NothingToClaim.selector);
        pot.claim();
        assertEq(pot.claimable(alice), 10e18);
        // nobody but the hook reaches the bookkeeping entry points
        vm.startPrank(OWNER);
        vm.expectRevert(RewardPot.NotHook.selector);
        pot.addPoints(OWNER, 1e30);
        vm.expectRevert(RewardPot.NotHook.selector);
        pot.onFeeAccrued(1);
        vm.expectRevert(RewardPot.NotHook.selector);
        pot.onRedeemed(1);
        vm.expectRevert(RewardPot.NotHook.selector);
        pot.activate();
        vm.stopPrank();
        assertEq(imd.balanceOf(address(pot)), 10e18);
    }

    function test_hookCannotOverReportRedemption() public {
        vm.prank(address(hook));
        vm.expectRevert(RewardPot.RedeemExceedsAccrued.selector);
        pot.onRedeemed(1);
    }

    // ------------------------------------------------------------------ contributions

    function test_contribute_burnsAndAwardsPoints_anyOrigin() public {
        // alice's tokens are a plain transfer (uncredited origin): she may still contribute
        uint256 supply = token.totalSupply();
        vm.prank(alice);
        token.contribute(1, 1_000_000.5e18);
        assertEq(token.totalSupply(), supply - 1_000_000.5e18);
        assertEq(pot.points(alice), 1_000_000.5e18); // fractional precision kept
        assertEq(hook.burnProgress(), 1_000_000.5e18);
        assertEq(hook.gateBurned(), 1_000_000.5e18);
        assertEq(hook.totalBurned(), 1_000_000.5e18);
        (uint8 g, uint256 maxAmount) = hook.contributionQuote();
        assertEq(g, 1);
        assertEq(maxAmount, 25_000_000e18 - 1_000_000.5e18);
    }

    function test_contribute_rejectsStaleGateExcessAndZero_withoutBurning() public {
        uint256 bal = token.balanceOf(OWNER);
        vm.startPrank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(UnlockV2Hook.StaleGate.selector, uint8(2), uint8(1)));
        token.contribute(2, 1e18);
        vm.expectRevert(abi.encodeWithSelector(UnlockV2Hook.StaleGate.selector, uint8(0), uint8(1)));
        token.contribute(0, 1e18);
        vm.expectRevert(
            abi.encodeWithSelector(UnlockV2Hook.ExceedsGateRemaining.selector, 25_000_000e18 + 1, 25_000_000e18)
        );
        token.contribute(1, 25_000_000e18 + 1);
        vm.expectRevert(UnlockV2Hook.ZeroAmount.selector);
        token.contribute(1, 0);
        vm.stopPrank();
        assertEq(token.balanceOf(OWNER), bal);
        assertEq(hook.totalBurned(), 0);
        assertEq(pot.totalPoints(), 0);
    }

    function test_contribute_racingContributorIsRejectedNotCarried() public {
        vm.prank(OWNER);
        token.contribute(1, 20_000_000e18);
        // alice quoted 10m earlier; only 5m remains: rejected instead of burning 5m into gate 2
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(UnlockV2Hook.ExceedsGateRemaining.selector, 10_000_000e18, 5_000_000e18));
        token.contribute(1, 10_000_000e18);
        vm.prank(alice);
        token.contribute(1, 5_000_000e18); // exact fill opens gate 1
        assertEq(hook.gatesOpen(), 1);
        assertEq(hook.burnProgress(), 0);
        // the old gate is now stale
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(UnlockV2Hook.StaleGate.selector, uint8(1), uint8(2)));
        token.contribute(1, 1e18);
    }

    function test_contribute_staleAfterGateOpensByFdv_pointsSurvive() public {
        vm.prank(alice);
        token.contribute(1, 5_000_000e18);
        // gates 1-3 open by FDV; the contributed burn is neither refunded nor carried
        feed.set(30_000e8, vm.getBlockTimestamp());
        fee(1e18);
        assertEq(hook.gatesOpen(), 3);
        assertEq(pot.points(alice), 5_000_000e18);
        assertEq(hook.burnProgress(), 0);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(UnlockV2Hook.StaleGate.selector, uint8(1), uint8(4)));
        token.contribute(1, 1e18);
        vm.prank(alice);
        token.contribute(4, 1e18);
        assertEq(hook.burnProgress(), 1e18);
    }

    function test_voluntaryBurnEarnsPointsButNoGateProgress() public {
        burnAs(OWNER, 30_000_000e18);
        assertEq(pot.points(OWNER), 30_000_000e18);
        assertEq(hook.totalBurned(), 30_000_000e18);
        assertEq(hook.gateBurned(), 0);
        assertEq(hook.gatesOpen(), 0);
    }

    function test_contribute_requiresBoundHook() public {
        UnlockV2Token unbound = new UnlockV2Token();
        vm.expectRevert(UnlockV2Token.HookNotRegistered.selector);
        unbound.contribute(1, 1e18);
    }

    function test_onContribute_onlyToken() public {
        vm.expectRevert(UnlockV2Hook.NotToken.selector);
        hook.onContribute(alice, 1, 1e18);
    }

    function test_claimBeforeActivationReverts() public {
        // fresh deployment, not activated
        BaseTest.setUp();
        vm.expectRevert(RewardPot.NotActive.selector);
        vm.prank(alice);
        pot.claim();
        assertEq(pot.currentEpoch(), 0);
        assertFalse(pot.isActive());
    }

    // ------------------------------------------------------------------ fee bases

    /// @dev A hookless twin pool with identical price and liquidity shows the bases: the reward fee is
    ///      taken from the IMD leg, the 1.25% LP fee from what is then swapped. They do not add to 2.25%.
    function test_feeBases_twinPoolComparison() public {
        PoolKey memory twin = key;
        twin.hooks = IHooks(address(0));
        manager.initialize(twin, TickMath.getSqrtPriceAtTick(officialTick()));
        int24 t = officialTick();
        lpRouter.modifyLiquidity(
            twin, ModifyLiquidityParams({tickLower: t - 6000, tickUpper: t + 6000, liquidityDelta: 1e24, salt: 0}), ""
        );
        imd.approve(address(swapRouter), type(uint256).max);
        token.approve(address(swapRouter), type(uint256).max);

        // exact-input buy of X IMD: hook takes floor(X/100) first, the pool swaps (and LP-fees) the rest
        uint256 x = 1_234.567890123456789012e18;
        BalanceDelta dHook = buy(carol, -int256(x));
        uint256 h = hook.hookFee(x);
        BalanceDelta dTwin = _swap(twin, !tokenIs0, -int256(x - h));
        assertEq(abs(tokAmt(dHook)), abs(tokAmt(dTwin)));
        assertEq(hook.pendingFees(), h);
        assertEq(h, x / 100);

        // exact-input sell of T UNLK2: pool output Z (after LP fee on T), trader gets Z - floor(Z/100)
        vm.roll(vm.getBlockNumber() + 1);
        uint256 tIn = abs(tokAmt(dHook)) / 10;
        BalanceDelta sTwin = _swap(twin, tokenIs0, -int256(tIn));
        uint256 z = abs(imdAmt(sTwin));
        uint256 before = imd.balanceOf(carol);
        sell(carol, -int256(tIn));
        assertEq(imd.balanceOf(carol) - before, z - z / 100);

        (uint24 lp, uint24 founderPips, uint24 platformPips, uint256 rewardBps) = hook.feeSchedule();
        assertEq(lp, 12500);
        assertEq(founderPips + platformPips, lp);
        assertEq(rewardBps, 100);
        // rounding is down: below 100 wei of IMD the reward fee is zero
        assertEq(hook.hookFee(99), 0);
        assertEq(hook.hookFee(100), 1);
    }

    function _swap(PoolKey memory k, bool zeroForOne, int256 amountSpecified) internal returns (BalanceDelta) {
        return swapRouter.swap(
            k,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
    }

    // ------------------------------------------------------------------ fuzz: conservation and solvency

    function testFuzz_rewardsConservedAndSolvent(uint256[12] memory ops) public {
        address[3] memory users = [alice, bob, dave];
        uint256 now_ = t0;
        for (uint256 i = 0; i < ops.length; i++) {
            uint256 op = ops[i] % 5;
            address u = users[(ops[i] >> 8) % 3];
            uint256 amt = (ops[i] >> 16) % 1e24;
            if (op == 0) {
                if (amt % 2 == 0) {
                    burnAs(u, amt / 1e6 + 1);
                } else {
                    (uint8 g, uint256 maxAmount) = hook.contributionQuote();
                    if (g != 0 && maxAmount != 0) {
                        uint256 c = amt / 1e6 + 1;
                        if (c > maxAmount) c = maxAmount;
                        vm.prank(u);
                        token.contribute(g, c);
                    }
                }
            } else if (op == 1) {
                fee(amt % 200e18 + 1e6);
            } else if (op == 2) {
                now_ += amt % 10 days;
                warpTo(now_);
            } else if (op == 3) {
                if (pot.claimable(u) != 0) {
                    uint256 b = imd.balanceOf(u);
                    vm.prank(u);
                    uint256 got = pot.claim();
                    assertEq(imd.balanceOf(u) - b, got);
                }
            } else if (hook.pendingFees() != 0) {
                hook.redeemFees();
            }
            assertTrue(pot.isSolvent());
            assertLe(pot.totalPaid(), pot.totalVested());
            assertLe(pot.totalVested(), pot.totalAccrued());
            assertLe(pot.totalRedeemed(), pot.totalAccrued());
            assertEq(pot.totalAccrued() - pot.totalRedeemed(), hook.pendingFees());
            assertGe(imd.balanceOf(address(pot)), pot.totalRedeemed() - pot.totalPaid());
        }
        // everything owed to users never exceeds what was allocated to points, minus rounding dust only
        (, uint256 vested,,,,,) = pot.solvency();
        uint256 owed;
        for (uint256 j = 0; j < 3; j++) {
            owed += totals(users[j]) + pot.accountOf(users[j]).claimed;
        }
        assertLe(owed, vested);
        if (pot.totalPoints() != 0) assertApproxEqAbs(owed, vested, 100);
        // after a full release and an epoch close, everything is claimable and payable
        warpTo(now_ + 15 days);
        for (uint256 j = 0; j < 3; j++) {
            if (pot.claimable(users[j]) != 0) {
                vm.prank(users[j]);
                pot.claim();
            }
            assertEq(totals(users[j]), 0);
        }
        assertTrue(pot.isSolvent());
    }
}
