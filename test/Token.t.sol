// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseTest} from "./Base.t.sol";
import {UnlockV2Token} from "../src/UnlockV2Token.sol";
import {UnlockV2Hook} from "../src/UnlockV2Hook.sol";
import {MockERC20} from "./utils/Mocks.sol";

contract TokenTest is BaseTest {
    function test_metadataAndSupply() public view {
        assertEq(token.name(), "UNLOCK V2");
        assertEq(token.symbol(), "UNLK2");
        assertEq(token.decimals(), 18);
        assertEq(token.totalSupply(), 1_000_000_000e18);
        assertEq(token.balanceOf(address(this)), 1_000_000_000e18);
        assertEq(token.factory(), address(this));
    }

    function test_allocationSumsToSupply() public view {
        (uint256 p, uint256 s, uint256 m, uint256 f) = hook.allocation();
        assertEq(p + s + m + f, token.totalSupply());
        assertEq(p, 150_000_000e18);
        assertEq(s, 100_000_000e18);
        assertEq(m, 700_000_000e18);
        assertEq(f, 50_000_000e18);
    }

    function test_hookBoundDuringLaunch() public view {
        assertEq(token.hook(), address(hook));
        assertTrue(hook.isBound());
    }

    function test_registerHook_rejectsSecondAndLate() public {
        vm.expectRevert(UnlockV2Token.HookAlreadyRegistered.selector);
        token.registerHook(address(this));

        UnlockV2Token fresh = new UnlockV2Token();
        vm.prank(alice);
        vm.expectRevert(UnlockV2Token.NotLaunchFactory.selector);
        fresh.registerHook(alice);

        fresh.transfer(alice, 1);
        vm.expectRevert(UnlockV2Token.NotDuringLaunch.selector);
        fresh.registerHook(address(this));
    }

    function test_transfersMoveExactAmounts() public {
        // wallet -> wallet
        token.transfer(alice, 100e18);
        vm.prank(alice);
        token.transfer(bob, 40e18);
        assertEq(token.balanceOf(alice), 60e18);
        assertEq(token.balanceOf(bob), 40e18);
        // contract -> contract (vault and reward pot are contracts)
        token.transfer(address(vault), 10e18);
        assertEq(token.balanceOf(address(vault)), 10e18);
        // launch factory moves with everything in force
        token.transfer(address(pot), 5e18);
        assertEq(token.balanceOf(address(pot)), 5e18);
    }

    function test_burnReducesSupplyAndReportsToHook() public {
        token.transfer(alice, 100e18);
        vm.prank(alice);
        token.burn(30e18);
        assertEq(token.totalSupply(), 1_000_000_000e18 - 30e18);
        assertEq(token.balanceOf(alice), 70e18);
        assertEq(hook.totalBurned(), 30e18);
        assertEq(pot.points(alice), 30e18);
        assertEq(pot.totalPoints(), 30e18);
    }

    function test_burn_failsWithoutBalance() public {
        vm.prank(alice);
        vm.expectRevert();
        token.burn(1);
    }

    function test_onBurn_onlyToken() public {
        vm.expectRevert(UnlockV2Hook.NotToken.selector);
        hook.onBurn(alice, 1);
    }

    function test_noMintOrAdminSurface() public view {
        // The token exposes exactly: ERC20, burn, registerHook, factory, hook. No owner.
        assertEq(token.hook(), address(hook));
    }
}
