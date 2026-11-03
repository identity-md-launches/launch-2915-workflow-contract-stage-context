// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {BaseTest} from "./Base.t.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {SwapParams} from "v4-core/types/PoolOperation.sol";
import {Pool} from "v4-core/libraries/Pool.sol";
import {UnlockV2Token} from "../src/UnlockV2Token.sol";
import {UnlockV2Hook} from "../src/UnlockV2Hook.sol";
import {MigrationVault} from "../src/MigrationVault.sol";
import {RewardPot} from "../src/RewardPot.sol";
import {MockERC20, MockFeed, AuthRouter} from "./utils/Mocks.sol";

/// @dev Random sequences of buys, sells, burns, gate contributions, migrations, transfers, time jumps,
///      redemptions and claims by three actors on the activated launch (MOCK environment).
contract LaunchHandler is Test {
    UnlockV2Token internal token;
    UnlockV2Hook internal hook;
    MigrationVault internal vault;
    RewardPot internal pot;
    MockERC20 internal imd;
    MockERC20 internal v1;
    MockFeed internal feed;
    AuthRouter internal router;
    PoolKey internal key;
    bool internal tokenIs0;

    address[3] internal actors;

    // ghosts
    mapping(address => uint256) public ghostSoldBeforeGolden;
    mapping(address => uint256) public ghostClaimed;
    uint256 public ghostMigrated;
    uint8 public ghostMaxGates;
    uint256 public ghostMaxVolume;
    bool public ghostRegression;
    bool public ghostUnexpectedRevert;
    bool public ghostSpikeOpenedGate;
    bool public ghostGatePriceAboveSpot;
    /// @dev pendingGatesOpen() disagreed with the gates the block's first swap actually opened by FDV.
    bool public ghostPreviewMismatch;
    uint256 public previewChecks;
    uint256 public calls;
    bytes4 internal lastSwapError;

    constructor(
        UnlockV2Token token_,
        UnlockV2Hook hook_,
        MockERC20 imd_,
        MockERC20 v1_,
        MockFeed feed_,
        AuthRouter router_,
        PoolKey memory key_,
        address[3] memory actors_
    ) {
        token = token_;
        hook = hook_;
        vault = hook_.migrationVault();
        pot = hook_.rewardPot();
        imd = imd_;
        v1 = v1_;
        feed = feed_;
        router = router_;
        key = key_;
        tokenIs0 = address(token_) < address(imd_);
        actors = actors_;
    }

    function actorAt(uint256 i) external view returns (address) {
        return actors[i];
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % 3];
    }

    function _track() internal {
        calls++;
        if (hook.gatesOpen() < ghostMaxGates) ghostRegression = true;
        if (hook.cumulativeVolumeUsd() < ghostMaxVolume) ghostRegression = true;
        ghostMaxGates = hook.gatesOpen();
        ghostMaxVolume = hook.cumulativeVolumeUsd();
        (uint256 spot, bool sv) = hook.imdUsdPrice();
        (uint256 gp, bool gv) = hook.gateImdUsdPrice();
        if (sv && gv && gp > spot) ghostGatePriceAboveSpot = true;
    }

    function _swap(address who, bool isBuy, int256 amountSpecified) internal returns (bool ok) {
        bool zeroForOne = isBuy ? !tokenIs0 : tokenIs0;
        lastSwapError = bytes4(0);
        // the block's first official swap takes the settled FDV reading; pendingGatesOpen() must preview it
        bool readingPending = hook.lastFdvBlock() != block.number;
        uint8 preview = hook.pendingGatesOpen();
        // the preview keeps the current burn progress for every later gate instead of restarting it at
        // zero (reported in .imd-findings.json); below the smallest burn target that cannot matter
        bool progressBelowEveryTarget = hook.burnProgress() < 2_000_000e18;
        vm.prank(who);
        try router.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            })
        ) {
            ok = true;
            if (readingPending && progressBelowEveryTarget) _checkPreview(preview);
        } catch (bytes memory err) {
            ok = false;
            if (err.length >= 4) lastSwapError = bytes4(err);
        }
    }

    /// @dev After the block's first swap: the reading opened exactly `preview` gates; any beyond it were
    ///      opened by the swap's own volume (afterSwap), which needs the volume threshold of gate preview+1.
    function _checkPreview(uint8 preview) internal {
        previewChecks++;
        uint8 g = hook.gatesOpen();
        if (g < preview) {
            ghostPreviewMismatch = true;
        } else if (g > preview) {
            (,, uint256 volT,) = hook.gate(preview + 1);
            if (hook.cumulativeVolumeUsd() < volT) ghostPreviewMismatch = true;
        }
    }

    function buy(uint256 who, uint256 imdIn) external {
        imdIn = bound(imdIn, 1e15, 300e18);
        _swap(_actor(who), true, -int256(imdIn));
        _track();
    }

    /// @dev Same-block price spike and sell-back attempt: whatever the spike does to the spot FDV, it must
    ///      not open an FDV gate within its own block (only volume or burns may).
    function spikeAndSellBack(uint256 who, uint256 imdIn) external {
        // a spike left in place opens gates at the next block (disclosed); keep it rare so the
        // pre-gate-10 properties still get coverage
        if (hook.gatesOpen() >= 10 || imdIn % 4 != 0) return;
        address a = _actor(who);
        _swap(a, true, -1e15); // this block's settled FDV reading happens here (or already happened)
        uint8 g = hook.gatesOpen();
        if (g >= 10) {
            _track();
            return;
        }
        uint256 bal = token.balanceOf(a);
        _swap(a, true, -int256(bound(imdIn, 1000e18, 6000e18)));
        uint256 got = token.balanceOf(a) - bal;
        // matured credit may cover part of a sell-back: keep the sold-before-gate-10 ghost exact
        if (got > 0 && got <= hook.sellAllowance(a) && _swap(a, false, -int256(got))) {
            if (hook.gatesOpen() < 10) ghostSoldBeforeGolden[a] += got;
        } else if (got > 0 && _swap(a, false, -int256(got))) {
            ghostRegression = true; // sold more than the allowance in the spike's own block
        }
        (,, uint256 volT,) = hook.gate(g + 1);
        if (hook.cumulativeVolumeUsd() < volT && hook.gatesOpen() != g) ghostSpikeOpenedGate = true;
        _track();
    }

    function sell(uint256 who, uint256 frac) external {
        address a = _actor(who);
        bool golden = hook.gatesOpen() >= 10;
        uint256 allowance = hook.sellAllowance(a);
        uint256 bal = token.balanceOf(a);
        uint256 cap = allowance < bal ? allowance : bal;
        if (cap < 1e12) return;
        uint256 amount = bound(frac, 1e12, cap);
        UnlockV2Hook.Rights memory before = hook.rightsOf(a);
        // the block's first official swap reads the settled FDV in beforeSwap and may open gates
        // (up to the final bypass) before its own quota check
        bool readingPending = hook.lastFdvBlock() != block.number;
        if (!_swap(a, false, -int256(amount))) {
            // an earlier sell can drain the mock position and park the price at the swap limit; the
            // pool manager then rejects any further sell before the hook runs. That is pool liquidity,
            // not a quota decision, so only other reverts count as unexpected.
            if (lastSwapError != Pool.PriceLimitAlreadyExceeded.selector) ghostUnexpectedRevert = true;
            return;
        }
        if (readingPending && hook.gatesOpen() >= 10) golden = true;
        if (!golden) {
            ghostSoldBeforeGolden[a] += amount;
            UnlockV2Hook.Rights memory r = hook.rightsOf(a);
            if (uint256(r.buySold) + r.otherSold != uint256(before.buySold) + before.otherSold + amount) {
                ghostRegression = true;
            }
        }
        _track();
    }

    function sellTooMuch(uint256 who) external {
        address a = _actor(who);
        // let this block's settled FDV reading happen first: sellAllowance() does not preview it
        if (hook.lastFdvBlock() != block.number) _swap(a, true, -1e15);
        if (hook.lastFdvBlock() != block.number || hook.gatesOpen() >= 10) return;
        uint256 allowance = hook.sellAllowance(a);
        if (token.balanceOf(a) <= allowance + 1e12) return;
        // selling more than the allowance must always fail
        if (_swap(a, false, -int256(allowance + 1e12))) ghostRegression = true;
        _track();
    }

    function burn(uint256 who, uint256 amount) external {
        address a = _actor(who);
        uint256 bal = token.balanceOf(a);
        if (bal == 0) return;
        amount = bound(amount, 1, bal);
        uint256 allowanceBefore = hook.sellAllowance(a);
        vm.prank(a);
        token.burn(amount);
        if (hook.sellAllowance(a) > allowanceBefore) ghostRegression = true;
        _track();
    }

    function contribute(uint256 who, uint256 amount) external {
        address a = _actor(who);
        (uint8 g, uint256 maxAmount) = hook.contributionQuote();
        uint256 bal = token.balanceOf(a);
        if (g == 0 || maxAmount == 0 || bal == 0) return;
        uint256 cap = maxAmount < bal ? maxAmount : bal;
        amount = bound(amount, 1, cap);
        vm.prank(a);
        token.contribute(g, amount);
        _track();
    }

    function migrate(uint256 who, uint256 amount) external {
        address a = _actor(who);
        uint256 rem = vault.remainingCapacity();
        if (rem == 0) return;
        amount = bound(amount, 1, rem < 50_000_000e18 ? rem : 50_000_000e18);
        v1.mint(a, amount);
        vm.startPrank(a);
        v1.approve(address(vault), amount);
        vault.migrate(amount);
        vm.stopPrank();
        ghostMigrated += amount;
        _track();
    }

    function transfer(uint256 from, uint256 to, uint256 amount) external {
        address a = _actor(from);
        address b = _actor(to);
        uint256 bal = token.balanceOf(a);
        if (bal == 0) return;
        amount = bound(amount, 1, bal);
        uint256 allowanceB = hook.sellAllowance(b);
        vm.prank(a);
        token.transfer(b, amount);
        if (a != b && hook.sellAllowance(b) != allowanceB) ghostRegression = true;
        _track();
    }

    function warp(uint256 secs, bool refreshFeed) external {
        secs = bound(secs, 1, 20 days);
        vm.warp(vm.getBlockTimestamp() + secs);
        vm.roll(vm.getBlockNumber() + 1 + secs / 12);
        if (refreshFeed) feed.set(3000e8, vm.getBlockTimestamp());
        _track();
    }

    function redeem() external {
        if (hook.pendingFees() == 0) return;
        hook.redeemFees();
        _track();
    }

    function claim(uint256 who) external {
        address a = _actor(who);
        if (pot.claimable(a) == 0) return;
        vm.prank(a);
        uint256 got = pot.claim();
        ghostClaimed[a] += got;
        _track();
    }

    function checkpoint() external {
        pot.checkpoint();
        _track();
    }
}

