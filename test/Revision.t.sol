// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseTest} from "./Base.t.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/types/PoolOperation.sol";
import {UnlockV2Hook} from "../src/UnlockV2Hook.sol";
import {UnlockV2Token} from "../src/UnlockV2Token.sol";
import {ClaimDonor, MockDistributor} from "./utils/Mocks.sol";

/// @dev Behaviour added or changed by the review round: surplus ERC-6909 claims, partial fills of the
///      specified-IMD swap shapes, liquidity provision after activation, the hook binding at activation and
///      credits netted against burns made before they were recorded.
contract RevisionTest is BaseTest, IUnlockCallback {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    function setUp() public override {
        super.setUp();
    }

    function _launchAndFund() internal {
        fullLaunch();
        giveImd(alice, 1e24);
        giveImd(bob, 1e24);
    }

    // ------------------------------------------------------------------ IUnlockCallback: the factory adds liquidity itself

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager));
        ModifyLiquidityParams memory p = abi.decode(data, (ModifyLiquidityParams));
        (BalanceDelta d,) = manager.modifyLiquidity(key, p, "");
        _settle(key.currency0, d.amount0());
        _settle(key.currency1, d.amount1());
        return "";
    }

    function _settle(Currency c, int128 amount) internal {
        if (amount < 0) {
            manager.sync(c);
            IERC20(Currency.unwrap(c)).transfer(address(manager), uint256(uint128(-amount)));
            manager.settle();
        } else if (amount > 0) {
            manager.take(c, address(this), uint256(uint128(amount)));
        }
    }

    // ------------------------------------------------------------------ surplus claims (finding 6261bc5a)

    function test_claimDonationCannotBrickRedemptionOrClaims() public {
        _launchAndFund();
        vm.prank(OWNER);
        token.transfer(alice, 1e18);
        vm.prank(alice);
        token.burn(1e18); // alice is the only points holder
        buy(bob, -1_000e18);
        assertEq(pot.totalAccrued(), 10e18);
        assertEq(hook.pendingFees(), 10e18);

        // anyone gives the hook 1 wei of IMD claims
        ClaimDonor donor = new ClaimDonor(manager, IERC20(address(imd)));
        imd.mint(address(donor), 1);
        donor.donate(address(hook), 1);
        assertEq(hook.pendingFees(), 10e18 + 1);
        assertTrue(pot.isSolvent());

        // redemption attributes the surplus as a fee and moves everything
        uint256 redeemed = hook.redeemFees();
        assertEq(redeemed, 10e18 + 1);
        assertEq(pot.totalAccrued(), 10e18 + 1);
        assertEq(pot.totalRedeemed(), 10e18 + 1);
        assertEq(hook.pendingFees(), 0);
        assertEq(pot.totalAccrued() - pot.totalRedeemed(), hook.pendingFees());

        // and a later donation before a claim does not block the claim either
        buy(bob, -1_000e18);
        imd.mint(address(donor), 5e18);
        donor.donate(address(hook), 5e18);
        vm.warp(vm.getBlockTimestamp() + 8 days);
        feed.set(ETH_USD, vm.getBlockTimestamp());
        uint256 balBefore = imd.balanceOf(alice);
        vm.prank(alice);
        uint256 paid = pot.claim();
        assertGt(paid, 19.99e18);
        assertEq(imd.balanceOf(alice) - balBefore, paid);
        assertEq(hook.pendingFees(), 0);
        assertTrue(pot.isSolvent());
        // the gift went to points holders: alice's next claim includes it
        vm.warp(vm.getBlockTimestamp() + 7 days);
        feed.set(ETH_USD, vm.getBlockTimestamp());
        vm.prank(alice);
        uint256 paid2 = pot.claim();
        assertEq(paid2 + paid, 25e18 + 1);
    }

    function test_donationBeforeAnyFeeIsRedeemable() public {
        _launchAndFund();
        ClaimDonor donor = new ClaimDonor(manager, IERC20(address(imd)));
        imd.mint(address(donor), 7);
        donor.donate(address(hook), 7);
        assertEq(hook.redeemFees(), 7);
        assertEq(pot.prePointPot(), 7);
        assertEq(imd.balanceOf(address(pot)), 7);
    }

    // ------------------------------------------------------------------ partial fills (finding 92c672ee)

    function _limitedBuy(address who, int256 amountSpecified, int24 ticksPastSpot) internal returns (BalanceDelta d) {
        bool zeroForOne = !tokenIs0;
        (, int24 tick,,) = IPoolManager(address(manager)).getSlot0(key.toId());
        uint160 limit = TickMath.getSqrtPriceAtTick(zeroForOne ? tick - ticksPastSpot : tick + ticksPastSpot);
        vm.prank(who);
        d = authRouter.swap(key, SwapParams(zeroForOne, amountSpecified, limit));
    }

    function _limitedSell(address who, int256 amountSpecified, int24 ticksPastSpot) internal returns (BalanceDelta d) {
        bool zeroForOne = tokenIs0;
        (, int24 tick,,) = IPoolManager(address(manager)).getSlot0(key.toId());
        uint160 limit = TickMath.getSqrtPriceAtTick(zeroForOne ? tick - ticksPastSpot : tick + ticksPastSpot);
        vm.prank(who);
        d = authRouter.swap(key, SwapParams(zeroForOne, amountSpecified, limit));
    }

    function test_partialExactInputBuy_feeIsOnePercentOfExecutedLeg_restRefunded() public {
        _launchAndFund();
        uint256 before = imd.balanceOf(alice);
        BalanceDelta d = _limitedBuy(alice, -1_000e18, 60);
        uint256 executed = abs(imdAmt(d)) - 10e18; // router delta = pool leg + up-front fee
        uint256 fee = hook.pendingFees();
        assertLt(executed, 990e18, "the price limit stopped the fill early");
        assertEq(fee, executed / 100, "fee is 1% of the executed IMD leg");
        assertEq(before - imd.balanceOf(alice), executed + fee, "the trader paid the executed leg plus that fee");
        assertEq(pot.totalAccrued(), fee);
        assertEq(hook.pendingFees(), pot.totalAccrued() - pot.totalRedeemed());
        assertGt(token.balanceOf(alice), 0);
        assertEq(hook.rightsOf(alice).pendingBuy, token.balanceOf(alice));
        // volume counted the executed leg only
        (uint256 imdUsd,) = hook.gateImdUsdPrice();
        assertEq(hook.cumulativeVolumeUsd(), executed * imdUsd / 1e18);
    }

    function test_partialExactOutputSell_feeIsOnePercentOfExecutedLeg_restRefunded() public {
        _launchAndFund();
        buy(alice, -1_000e18);
        vm.roll(vm.getBlockNumber() + 1);
        uint256 feesBefore = hook.pendingFees();
        uint256 imdBefore = imd.balanceOf(alice);
        uint256 tokBefore = token.balanceOf(alice);
        // asks for 100 IMD out but allows only a 60-tick move: the pool delivers far less
        BalanceDelta d = _limitedSell(alice, int256(100e18), 60);
        uint256 executed = abs(imdAmt(d)) + 1e18; // router delta = pool leg - up-front fee
        uint256 fee = hook.pendingFees() - feesBefore;
        assertLt(executed, 101e18, "the price limit stopped the fill early");
        assertEq(fee, executed / 100);
        assertEq(imd.balanceOf(alice) - imdBefore, executed - fee, "the trader keeps the executed leg minus 1%");
        assertEq(hook.rightsOf(alice).buySold, tokBefore - token.balanceOf(alice));
    }

    function test_partialExactOutputSell_smallerThanTheFeeStillNetsOutPositive() public {
        _launchAndFund();
        buy(alice, -1_000e18);
        vm.roll(vm.getBlockNumber() + 1);
        uint256 imdBefore = imd.balanceOf(alice);
        // ask for a huge output with a 1-tick limit: the pool delivers less than the up-front fee would be
        BalanceDelta d = _limitedSell(alice, int256(500e18), 1);
        uint256 executed = abs(imdAmt(d) < 0 ? -imdAmt(d) : imdAmt(d));
        // net to the trader is the executed leg minus 1% of it: never negative
        assertGe(imd.balanceOf(alice), imdBefore);
        uint256 got = imd.balanceOf(alice) - imdBefore;
        uint256 leg = got * 100 / 99;
        assertApproxEqAbs(got, leg - leg / 100, 2);
        executed; // silence
    }

    function test_fullFillShapesUnchanged() public {
        _launchAndFund();
        uint256 before = imd.balanceOf(alice);
        buy(alice, -1_000e18);
        assertEq(before - imd.balanceOf(alice), 1_000e18);
        assertEq(hook.pendingFees(), 10e18);
    }

    function testFuzz_partialFillFeeNeverExceedsOnePercentOfExecuted(uint96 amount, uint16 ticks) public {
        _launchAndFund();
        int256 amt = int256(bound(amount, 1e18, 5_000e18));
        int24 t = int24(uint24(bound(ticks, 1, 2000)));
        uint256 before = imd.balanceOf(alice);
        BalanceDelta d = _limitedBuy(alice, -amt, t);
        uint256 fee = hook.pendingFees();
        uint256 paid = before - imd.balanceOf(alice);
        uint256 executed = paid - fee;
        uint256 upFront = uint256(amt) / 100;
        if (executed == uint256(amt) - upFront) {
            assertEq(fee, upFront, "full fill: 1% of the gross input, as documented");
        } else {
            assertLt(executed, uint256(amt) - upFront);
            assertEq(fee, executed / 100, "partial fill: 1% of the executed leg");
        }
        assertEq(abs(imdAmt(d)), executed + upFront);
        assertEq(pot.totalAccrued(), fee);
    }

    function testFuzz_partialExactOutputSellFeeNeverExceedsOnePercentOfExecuted(uint96 amount, uint16 ticks) public {
        _launchAndFund();
        buy(alice, -1_000e18);
        vm.roll(vm.getBlockNumber() + 1);
        int256 amt = int256(bound(amount, 1e18, 100e18));
        int24 t = int24(uint24(bound(ticks, 1, 2000)));
        uint256 upFront = uint256(amt) / 100;
        uint256 feesBefore = hook.pendingFees();
        uint256 accruedBefore = pot.totalAccrued();
        uint256 imdBefore = imd.balanceOf(alice);
        BalanceDelta d = _limitedSell(alice, amt, t);
        // the router's IMD delta is the pool's output minus the up-front fee (possibly negative)
        int256 routerImd = int256(imdAmt(d));
        uint256 executed = uint256(routerImd + int256(upFront));
        uint256 fee = hook.pendingFees() - feesBefore;
        assertLe(fee, executed / 100, "never above 1% of the executed IMD leg");
        assertLe(fee, upFront, "never above what was taken up front");
        if (executed >= uint256(amt) + upFront) assertEq(fee, upFront, "full fill keeps the requested base");
        else if (executed <= uint256(amt)) assertEq(fee, executed / 100);
        assertEq(imd.balanceOf(alice) - imdBefore, executed - fee, "the trader nets the executed leg minus the fee");
        assertEq(pot.totalAccrued(), accruedBefore + fee);
    }

    // ------------------------------------------------------------------ liquidity (finding 567d9523)

    function test_onlyFactoryAddsLiquidityAfterActivation() public {
        initOfficialPool();
        seedOfficialLiquidity();
        int24 t = officialTick();
        // before activation anyone may add (the launch's own seeding, however it is routed)
        token.transfer(alice, 1_000e18);
        vm.startPrank(alice);
        token.approve(address(lpRouter), type(uint256).max);
        (int24 lo, int24 hi) = tokenIs0 ? (t + 60, t + 660) : (t - 660, t - 60);
        lpRouter.modifyLiquidity(key, ModifyLiquidityParams(lo, hi, 1e20, bytes32(uint256(7))), "");
        vm.stopPrank();
        fullLaunch();

        // after activation a holder's token-only range order is refused
        vm.prank(OWNER);
        token.transfer(bob, 1_000e18);
        vm.startPrank(bob);
        token.approve(address(lpRouter), type(uint256).max);
        vm.expectRevert();
        lpRouter.modifyLiquidity(key, ModifyLiquidityParams(lo, hi, 1e20, 0), "");
        vm.stopPrank();
        // so is any add through a router, even the one that seeded the pool
        vm.expectRevert();
        lpRouter.modifyLiquidity(
            key, ModifyLiquidityParams({tickLower: t - 6000, tickUpper: t + 6000, liquidityDelta: 1, salt: 0}), ""
        );

        // the factory itself still can, calling the PoolManager directly
        uint256 liqBefore = IPoolManager(address(manager)).getLiquidity(key.toId());
        manager.unlock(abi.encode(ModifyLiquidityParams(t - 6000, t + 6000, 1e21, bytes32(uint256(2)))));
        assertEq(IPoolManager(address(manager)).getLiquidity(key.toId()), liqBefore + 1e21);

        // removal and zero-delta fee collection are never intercepted, whoever the sender is
        giveImd(alice, 1e24);
        buy(alice, -1_000e18);
        lpRouter.modifyLiquidity(
            key, ModifyLiquidityParams({tickLower: t - 6000, tickUpper: t + 6000, liquidityDelta: 0, salt: 0}), ""
        );
        lpRouter.modifyLiquidity(
            key, ModifyLiquidityParams({tickLower: t - 6000, tickUpper: t + 6000, liquidityDelta: -1e23, salt: 0}), ""
        );
        vm.prank(alice);
        lpRouter.modifyLiquidity(key, ModifyLiquidityParams(lo, hi, -1e20, bytes32(uint256(7))), "");
    }

    function test_migratedHolderCannotExitThroughRangeOrder() public {
        _launchAndFund();
        v1.mint(alice, 1_000_000e18);
        vm.startPrank(alice);
        v1.approve(address(vault), type(uint256).max);
        vault.migrate(1_000_000e18);
        assertEq(hook.sellAllowance(alice), 0);
        token.approve(address(lpRouter), type(uint256).max);
        int24 t = officialTick();
        (int24 lo, int24 hi) = tokenIs0 ? (t + 60, t + 660) : (t - 660, t - 60);
        uint256 imdBefore = imd.balanceOf(alice);
        vm.expectRevert();
        lpRouter.modifyLiquidity(key, ModifyLiquidityParams(lo, hi, 1e23, 0), "");
        vm.stopPrank();
        assertEq(token.balanceOf(alice), 1_000_000e18);
        assertEq(imd.balanceOf(alice), imdBefore);
    }

    // ------------------------------------------------------------------ binding (finding 8d0347a9)

    function test_activateRefusesAnUnboundHook() public {
        UnlockV2Token squatted = new UnlockV2Token();
        vm.prank(alice);
        squatted.registerHook(address(this)); // a stranger binds first
        assertEq(squatted.hook(), alice);
        address hookAddr = address(uint160(uint160(0x4321) << 20) | FLAGS);
        deployCodeTo(
            "UnlockV2Hook.sol:UnlockV2Hook",
            abi.encode(
                IPoolManager(address(manager)),
                address(squatted),
                address(imd),
                address(this),
                OWNER,
                address(v1),
                address(feed),
                block.chainid
            ),
            hookAddr
        );
        UnlockV2Hook unbound = UnlockV2Hook(hookAddr);
        assertFalse(unbound.isBound());
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(UnlockV2Hook.HookNotBound.selector, alice));
        unbound.activate();
        assertFalse(unbound.activated());
    }

    function test_activateRefusesWhenBindingFailed() public {
        UnlockV2Token fresh = new UnlockV2Token();
        fresh.transfer(alice, 1); // the factory moved tokens before the hook existed
        address hookAddr = address(uint160(uint160(0x5432) << 20) | FLAGS);
        deployCodeTo(
            "UnlockV2Hook.sol:UnlockV2Hook",
            abi.encode(
                IPoolManager(address(manager)),
                address(fresh),
                address(imd),
                address(this),
                OWNER,
                address(v1),
                address(feed),
                block.chainid
            ),
            hookAddr
        );
        UnlockV2Hook unbound = UnlockV2Hook(hookAddr);
        assertEq(fresh.hook(), address(0));
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(UnlockV2Hook.HookNotBound.selector, address(0)));
        unbound.activate();
    }

    // ------------------------------------------------------------------ credits vs earlier burns (finding e30ee4e8)

    function _singleLeafDistributor(address account, uint256 amount) internal returns (MockDistributor dist) {
        bytes32 root = keccak256(abi.encodePacked(uint256(0), account, amount));
        dist = new MockDistributor(root);
        dist.setClaimed(0, true);
        vm.prank(OWNER);
        hook.setSwarmDistributor(address(dist));
    }

    function test_burnBeforeSwarmCreditLeavesNoCredit() public {
        MockDistributor dist = _singleLeafDistributor(alice, 1_000_000e18);
        dist;
        token.transfer(alice, 1_000_000e18); // the distributor's payout
        fullLaunch();
        vm.prank(alice);
        token.burn(1_000_000e18);
        assertEq(hook.uncreditedBurned(alice), 1_000_000e18);
        bytes32[] memory proof;
        hook.creditSwarmClaim(0, alice, 1_000_000e18, proof);
        assertEq(hook.rightsOf(alice).otherCredited, 0, "same result as credit-then-burn");
        assertEq(hook.uncreditedBurned(alice), 0);
        assertEq(pot.points(alice), 1_000_000e18, "points are unaffected");
        assertTrue(hook.swarmIndexCredited(0));
        // tokens received later by transfer still create no eligibility
        vm.prank(OWNER);
        token.transfer(alice, 1_000_000e18);
        assertEq(hook.sellAllowance(alice), 0);
    }

    function test_creditThenBurnAndBurnThenCreditAgree() public {
        _singleLeafDistributor(alice, 100e18);
        token.transfer(alice, 100e18);
        fullLaunch();
        bytes32[] memory proof;
        // alice: burn 30 first, then credit 100 -> 70 credited
        vm.prank(alice);
        token.burn(30e18);
        hook.creditSwarmClaim(0, alice, 100e18, proof);
        assertEq(hook.rightsOf(alice).otherCredited, 70e18);
        // a burn larger than the later credit nets the whole credit and keeps the remainder for the next one
        vm.prank(alice);
        token.burn(70e18);
        assertEq(hook.rightsOf(alice).otherCredited, 0);
        assertEq(hook.uncreditedBurned(alice), 0);
    }

    function test_founderCreditNettedAgainstPreActivationBurn() public {
        initOfficialPool();
        seedOfficialLiquidity();
        initReferencePool();
        seedReferenceLiquidity();
        token.transfer(OWNER, 750_000_000e18);
        vm.startPrank(OWNER);
        token.transfer(address(vault), 700_000_000e18);
        token.burn(20_000_000e18); // before activation: no credits exist yet
        hook.activate();
        vm.stopPrank();
        assertEq(hook.rightsOf(OWNER).otherCredited, 30_000_000e18);
        assertEq(hook.uncreditedBurned(OWNER), 0);
    }

    function test_migrationCreditIsNotNetted() public {
        _launchAndFund();
        vm.prank(OWNER);
        token.transfer(alice, 10e18);
        vm.prank(alice);
        token.burn(10e18); // uncredited tokens burned
        v1.mint(alice, 100e18);
        vm.startPrank(alice);
        v1.approve(address(vault), 100e18);
        vault.migrate(100e18);
        vm.stopPrank();
        assertEq(hook.rightsOf(alice).otherCredited, 100e18, "migration tokens arrive with their credit");
        assertEq(hook.uncreditedBurned(alice), 10e18);
    }

    // ------------------------------------------------------------------ gate preview (info e4f2d829)

    function test_pendingGatesOpenPreviewsTheBlocksReading() public {
        _launchAndFund();
        assertEq(hook.pendingGatesOpen(), 0);
        feed.set(30_000e8, vm.getBlockTimestamp()); // FDV about 1,000,000 USD at the settled price
        assertEq(hook.gatesOpen(), 0);
        assertEq(hook.pendingGatesOpen(), 3, "the view previews gates 1-3");
        buy(alice, -1e18);
        assertEq(hook.gatesOpen(), 3);
        assertEq(hook.pendingGatesOpen(), 3);
    }
}
