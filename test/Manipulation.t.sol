// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {SwapParams, ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolIdLibrary, PoolId} from "v4-core/types/PoolId.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";

import {BaseTest} from "./Base.t.sol";

/// @notice FDV gates read only a price that survived a block boundary; the reference pool can move the
///         IMD valuation only at the tracker's rate.
contract ManipulationTest is BaseTest {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    uint256 internal constant VOLUME_GATE_1 = 125_000e18;
    int256 internal constant SPIKE = -5300e18;

    function setUp() public override {
        super.setUp();
        // wide official liquidity, added while trading is still closed: a large buy reaches the gate 10 FDV
        // while staying in range
        initOfficialPool();
        seedOfficialLiquidity();
        int24 t = officialTick();
        lpRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: tokenIs0 ? t - 600 : t - 60000,
                tickUpper: tokenIs0 ? t + 60000 : t + 600,
                liquidityDelta: 1e22,
                salt: bytes32(uint256(1))
            }),
            ""
        );
        fullLaunch();
        giveImd(alice, 1e24);
        giveImd(bob, 1e24);
        giveImd(address(this), 1e24);
        // deep, wide reference liquidity so the pool price can move far without leaving the range
        lpRouter.modifyLiquidity{value: 500 ether}(
            refKey,
            ModifyLiquidityParams({
                tickLower: REF_TICK - 40000,
                tickUpper: REF_TICK + 40000,
                liquidityDelta: 1e21,
                salt: bytes32(uint256(1))
            }),
            ""
        );
    }

    function _nextBlock(uint256 secs) internal {
        vm.roll(block.number + 1);
        vm.warp(vm.getBlockTimestamp() + secs);
        feed.set(ETH_USD, vm.getBlockTimestamp());
    }

    /// @dev Moves the reference pool to `tick`; a lower tick is fewer IMD per ETH, so a dearer IMD.
    function _moveReferenceTo(int24 tick) internal {
        (uint160 current,,,) = IPoolManager(address(manager)).getSlot0(refKey.toId());
        uint160 target = TickMath.getSqrtPriceAtTick(tick);
        if (target == current) return;
        bool zeroForOne = target < current;
        uint256 value = zeroForOne ? 400 ether : 0;
        swapRouter.swap{value: value}(
            refKey,
            SwapParams({zeroForOne: zeroForOne, amountSpecified: -int256(1e27), sqrtPriceLimitX96: target}),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
    }

    // ------------------------------------------------------------------ official pool

    function test_spikeInsideOneBlockOpensNoGate() public {
        (uint256 spotBefore,) = hook.tokenPriceInImd();
        buy(bob, SPIKE);
        (uint256 spotAfter,) = hook.tokenPriceInImd();
        assertGt(spotAfter, spotBefore, "buy moved the price");
        (uint256 spotFdv,) = hook.fdvUsd();
        assertGe(spotFdv, 25_000_000e18, "spot FDV is above the gate 10 threshold");

        assertEq(hook.gatesOpen(), 0, "the spike itself opens nothing");
        assertLt(hook.cumulativeVolumeUsd(), VOLUME_GATE_1);

        // further swaps in the same block read nothing new either
        buy(alice, -1e18);
        assertEq(hook.gatesOpen(), 0);
        assertEq(hook.sellAllowance(OWNER), 0);
    }

    function test_buyerCannotSellBackInTheSameBlock() public {
        buy(bob, SPIKE);
        uint256 bal = token.balanceOf(bob);
        vm.expectRevert();
        sell(bob, -int256(bal));
        assertEq(hook.gatesOpen(), 0);
    }

    function test_spikeUndoneBeforeBlockEndsLeavesGatesClosed() public {
        // bob holds matured buy credits, so part of a spike can really be sold back in the same block
        buy(bob, -2000e18);
        _nextBlock(12);
        buy(alice, -1e18); // this block's reading happens here
        assertEq(hook.lastFdvBlock(), block.number);
        uint8 gatesThen = hook.gatesOpen();

        buy(alice, SPIKE);
        sell(bob, -int256(hook.sellAllowance(bob)));
        assertEq(hook.gatesOpen(), gatesThen, "same-block activity reads no new FDV");
    }

    function test_priceHeldAcrossABlockOpensGatesFromOneObservation() public {
        buy(bob, SPIKE);
        assertEq(hook.gatesOpen(), 0);
        _nextBlock(12);
        // any swap of the next block reads the price the previous block left: several gates at once
        buy(alice, -1e18);
        assertEq(hook.gatesOpen(), 10);
        assertEq(hook.sellAllowance(OWNER), type(uint256).max);
        // and gates stay open after the price falls back
        sell(bob, -int256(token.balanceOf(bob)));
        _nextBlock(12);
        buy(alice, -1e18);
        assertEq(hook.gatesOpen(), 10);
    }

    function test_firstSwapOfBlockSeesGateBeforeItsOwnQuotaCheck() public {
        // a sell that is the block's first swap is judged with the gates the settled price opens
        vm.prank(OWNER);
        token.transfer(bob, 1000e18);
        buy(alice, SPIKE);
        _nextBlock(12);
        sell(bob, -1000e18);
        assertEq(hook.gatesOpen(), 10);
    }

    function test_feedOutageDelaysTheReadingToTheNextValidBlock() public {
        buy(alice, SPIKE);
        _nextBlock(12);
        feed.set(ETH_USD, vm.getBlockTimestamp() - 2 hours);
        buy(bob, -1e18);
        assertEq(hook.gatesOpen(), 0, "invalid price reads nothing");
        assertEq(hook.lastFdvBlock(), block.number);
        _nextBlock(12);
        buy(bob, -1e18);
        assertEq(hook.gatesOpen(), 10, "the next valid block reads the held price");
    }

    function testFuzz_oneBlockNeverOpensAnFdvGate(uint96 first, uint96 second) public {
        uint256 a = bound(first, 1e18, 4000e18);
        uint256 b = bound(second, 1e18, 4000e18);
        buy(alice, -int256(a));
        buy(bob, -int256(b));
        // only the volume path may open a gate in the block of the swaps themselves
        if (hook.cumulativeVolumeUsd() < VOLUME_GATE_1) assertEq(hook.gatesOpen(), 0);
    }

    // ------------------------------------------------------------------ reference pool

    function test_referenceSpikeDoesNotInflateVolumeOrFdv() public {
        _nextBlock(12);
        (uint256 imdUsdBefore,) = hook.imdUsdPrice();
        // 30000 ticks down is about twenty times fewer IMD per ETH
        _moveReferenceTo(REF_TICK - 30000);
        (uint256 imdUsdSpike, bool ok) = hook.imdUsdPrice();
        assertTrue(ok);
        assertGt(imdUsdSpike, imdUsdBefore * 15, "spot IMD/USD is up about 20x");

        (uint256 gateUsd,) = hook.gateImdUsdPrice();
        assertLe(gateUsd, imdUsdBefore * 101 / 100, "12 seconds of tracker movement is tiny");

        uint256 volumeBefore = hook.cumulativeVolumeUsd();
        buy(alice, -1000e18);
        uint256 added = hook.cumulativeVolumeUsd() - volumeBefore;
        // 990 IMD enters the pool (after the 1% reward fee), valued near the pre-spike price, not 20x
        assertLe(added, 990e18 * imdUsdBefore / 1e18 * 101 / 100);
        assertEq(hook.gatesOpen(), 0, "valuation stayed near the pre-spike level");
        _moveReferenceTo(REF_TICK);
    }

    function test_quietPoolCapsOneReadingAtTwentyPercent() public {
        _nextBlock(30 days);
        (uint256 imdUsdBefore,) = hook.imdUsdPrice();
        _moveReferenceTo(REF_TICK - 30000);
        (uint256 gateUsd,) = hook.gateImdUsdPrice();
        assertLe(gateUsd, imdUsdBefore * 121 / 100);
        assertGe(gateUsd, imdUsdBefore * 119 / 100);
    }

    function test_realImdRiseIsFollowedAtTheTrackerRate() public {
        (uint256 imdUsdBefore,) = hook.imdUsdPrice();
        _moveReferenceTo(REF_TICK - 7000); // IMD about doubles and stays there
        uint256 last = imdUsdBefore;
        for (uint256 i; i < 24; i++) {
            _nextBlock(1 hours);
            buy(alice, -1e18);
            (uint256 p,) = hook.gateImdUsdPrice();
            assertGe(p, last, "tracker keeps rising toward a held price");
            last = p;
        }
        assertGt(last, imdUsdBefore * 19 / 10, "reached the new price within a day");
        (uint256 spot,) = hook.imdUsdPrice();
        assertLe(last, spot);
    }

    function test_trackerFollowsAtTheSameRateWithASwapEveryBlock() public {
        uint256 seed = hook.trackedImdPerEth();
        _moveReferenceTo(REF_TICK - 800); // IMD about 8% dearer: the tracker must fall toward spot
        for (uint256 i; i < 300; i++) {
            _nextBlock(12);
            buy(alice, -1e18);
        }
        // one hour of 12-second updates, each bounded relative to the previous value: 5% compounded over
        // 300 steps is (1 + 1/6000)^300, about 5.13%, not the 3% that whole-basis-point rounding gave
        uint256 tracked = hook.trackedImdPerEth();
        assertLe(tracked, seed * 10_000 / 10_500, "at least the 5% an hourly update allows");
        assertGe(tracked, seed * 10_000 / 10_520, "no faster than the compounded bound");
    }

    function test_imdFallCountsImmediately() public {
        _nextBlock(12);
        _moveReferenceTo(REF_TICK + 7000); // IMD about halves
        (uint256 spot,) = hook.imdUsdPrice();
        (uint256 gateUsd,) = hook.gateImdUsdPrice();
        assertEq(gateUsd, spot, "a lower IMD price is used at once, never overstated");
    }

    function testFuzz_gatePriceNeverExceedsSpot(int24 tickOffset, uint32 gap) public {
        int24 off = int24(bound(tickOffset, -30000, 30000));
        _nextBlock(bound(gap, 1, 40 days));
        _moveReferenceTo(REF_TICK + off);
        (uint256 spot, bool a) = hook.imdUsdPrice();
        (uint256 gateUsd, bool b) = hook.gateImdUsdPrice();
        assertEq(a, b);
        if (a) assertLe(gateUsd, spot);
    }

    function test_invalidFeedLeavesVolumeUntouchedAndTradingOpen() public {
        vm.warp(vm.getBlockTimestamp() + 91 minutes);
        vm.roll(block.number + 1);
        (, bool valid) = hook.gateImdUsdPrice();
        assertFalse(valid);
        buy(alice, -100e18);
        assertEq(hook.cumulativeVolumeUsd(), 0);
    }

    // ------------------------------------------------------------------ per-account credits (documented)

    function test_creditedAccountCanSellTokensReceivedFromOthers() public {
        buy(alice, -1000e18);
        _nextBlock(12);
        uint256 allowance = hook.sellAllowance(alice);
        assertGt(allowance, 0);
        // credits are counters on the account, not marks on tokens: alice's stay after she sends hers away
        vm.startPrank(alice);
        token.transfer(bob, token.balanceOf(alice));
        vm.stopPrank();
        assertEq(hook.sellAllowance(alice), allowance);
        assertEq(hook.sellAllowance(bob), 0, "the receiver gets no eligibility");
        vm.prank(OWNER);
        token.transfer(alice, allowance);
        sell(alice, -int256(allowance));
        assertEq(hook.sellAllowance(alice), 0, "total selling stays bounded by the credits");
    }
}
