// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseTest} from "./Base.t.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {UnlockV2Hook} from "../src/UnlockV2Hook.sol";

contract TradingTest is BaseTest {
    function setUp() public override {
        super.setUp();
        fullLaunch();
        giveImd(alice, 1e24);
        giveImd(bob, 1e24);
    }

    // ------------------------------------------------------------------ hook fee (kept as IMD)

    function test_buyExactInput_takes1PercentOfImdInput() public {
        uint256 imdBefore = imd.balanceOf(alice);
        BalanceDelta d = buy(alice, -1000e18);
        assertEq(imd.balanceOf(alice), imdBefore - 1000e18);
        // the pool executed 990 IMD, the hook holds 10 IMD as a claim
        assertEq(abs(imdAmt(d)), 1000e18);
        assertEq(hook.pendingFees(), 10e18);
        assertGt(abs(tokAmt(d)), 0);
        assertEq(token.balanceOf(alice), abs(tokAmt(d)));
    }

    function test_buyExactOutput_takes1PercentOfImdInput() public {
        uint256 imdBefore = imd.balanceOf(alice);
        BalanceDelta d = buy(alice, int256(1_000_000e18));
        assertEq(token.balanceOf(alice), 1_000_000e18);
        uint256 paid = imdBefore - imd.balanceOf(alice);
        uint256 fee = hook.pendingFees();
        // fee is 1% of the pool's IMD leg; user paid pool leg + fee
        assertEq(paid, abs(imdAmt(d)));
        assertEq(fee, (paid - fee) / 100);
    }

    function test_sellExactInput_takes1PercentOfImdOutput() public {
        buy(alice, -1000e18);
        vm.roll(vm.getBlockNumber() + 1);
        uint256 bought = token.balanceOf(alice);
        uint256 feesBefore = hook.pendingFees();
        uint256 imdBefore = imd.balanceOf(alice);
        BalanceDelta d = sell(alice, -int256(bought / 5));
        uint256 received = imd.balanceOf(alice) - imdBefore;
        uint256 fee = hook.pendingFees() - feesBefore;
        uint256 poolLeg = received + fee;
        assertEq(fee, poolLeg / 100);
        assertEq(abs(imdAmt(d)), received);
    }

    function test_sellExactOutput_takes1PercentOfImdOutput() public {
        buy(alice, -1000e18);
        vm.roll(vm.getBlockNumber() + 1);
        uint256 feesBefore = hook.pendingFees();
        uint256 imdBefore = imd.balanceOf(alice);
        sell(alice, int256(10e18));
        assertEq(imd.balanceOf(alice) - imdBefore, 10e18);
        assertEq(hook.pendingFees() - feesBefore, 0.1e18);
    }

    function test_redeemFees_movesImdToPotAndStreams() public {
        buy(alice, -1000e18);
        assertEq(hook.pendingFees(), 10e18);
        vm.prank(bob);
        uint256 redeemed = hook.redeemFees();
        assertEq(redeemed, 10e18);
        assertEq(hook.pendingFees(), 0);
        assertEq(imd.balanceOf(address(pot)), 10e18);
        assertEq(pot.streamTotal(), 10e18);
        assertEq(pot.streamEnd(), vm.getBlockTimestamp() + 7 days);
        vm.expectRevert(UnlockV2Hook.NothingToRedeem.selector);
        hook.redeemFees();
    }

    function test_unlockCallback_rejectsOutsideRedeem() public {
        vm.prank(address(manager));
        vm.expectRevert(UnlockV2Hook.NotRedeeming.selector);
        hook.unlockCallback(abi.encode(uint256(1)));
    }

    // ------------------------------------------------------------------ sell rights

    function test_buyCreditMaturesAfterOneBlock() public {
        buy(alice, -1000e18);
        uint256 bought = token.balanceOf(alice);
        UnlockV2Hook.Rights memory r = hook.rightsOf(alice);
        assertEq(r.pendingBuy, bought);
        assertEq(hook.sellAllowance(alice), 0);
        vm.expectRevert();
        sell(alice, -1e18);
        vm.roll(vm.getBlockNumber() + 1);
        assertEq(hook.sellAllowance(alice), bought * 20 / 100);
        r = hook.rightsOf(alice);
        assertEq(r.buyCredited, bought);
        assertEq(r.pendingBuy, 0);
    }

    function test_preGate1_20PercentCumulativeAllowance() public {
        buy(alice, -1000e18);
        vm.roll(vm.getBlockNumber() + 1);
        uint256 bought = token.balanceOf(alice);
        uint256 allowance = bought * 20 / 100;
        sell(alice, -int256(allowance / 2));
        assertEq(hook.sellAllowance(alice), allowance - allowance / 2);
        // one more than remaining fails
        vm.expectRevert();
        sell(alice, -int256(allowance - allowance / 2 + 1));
        sell(alice, -int256(allowance - allowance / 2));
        assertEq(hook.sellAllowance(alice), 0);
        vm.expectRevert();
        sell(alice, -1);
    }

    function test_transferDoesNotGrantRights() public {
        buy(alice, -1000e18);
        vm.roll(vm.getBlockNumber() + 1);
        uint256 bought = token.balanceOf(alice);
        vm.prank(alice);
        token.transfer(bob, bought);
        assertEq(hook.sellAllowance(bob), 0);
        vm.expectRevert();
        sell(bob, -1e18);
        // alice keeps her rights even without balance (she cannot use them without tokens)
        assertEq(hook.sellAllowance(alice), bought * 20 / 100);
    }

    function test_migratedTokensHaveZeroAllowanceBeforeGate1() public {
        v1.mint(alice, 1000e18);
        vm.startPrank(alice);
        v1.approve(address(vault), 1000e18);
        vault.migrate(1000e18);
        vm.stopPrank();
        assertEq(token.balanceOf(alice), 1000e18);
        UnlockV2Hook.Rights memory r = hook.rightsOf(alice);
        assertEq(r.otherCredited, 1000e18);
        assertEq(hook.sellAllowance(alice), 0);
        vm.expectRevert();
        sell(alice, -1e18);
    }

    function test_authenticatedRouterCreditsRealTrader() public {
        buy(alice, -1000e18);
        vm.roll(vm.getBlockNumber() + 1);
        uint256 bought = token.balanceOf(alice);
        assertEq(hook.sellAllowance(alice), bought * 20 / 100);
        assertEq(hook.sellAllowance(address(authRouter)), 0);
        sell(alice, -int256(bought / 10));
        assertEq(hook.sellAllowance(alice), bought * 20 / 100 - bought / 10);
    }

    function test_unregisteredRouterIsOneSharedAccount() public {
        // PoolSwapTest is not registered: every user of it shares the router's bucket.
        buyShared(alice, -1000e18);
        buyShared(bob, -1000e18);
        vm.roll(vm.getBlockNumber() + 1);
        uint256 routerCredit = hook.rightsOf(address(swapRouter)).buyCredited;
        assertEq(routerCredit, token.balanceOf(alice) + token.balanceOf(bob));
        assertEq(hook.sellAllowance(alice), 0);
        // bob can consume the shared allowance that alice's buy created
        uint256 shared = hook.sellAllowance(address(swapRouter));
        sellShared(bob, -int256(shared));
        assertEq(hook.sellAllowance(address(swapRouter)), 0);
        vm.expectRevert();
        sellShared(alice, -1e18);
        // and alice cannot use her own account either: the router, not she, was credited
        vm.expectRevert();
        sell(alice, -1e18);
    }

    // ------------------------------------------------------------------ gates

    function test_gatesOpenByFdvAcrossMultipleThresholds() public {
        assertEq(hook.gatesOpen(), 0);
        // ETH -> 30,000 USD makes IMD ~10 USD and FDV ~1,000,000 USD: gates 1-3 open on the next observation
        feed.set(30_000e8, vm.getBlockTimestamp());
        buy(alice, -1e18);
        assertEq(hook.gatesOpen(), 3);
        (uint256 b, uint256 o) = hook.unlockedPercents();
        assertEq(b, 35);
        assertEq(o, 35);
        // falling prices never relock
        feed.set(ETH_USD, vm.getBlockTimestamp());
        buy(alice, -1e18);
        assertEq(hook.gatesOpen(), 3);
        // migrated tokens now sell at the global percentage
        v1.mint(bob, 1000e18);
        vm.startPrank(bob);
        v1.approve(address(vault), 1000e18);
        vault.migrate(1000e18);
        vm.stopPrank();
        assertEq(hook.sellAllowance(bob), 350e18);
        sell(bob, -350e18);
        vm.expectRevert();
        sell(bob, -1);
    }

    function test_invalidPriceSkipsProgressButTradingContinues() public {
        feed.set(30_000e8, vm.getBlockTimestamp() - 2 hours); // stale
        BalanceDelta d = buy(alice, -1000e18);
        assertGt(abs(tokAmt(d)), 0);
        assertEq(hook.cumulativeVolumeUsd(), 0);
        assertEq(hook.gatesOpen(), 0);
        assertEq(hook.lastValidObservation(), 0);
        // the fee is still taken and the buy credited
        assertEq(hook.pendingFees(), 10e18);
        vm.roll(vm.getBlockNumber() + 1);
        assertGt(hook.sellAllowance(alice), 0);
    }

    function test_volumeCountsExecutedImdLegOnce() public {
        (uint256 imdUsd,) = hook.imdUsdPrice();
        BalanceDelta d = buy(alice, -1000e18);
        // pool leg is 990 IMD (1000 minus the 1% hook fee)
        uint256 leg = abs(imdAmt(d)) - 10e18;
        assertEq(leg, 990e18);
        assertEq(hook.cumulativeVolumeUsd(), leg * imdUsd / 1e18);
        uint256 v1Snap = hook.cumulativeVolumeUsd();
        vm.roll(vm.getBlockNumber() + 1);
        sell(alice, -int256(token.balanceOf(alice) / 10));
        assertGt(hook.cumulativeVolumeUsd(), v1Snap);
    }

    function test_gateOpensByBurnAndGate10BypassesQuotas() public {
        // gate 1 by burn: 25m from the owner's remainder
        vm.prank(OWNER);
        token.burn(25_000_000e18);
        assertEq(hook.gatesOpen(), 1);
        assertEq(hook.burnProgress(), 0);
        // burn the rest of the targets: 22+19+16+13+10+8+6+4+2 = 100m (from the swarm stand-in balance)
        token.transfer(alice, 100_000_000e18);
        vm.prank(alice);
        token.burn(100_000_000e18);
        assertEq(hook.gatesOpen(), 10);
        assertEq(hook.sellAllowance(alice), type(uint256).max);
        // uncredited tokens (plain transfer) sell freely
        vm.prank(OWNER);
        token.transfer(bob, 1_000_000e18);
        sell(bob, -1_000_000e18);
        assertEq(token.balanceOf(bob), 0);
    }

    // ------------------------------------------------------------------ burns

    function test_burnDebitsCreditsConservatively() public {
        buy(alice, -1000e18);
        vm.roll(vm.getBlockNumber() + 1);
        uint256 bought = token.balanceOf(alice);
        // sell 10% first
        sell(alice, -int256(bought / 10));
        uint256 held = bought - bought / 10;
        // also give alice uncredited tokens
        vm.prank(OWNER);
        token.transfer(alice, 500e18);
        // burn 500 + half of the credited holding: debits credited first
        uint256 burnAmt = 500e18 + held / 2;
        (uint256 fp, uint256 fb, uint256 fo, uint256 unc, uint256 after_) = hook.previewBurn(alice, burnAmt);
        assertEq(fp, 0);
        assertEq(fb, burnAmt < held ? burnAmt : held);
        assertEq(fo, 0);
        assertEq(unc, burnAmt - fb);
        vm.prank(alice);
        token.burn(burnAmt);
        UnlockV2Hook.Rights memory r = hook.rightsOf(alice);
        assertEq(r.buyCredited, bought - fb);
        assertEq(r.buySold, bought / 10); // sales never reset
        assertEq(hook.sellAllowance(alice), after_);
        uint256 cap = uint256(r.buyCredited) * 20 / 100;
        assertEq(after_, cap > r.buySold ? cap - r.buySold : 0);
        assertEq(pot.points(alice), burnAmt);
    }

    function test_burnMixedOriginsOrderPendingBuyOther() public {
        v1.mint(alice, 100e18);
        vm.startPrank(alice);
        v1.approve(address(vault), 100e18);
        vault.migrate(100e18);
        vm.stopPrank();
        buy(alice, -10e18); // pending in this block
        UnlockV2Hook.Rights memory r = hook.rightsOf(alice);
        uint256 pending = r.pendingBuy;
        (uint256 fp, uint256 fb, uint256 fo,,) = hook.previewBurn(alice, pending + 40e18);
        assertEq(fp, pending);
        assertEq(fb, 0);
        assertEq(fo, 40e18);
        vm.prank(alice);
        token.burn(pending + 40e18);
        r = hook.rightsOf(alice);
        assertEq(r.pendingBuy, 0);
        assertEq(r.otherCredited, 60e18);
    }

    // ------------------------------------------------------------------ fuzz

    function testFuzz_sellNeverExceedsAllowance(uint96 buyAmt, uint96 sellFrac) public {
        buyAmt = uint96(bound(buyAmt, 1e18, 2e20));
        buy(alice, -int256(uint256(buyAmt)));
        vm.roll(vm.getBlockNumber() + 1);
        uint256 allowance = hook.sellAllowance(alice);
        uint256 amount = bound(sellFrac, 1, allowance * 2);
        if (amount > allowance) {
            vm.expectRevert();
            sell(alice, -int256(amount));
        } else {
            sell(alice, -int256(amount));
            assertEq(hook.sellAllowance(alice), allowance - amount);
        }
    }
}