/// @notice Invariants of the value-holding launch contracts (vault, pot, hook rights) over random sequences.
contract InvariantsTest is BaseTest {
    LaunchHandler internal handler;
    address internal carol = makeAddr("carol");

    function setUp() public override {
        super.setUp();
        fullLaunch();
        address[3] memory actors = [alice, bob, carol];
        handler = new LaunchHandler(token, hook, imd, v1, feed, authRouter, key, actors);
        for (uint256 i; i < 3; i++) {
            giveImd(actors[i], 1e24);
            // some uncredited swarm-share tokens for burns, contributions and transfers
            token.transfer(actors[i], 5_000_000e18);
        }
        targetContract(address(handler));
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 40
    function invariant_supplyConservedAndBurnsAccounted() public view {
        assertEq(token.totalSupply() + hook.totalBurned(), 1_000_000_000e18);
        assertLe(hook.gateBurned(), hook.totalBurned());
        assertEq(pot.totalPoints(), hook.totalBurned(), "one point per burned token");
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 40
    function invariant_migrationVaultBackedAndLocked() public view {
        assertGe(vault.remainingBacking(), vault.remainingCapacity(), "vault under-backed");
        assertEq(vault.totalMigrated(), handler.ghostMigrated());
        assertEq(vault.lockedV1(), vault.totalMigrated(), "V1 released or reused");
        assertLe(vault.totalMigrated(), vault.CAP());
        assertEq(vault.totalMigrated() + vault.remainingBacking(), 700_000_000e18);
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 40
    function invariant_rewardPotSolventAndConserved() public view {
        (uint256 accrued, uint256 vested,, uint256 paid, uint256 unredeemed, uint256 held,) = pot.solvency();
        assertEq(held + unredeemed, accrued - paid, "IMD held + claims != liabilities");
        assertLe(paid, vested);
        assertLe(vested, accrued);
        assertEq(pot.totalAccrued(), pot.totalRedeemed() + hook.pendingFees());
        assertTrue(pot.isSolvent());
        uint256 owed;
        uint256 claimedSum;
        for (uint256 i; i < 3; i++) {
            address a = handler.actorAt(i);
            (uint256 c, uint256 m) = pot.rewardsOf(a);
            owed += c + m;
            claimedSum += handler.ghostClaimed(a);
            assertEq(pot.accountOf(a).claimed, handler.ghostClaimed(a));
        }
        assertEq(claimedSum, paid);
        // entitlements never exceed what has been vested (rounding only ever favours the pot)
        assertLe(owed + paid, vested);
        assertEq(imd.balanceOf(OWNER), 0, "owner never receives reward IMD");
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 40
    function invariant_rightsAndGatesMonotonic() public view {
        assertFalse(handler.ghostRegression(), "gate/volume regressed, burn/transfer created rights, or oversell");
        assertFalse(handler.ghostUnexpectedRevert(), "sell within allowance reverted");
        assertLe(hook.gatesOpen(), 10);
        assertFalse(handler.ghostSpikeOpenedGate(), "a same-block spike opened an FDV gate");
        assertFalse(handler.ghostGatePriceAboveSpot(), "gate IMD price above spot");
        assertFalse(handler.ghostPreviewMismatch(), "pendingGatesOpen() did not preview the block's reading");
        assertGt(hook.trackedImdPerEth(), 0, "reference tracker lost its seed");
        assertLe(hook.trackedAt(), block.timestamp);
        for (uint256 i; i < 3; i++) {
            address a = handler.actorAt(i);
            UnlockV2Hook.Rights memory r = hook.rightsOf(a);
            if (hook.gatesOpen() < 10) {
                assertEq(uint256(r.buySold) + r.otherSold, handler.ghostSoldBeforeGolden(a));
            }
        }
        assertTrue(hook.activated());
    }
}
