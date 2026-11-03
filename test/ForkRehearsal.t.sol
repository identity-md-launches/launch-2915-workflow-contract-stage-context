// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";
import {PoolModifyLiquidityTest} from "v4-core/test/PoolModifyLiquidityTest.sol";

import {UnlockV2Token} from "src/UnlockV2Token.sol";
import {UnlockV2Hook} from "src/UnlockV2Hook.sol";
import {MigrationVault} from "src/MigrationVault.sol";
import {RewardPot} from "src/RewardPot.sol";

interface IUniversalRouter {
    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline) external payable;
    function msgSender() external view returns (address);
}

interface IPermit2 {
    function approve(address token, address spender, uint160 amount, uint48 expiration) external;
}

/// @dev v4-periphery IV4Router.ExactInputSingleParams / ExactOutputSingleParams as deployed in the
///      Ethereum Universal Router (0x66a9...8Af).
struct ExactInputSingleParams {
    PoolKey poolKey;
    bool zeroForOne;
    uint128 amountIn;
    uint128 amountOutMinimum;
    bytes hookData;
}

struct ExactOutputSingleParams {
    PoolKey poolKey;
    bool zeroForOne;
    uint128 amountOut;
    uint128 amountInMaximum;
    bytes hookData;
}

/// @title Mainnet-fork rehearsal (chain 1, block 26333609)
/// @notice FORK checks: the launch is deployed into a fork of Ethereum mainnet at the pinned block and run
///         against the LIVE PoolManager, IMD token, UNLOCK V1 token, Chainlink ETH/USD feed, the live
///         ETH/IMD v4 reference pool and the live Uniswap Universal Router (a real standard router that
///         exposes msgSender()). Balances are created with `deal` inside the fork: no real-money trade,
///         no live transaction, no activation of anything on chain. Skipped when MAINNET_RPC_URL is unset.
contract ForkRehearsalTest is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint256 internal constant FORK_BLOCK = 26333609;

    IPoolManager internal constant PM = IPoolManager(0x000000000004444c5dc75cB358380D2e3dE08A90);
    address internal constant IMD = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;
    address internal constant V1 = 0x99fA82B022BE4575891a43b757Bc770691E18fDa;
    address internal constant FEED = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;
    IUniversalRouter internal constant UR = IUniversalRouter(0x66a9893cC07D91D95644AEDD05D03f95e1dBA8Af);
    IPermit2 internal constant PERMIT2 = IPermit2(0x000000000022D473030F116dDEE9F6B43aC78BA3);
    address internal constant OWNER = 0x48E4E74fE1d0c14404cEB57B9fec5b21329C6ec9;
    bytes32 internal constant REF_POOL_ID = 0xb07d640fd9e2eb9dc81b953c8e4fd006bdfeaf276010fb5418eb763ca15abfb3;

    uint160 internal constant FLAGS = Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
        | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;

    UnlockV2Token internal token;
    UnlockV2Hook internal hook;
    MigrationVault internal vault;
    RewardPot internal pot;
    PoolModifyLiquidityTest internal lpRouter;
    PoolKey internal key;
    bool internal tokenIs0;

    address internal alice = makeAddr("fork-alice");
    address internal bob = makeAddr("fork-bob");

    /// @dev Forks the pinned block and deploys token + hook + official pool with liquidity (trading closed).
    function _fork() internal returns (bool) {
        string memory url = vm.envOr("MAINNET_RPC_URL", string(""));
        if (bytes(url).length == 0) {
            vm.skip(true);
            return false;
        }
        vm.createSelectFork(url, FORK_BLOCK);
        assertEq(block.number, FORK_BLOCK);

        token = new UnlockV2Token();
        address hookAddr = address(uint160(uint160(0xA11CE5) << 40) | FLAGS);
        assertEq(hookAddr.code.length, 0);
        deployCodeTo(
            "UnlockV2Hook.sol:UnlockV2Hook",
            abi.encode(PM, address(token), IMD, address(this), OWNER, V1, FEED, uint256(1)),
            hookAddr
        );
        hook = UnlockV2Hook(hookAddr);
        vault = hook.migrationVault();
        pot = hook.rewardPot();
        assertTrue(hook.isBound());

        tokenIs0 = address(token) < IMD;
        key = PoolKey({
            currency0: Currency.wrap(tokenIs0 ? address(token) : IMD),
            currency1: Currency.wrap(tokenIs0 ? IMD : address(token)),
            fee: 12500,
            tickSpacing: 60,
            hooks: IHooks(hookAddr)
        });
        // ~1e-5 IMD per UNLK2 (launch FDV well below gate 1 at the live IMD price)
        int24 tick = tokenIs0 ? int24(-115140) : int24(115140);
        PM.initialize(key, TickMath.getSqrtPriceAtTick(tick));

        lpRouter = new PoolModifyLiquidityTest(PM);
        deal(IMD, address(this), 1_000_000e18);
        IERC20(IMD).approve(address(lpRouter), type(uint256).max);
        token.approve(address(lpRouter), type(uint256).max);
        // wide range around the launch price (liquidity is added while swaps are still closed)
        lpRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({tickLower: tick - 60000, tickUpper: tick + 60000, liquidityDelta: 2e23, salt: 0}),
            ""
        );
        return true;
    }

    function _activate() internal {
        token.transfer(OWNER, 750_000_000e18);
        vm.startPrank(OWNER);
        token.transfer(address(vault), 700_000_000e18);
        hook.setRouter(address(UR), true);
        hook.activate();
        vm.stopPrank();
    }

    function _approveViaPermit2(address who, address tok) internal {
        vm.startPrank(who);
        IERC20(tok).approve(address(PERMIT2), type(uint256).max);
        PERMIT2.approve(tok, address(UR), type(uint160).max, type(uint48).max);
        vm.stopPrank();
    }

    function _urSwap(address who, bool buy, bool exactIn, uint128 amount, uint128 limit) internal {
        bool zeroForOne = buy ? !tokenIs0 : tokenIs0;
        Currency cin = zeroForOne ? key.currency0 : key.currency1;
        Currency cout = zeroForOne ? key.currency1 : key.currency0;
        bytes memory actions;
        bytes[] memory params = new bytes[](3);
        if (exactIn) {
            actions = abi.encodePacked(uint8(0x06), uint8(0x0c), uint8(0x0f));
            params[0] = abi.encode(ExactInputSingleParams(key, zeroForOne, amount, limit, ""));
            params[1] = abi.encode(cin, uint256(amount));
            params[2] = abi.encode(cout, uint256(limit));
        } else {
            actions = abi.encodePacked(uint8(0x08), uint8(0x0c), uint8(0x0f));
            params[0] = abi.encode(ExactOutputSingleParams(key, zeroForOne, amount, limit, ""));
            params[1] = abi.encode(cin, uint256(limit));
            params[2] = abi.encode(cout, uint256(amount));
        }
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(actions, params);
        vm.prank(who);
        UR.execute(hex"10", inputs, block.timestamp + 60);
    }

    // ------------------------------------------------------------------ live references

    function test_fork_liveReferencesAndActivation() public {
        if (!_fork()) return;
        // live dependencies exist at the pinned block
        assertGt(address(PM).code.length, 0);
        assertGt(IMD.code.length, 0);
        assertGt(V1.code.length, 0);
        assertGt(FEED.code.length, 0);
        assertGt(address(UR).code.length, 0);
        assertEq(PoolId.unwrap(hook.referencePoolId()), REF_POOL_ID);
        assertGt(PM.getLiquidity(PoolId.wrap(REF_POOL_ID)), 0, "reference pool has no liquidity");

        // the 700m cap cannot cover the live V1 supply
        assertGt(IERC20(V1).totalSupply(), vault.CAP());

        // live prices are valid and IMD/USD is consistent with the feed and the reference pool
        (uint256 imdUsd, bool ok) = hook.imdUsdPrice();
        assertTrue(ok, "live IMD/USD invalid");
        assertGt(imdUsd, 0);
        assertTrue(hook.isReferenceAvailable());

        // closed until activation, owner-only activation, unfunded activation refused
        vm.expectRevert(UnlockV2Hook.NotOwner.selector);
        hook.activate();
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(UnlockV2Hook.MigrationNotFunded.selector, 0, 700_000_000e18));
        hook.activate();

        // swaps through the live Universal Router are closed before activation
        deal(IMD, alice, 1000e18);
        _approveViaPermit2(alice, IMD);
        vm.expectRevert();
        _urSwap(alice, true, true, 100e18, 0);

        _activate();
        assertTrue(hook.activated());
        assertEq(hook.rightsOf(OWNER).otherCredited, 50_000_000e18);
        assertEq(token.balanceOf(OWNER), 50_000_000e18);
        assertEq(vault.remainingBacking(), 700_000_000e18);
        (uint256 fdv, bool fdvOk) = hook.fdvUsd();
        assertTrue(fdvOk);
        assertGt(fdv, 0);
        // sealed: no setter works any more
        vm.prank(OWNER);
        vm.expectRevert(UnlockV2Hook.Sealed.selector);
        hook.setRouter(address(UR), false);
    }

    // ------------------------------------------------------------------ live standard router

    function test_fork_universalRouterExactInAndExactOut_creditsRealTrader_feesConserved() public {
        if (!_fork()) return;
        _activate();
        deal(IMD, alice, 10_000e18);
        _approveViaPermit2(alice, IMD);
        _approveViaPermit2(alice, address(token));

        // exact-input buy of 100 IMD: reward fee is exactly 1% of the gross IMD input
        uint256 imdBefore = IERC20(IMD).balanceOf(alice);
        _urSwap(alice, true, true, 100e18, 0);
        assertEq(imdBefore - IERC20(IMD).balanceOf(alice), 100e18);
        uint256 fee1 = 1e18;
        assertEq(hook.pendingFees(), fee1);
        uint256 bought = token.balanceOf(alice);
        assertGt(bought, 0);

        // credited to alice (the router's msgSender), not to the router contract
        UnlockV2Hook.Rights memory r = hook.rightsOf(alice);
        assertEq(r.pendingBuy, bought);
        assertEq(hook.rightsOf(address(UR)).pendingBuy, 0);
        // a new buy matures only after one block
        assertEq(hook.sellAllowance(alice), 0);
        vm.expectRevert();
        _urSwap(alice, false, true, uint128(bought / 10), 0);
        vm.roll(block.number + 1);
        assertEq(hook.sellAllowance(alice), bought * 20 / 100);

        // exact-output buy of 1000 UNLK2: alice pays pool input + 1% of it
        uint256 imdMid = IERC20(IMD).balanceOf(alice);
        uint256 pendingMid = hook.pendingFees();
        _urSwap(alice, true, false, 1000e18, type(uint128).max);
        uint256 paid = imdMid - IERC20(IMD).balanceOf(alice);
        uint256 fee2 = hook.pendingFees() - pendingMid;
        assertGt(fee2, 0);
        // paid = Z + floor(Z/100), so fee2 == floor((paid - fee2)/100)
        assertEq(fee2, (paid - fee2) / 100);
        assertEq(token.balanceOf(alice), bought + 1000e18);

        // exact-output sell of 1 IMD: alice receives exactly 1 IMD, fee 1% of it
        vm.roll(block.number + 1);
        uint256 allowance = hook.sellAllowance(alice);
        uint256 tokBefore = token.balanceOf(alice);
        uint256 imdBeforeSell = IERC20(IMD).balanceOf(alice);
        _urSwap(alice, false, false, 1e18, type(uint128).max);
        assertEq(IERC20(IMD).balanceOf(alice) - imdBeforeSell, 1e18);
        uint256 soldTok = tokBefore - token.balanceOf(alice);
        assertEq(hook.sellAllowance(alice), allowance - soldTok);
        assertEq(hook.pendingFees(), fee1 + fee2 + 1e16);

        // conservation: every fee attributed in the pot equals the hook's claim; redemption moves it 1:1
        assertEq(pot.totalAccrued(), hook.pendingFees());
        uint256 total = hook.pendingFees();
        hook.redeemFees();
        assertEq(hook.pendingFees(), 0);
        assertEq(IERC20(IMD).balanceOf(address(pot)), total);
        assertEq(pot.totalRedeemed(), total);
        assertTrue(pot.isSolvent());

        // volume was counted once per swap at live prices
        assertGt(hook.cumulativeVolumeUsd(), 0);
        assertEq(hook.gatesOpen(), 0);
    }

    function test_fork_sellBeyondAllowanceRevertsThroughRouter() public {
        if (!_fork()) return;
        _activate();
        // bob only holds uncredited (transferred) tokens: the live router cannot sell them before gate 10
        vm.prank(OWNER);
        token.transfer(bob, 1000e18);
        _approveViaPermit2(bob, address(token));
        vm.expectRevert();
        _urSwap(bob, false, true, 1e18, 0);
        assertEq(token.balanceOf(bob), 1000e18);
    }

    /// Re-check of finding 3284f846 on live state: a spike bought through the live Universal Router is
    /// not read inside its own block and cannot be sold back there; the tracker is seeded from the live
    /// reference pool and the gate price never exceeds spot.
    function test_fork_spikeThroughLiveRouterOpensNothingInItsBlock() public {
        if (!_fork()) return;
        _activate();
        (uint256 spotRef,) = hook.imdUsdPrice();
        (uint256 gateRef, bool gv) = hook.gateImdUsdPrice();
        assertTrue(gv);
        assertEq(gateRef, spotRef, "tracker seeded at the live reference spot");
        assertGt(hook.trackedImdPerEth(), 0);
        assertEq(hook.trackedAt(), block.timestamp);

        deal(IMD, alice, 100_000e18);
        _approveViaPermit2(alice, IMD);
        _approveViaPermit2(alice, address(token));
        _urSwap(alice, true, true, 1e18, 0); // the block's settled reading
        assertEq(hook.lastFdvBlock(), block.number);
        uint256 settled = hook.lastFdvUsd();
        _urSwap(alice, true, true, 20_000e18, 0);
        (uint256 spotFdv, bool ok) = hook.fdvUsd();
        assertTrue(ok);
        assertGt(spotFdv, settled * 10, "the buy moved the spot FDV a lot");
        assertEq(hook.lastFdvUsd(), settled, "no re-read inside the block");
        assertEq(hook.gatesOpen(), 0, "spike opened a gate in its own block");
        uint256 bal = token.balanceOf(alice);
        vm.expectRevert();
        _urSwap(alice, false, true, uint128(bal), 0);
        assertEq(token.balanceOf(alice), bal);

        // held across a block boundary, the next block's first swap reads it (disclosed behaviour)
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 12);
        // the spike ran the test position to its price limit, so the next swap is a small sell
        // of matured buy credit
        _urSwap(alice, false, true, 1e18, 0);
        assertEq(hook.lastFdvBlock(), block.number);
        assertGt(hook.gatesOpen() == 10 ? spotFdv : hook.lastFdvUsd(), settled);
        (, uint256 fdvT1,,) = hook.gate(1);
        if (hook.lastFdvUsd() >= fdvT1) assertGt(hook.gatesOpen(), 0);
        else assertEq(hook.gatesOpen(), 0);
    }

    // ------------------------------------------------------------------ live V1 migration

    function test_fork_migrationWithLiveV1() public {
        if (!_fork()) return;
        // funding is all-or-nothing for activation, but migration works before activation once backed
        token.transfer(OWNER, 750_000_000e18);
        vm.prank(OWNER);
        token.transfer(address(vault), 700_000_000e18);

        deal(V1, alice, 1_000e18);
        vm.startPrank(alice);
        IERC20(V1).approve(address(vault), type(uint256).max);
        vault.migrate(400e18);
        vm.stopPrank();
        assertEq(token.balanceOf(alice), 400e18);
        assertEq(IERC20(V1).balanceOf(address(vault)), 400e18);
        assertEq(vault.lockedV1(), 400e18);
        assertEq(hook.rightsOf(alice).otherCredited, 400e18);
        // migrated tokens have 0% before gate 1
        assertEq(hook.sellAllowance(alice), 0);

        // locked V1 cannot be migrated again: alice only has 600 left
        vm.prank(alice);
        vm.expectRevert();
        vault.migrate(601e18);

        // the 700m cap: amounts above the remaining capacity are rejected
        deal(V1, bob, 800_000_000e18);
        vm.startPrank(bob);
        IERC20(V1).approve(address(vault), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(MigrationVault.ExceedsCapacity.selector, 700_000_000e18 - 400e18));
        vault.migrate(700_000_000e18);
        vault.migrate(700_000_000e18 - 400e18);
        vm.expectRevert(abi.encodeWithSelector(MigrationVault.ExceedsCapacity.selector, 0));
        vault.migrate(1);
        vm.stopPrank();
        assertEq(vault.remainingCapacity(), 0);
        assertEq(vault.remainingBacking(), 0);
        assertEq(vault.lockedV1(), 700_000_000e18);
    }

    // ------------------------------------------------------------------ live feed staleness

    function test_fork_staleLiveFeedSkipsProgressButTradingContinues() public {
        if (!_fork()) return;
        _activate();
        deal(IMD, alice, 10_000e18);
        _approveViaPermit2(alice, IMD);
        // the live Chainlink round at the pinned block is < 90 minutes old
        (uint256 p, bool ok) = hook.imdUsdPrice();
        assertTrue(ok);
        assertGt(p, 0);
        // nobody updates the forked feed: 2 hours later it is stale
        vm.warp(block.timestamp + 2 hours);
        (, ok) = hook.imdUsdPrice();
        assertFalse(ok);
        uint256 volBefore = hook.cumulativeVolumeUsd();
        _urSwap(alice, true, true, 100e18, 0);
        assertEq(hook.cumulativeVolumeUsd(), volBefore, "stale feed must not add volume");
        assertGt(token.balanceOf(alice), 0, "trading continues on a stale feed");
        assertEq(hook.pendingFees(), 1e18, "fee is still collected");
    }
}
