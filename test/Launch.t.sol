// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseTest} from "./Base.t.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {CustomRevert} from "v4-core/libraries/CustomRevert.sol";
import {UnlockV2Hook} from "../src/UnlockV2Hook.sol";

contract LaunchTest is BaseTest {
    using PoolIdLibrary for PoolKey;

    function test_referencePoolIdMatchesMainnet() public pure {
        PoolKey memory k = PoolKey({
            currency0: CurrencyLibrary.ADDRESS_ZERO,
            currency1: Currency.wrap(0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7),
            fee: 10000,
            tickSpacing: 200,
            hooks: IHooks(address(0))
        });
        assertEq(PoolId.unwrap(k.toId()), 0xb07d640fd9e2eb9dc81b953c8e4fd006bdfeaf276010fb5418eb763ca15abfb3);
    }

    function test_permissionsMatchAddressFlags() public view {
        assertEq(uint160(address(hook)) & Hooks.ALL_HOOK_MASK, hook.requiredAddressFlags());
        Hooks.Permissions memory p = hook.getHookPermissions();
        assertTrue(
            p.beforeInitialize && p.beforeAddLiquidity && p.beforeSwap && p.afterSwap && p.beforeSwapReturnDelta
                && p.afterSwapReturnDelta
        );
        assertFalse(p.beforeRemoveLiquidity || p.afterRemoveLiquidity || p.afterAddLiquidity);
        assertEq(hook.requiredAddressFlags(), 0x28CC);
    }

    function test_factoryInitializesIntendedPoolOnce() public {
        initOfficialPool();
        assertTrue(hook.poolInitialized());
        assertEq(hook.tokenIsCurrency0(), tokenIs0);
        vm.expectRevert();
        manager.initialize(key, TickMath.getSqrtPriceAtTick(officialTick()));
    }

    function test_nonFactoryCannotInitialize() public {
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.beforeInitialize.selector,
                abi.encodeWithSelector(UnlockV2Hook.NotFactory.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        manager.initialize(key, TickMath.getSqrtPriceAtTick(officialTick()));
        assertFalse(hook.poolInitialized());
    }

    function test_wrongKeyRejected() public {
        PoolKey memory bad = key;
        bad.fee = 3000;
        vm.expectRevert();
        manager.initialize(bad, TickMath.getSqrtPriceAtTick(officialTick()));
        bad = key;
        bad.tickSpacing = 200;
        vm.expectRevert();
        manager.initialize(bad, TickMath.getSqrtPriceAtTick(officialTick()));
        // a pool with a foreign currency
        bad = key;
        if (tokenIs0) bad.currency1 = Currency.wrap(address(v1));
        else bad.currency0 = Currency.wrap(address(v1));
        if (Currency.unwrap(bad.currency0) > Currency.unwrap(bad.currency1)) {
            (bad.currency0, bad.currency1) = (bad.currency1, bad.currency0);
        }
        vm.expectRevert();
        manager.initialize(bad, TickMath.getSqrtPriceAtTick(0));
    }

    function test_callbacksOnlyFromPoolManager() public {
        vm.expectRevert(UnlockV2Hook.NotPoolManager.selector);
        hook.beforeInitialize(address(this), key, 0);
        vm.expectRevert(UnlockV2Hook.NotPoolManager.selector);
        hook.unlockCallback("");
    }

    function test_liquidityWorksWhileTradingClosed_swapsBlocked() public {
        initOfficialPool();
        seedOfficialLiquidity();
        assertFalse(hook.activated());
        giveImd(alice, 1e21);
        vm.expectRevert();
        buy(alice, -1e18);
    }

    function test_activate_requirements() public {
        vm.prank(alice);
        vm.expectRevert(UnlockV2Hook.NotOwner.selector);
        hook.activate();

        vm.prank(OWNER);
        vm.expectRevert(UnlockV2Hook.PoolNotInitialized.selector);
        hook.activate();

        initOfficialPool();
        seedOfficialLiquidity();
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(UnlockV2Hook.MigrationNotFunded.selector, 0, 700_000_000e18));
        hook.activate();

        token.transfer(address(vault), 700_000_000e18);
        // reference pool missing
        vm.prank(OWNER);
        vm.expectRevert(UnlockV2Hook.ReferenceUnavailable.selector);
        hook.activate();

        initReferencePool();
        // initialized but no liquidity
        vm.prank(OWNER);
        vm.expectRevert(UnlockV2Hook.ReferenceUnavailable.selector);
        hook.activate();

        seedReferenceLiquidity();
        // stale feed
        feed.set(ETH_USD, vm.getBlockTimestamp() - 91 minutes);
        vm.prank(OWNER);
        vm.expectRevert(UnlockV2Hook.ReferenceUnavailable.selector);
        hook.activate();
        feed.set(ETH_USD, vm.getBlockTimestamp());

        // wrong decimals
        feed.setDecimals(18);
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(UnlockV2Hook.FeedDecimalsMismatch.selector, 18));
        hook.activate();
        feed.setDecimals(8);

        vm.prank(OWNER);
        hook.activate();
        assertTrue(hook.activated());
        assertTrue(hook.isReferenceAvailable());
        // founder credit exactly 50m in the "other" bucket
        UnlockV2Hook.Rights memory r = hook.rightsOf(OWNER);
        assertEq(r.otherCredited, 50_000_000e18);
        assertEq(r.buyCredited, 0);

        // sealed
        vm.startPrank(OWNER);
        vm.expectRevert(UnlockV2Hook.Sealed.selector);
        hook.activate();
        vm.expectRevert(UnlockV2Hook.Sealed.selector);
        hook.setRouter(address(authRouter), true);
        vm.expectRevert(UnlockV2Hook.Sealed.selector);
        hook.setSwarmDistributor(alice);
        vm.stopPrank();
    }

    function test_activate_wrongChain() public {
        initOfficialPool();
        seedOfficialLiquidity();
        token.transfer(address(vault), 700_000_000e18);
        initReferencePool();
        seedReferenceLiquidity();
        vm.chainId(1);
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(UnlockV2Hook.WrongChain.selector, 1));
        hook.activate();
    }

    function test_setup_onlyOwner() public {
        vm.prank(alice);
        vm.expectRevert(UnlockV2Hook.NotOwner.selector);
        hook.setRouter(address(authRouter), true);
        vm.prank(alice);
        vm.expectRevert(UnlockV2Hook.NotOwner.selector);
        hook.setSwarmDistributor(alice);
        vm.prank(OWNER);
        vm.expectRevert(UnlockV2Hook.ZeroAddress.selector);
        hook.setRouter(address(0), true);
    }

    function test_pricing_initialFdvBelowGate1() public {
        fullLaunch();
        (uint256 imdUsd, bool ok) = hook.imdUsdPrice();
        assertTrue(ok);
        // ~3000 USD / ~2981 IMD per ETH
        assertApproxEqRel(imdUsd, 1.0064e18, 0.01e18);
        (uint256 fdv, bool ok2) = hook.fdvUsd();
        assertTrue(ok2);
        assertApproxEqRel(fdv, 100_000e18, 0.03e18);
        assertEq(hook.gatesOpen(), 0);
    }

    function test_pricing_invalidFeedStates() public {
        fullLaunch();
        feed.set(0, vm.getBlockTimestamp());
        (, bool ok) = hook.imdUsdPrice();
        assertFalse(ok);
        feed.set(ETH_USD, vm.getBlockTimestamp() + 1);
        (, ok) = hook.imdUsdPrice();
        assertFalse(ok);
        feed.set(ETH_USD, vm.getBlockTimestamp());
        feed.setRounds(5, 4);
        (, ok) = hook.imdUsdPrice();
        assertFalse(ok);
        feed.setRounds(5, 5);
        feed.setRevert(true);
        (, ok) = hook.imdUsdPrice();
        assertFalse(ok);
        feed.setRevert(false);
        (, ok) = hook.imdUsdPrice();
        assertTrue(ok);
    }
}
