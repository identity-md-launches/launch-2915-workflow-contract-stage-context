// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseTest} from "./Base.t.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {UnlockV2Hook} from "../src/UnlockV2Hook.sol";
import {MigrationVault} from "../src/MigrationVault.sol";
import {MockDistributor, HookHarness} from "./utils/Mocks.sol";

contract CompanionsTest is BaseTest {
    // ------------------------------------------------------------------ migration

    function test_migrate_beforeActivation_andCapAccounting() public {
        token.transfer(address(vault), 700_000_000e18);
        v1.mint(alice, 1000e18);
        vm.startPrank(alice);
        v1.approve(address(vault), 1000e18);
        vault.migrate(600e18);
        vm.stopPrank();
        assertEq(token.balanceOf(alice), 600e18);
        assertEq(v1.balanceOf(address(vault)), 600e18);
        assertEq(vault.totalMigrated(), 600e18);
        assertEq(vault.remainingCapacity(), 700_000_000e18 - 600e18);
        assertEq(vault.remainingBacking(), 700_000_000e18 - 600e18);
        assertTrue(vault.isFullyFunded());
        assertEq(vault.lockedV1(), 600e18);
        UnlockV2Hook.Rights memory r = hook.rightsOf(alice);
        assertEq(r.otherCredited, 600e18);
    }

    function test_migrate_failures() public {
        v1.mint(alice, 1000e18);
        vm.startPrank(alice);
        v1.approve(address(vault), 1000e18);
        vm.expectRevert(MigrationVault.ZeroAmount.selector);
        vault.migrate(0);
        // unfunded vault
        vm.expectRevert(abi.encodeWithSelector(MigrationVault.InsufficientBacking.selector, 0));
        vault.migrate(1e18);
        vm.stopPrank();
        token.transfer(address(vault), 700_000_000e18);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(MigrationVault.ExceedsCapacity.selector, 700_000_000e18));
        vault.migrate(700_000_000e18 + 1);
        // no V1 approval / balance
        vm.prank(bob);
        vm.expectRevert();
        vault.migrate(1e18);
    }

    function test_migrate_capCannotCoverEntireV1Supply() public {
        token.transfer(address(vault), 700_000_000e18);
        // V1 supply is larger than the 700m cap: the last units are rejected first come first served
        v1.mint(alice, 700_000_000e18);
        v1.mint(bob, 1e18);
        vm.startPrank(alice);
        v1.approve(address(vault), type(uint256).max);
        vault.migrate(700_000_000e18);
        vm.stopPrank();
        assertEq(vault.remainingCapacity(), 0);
        assertEq(vault.remainingBacking(), 0);
        vm.startPrank(bob);
        v1.approve(address(vault), 1e18);
        vm.expectRevert(abi.encodeWithSelector(MigrationVault.ExceedsCapacity.selector, 0));
        vault.migrate(1e18);
        vm.stopPrank();
        // nothing in the vault can be withdrawn: there is no such function and V1 stays locked
        assertEq(v1.balanceOf(address(vault)), 700_000_000e18);
    }

    function test_creditMigration_onlyVault() public {
        vm.expectRevert(UnlockV2Hook.NotVault.selector);
        hook.creditMigration(alice, 1);
    }

    // ------------------------------------------------------------------ swarm claims

    function test_swarmClaimCreditedOnceWithEvidence() public {
        // two-leaf tree: (0, alice, 10e18), (1, bob, 20e18)
        bytes32 leafA = keccak256(abi.encodePacked(uint256(0), alice, uint256(10e18)));
        bytes32 leafB = keccak256(abi.encodePacked(uint256(1), bob, uint256(20e18)));
        bytes32 root =
            leafA < leafB ? keccak256(abi.encodePacked(leafA, leafB)) : keccak256(abi.encodePacked(leafB, leafA));
        MockDistributor dist = new MockDistributor(root);
        bytes32[] memory proof = new bytes32[](1);
        proof[0] = leafB;

        vm.expectRevert(UnlockV2Hook.DistributorNotSet.selector);
        hook.creditSwarmClaim(0, alice, 10e18, proof);

        vm.prank(OWNER);
        hook.setSwarmDistributor(address(dist));

        // not claimed yet on the distributor
        vm.expectRevert(UnlockV2Hook.SwarmClaimNotFound.selector);
        hook.creditSwarmClaim(0, alice, 10e18, proof);

        dist.setClaimed(0, true);
        // wrong amount -> bad proof
        vm.expectRevert(UnlockV2Hook.InvalidProof.selector);
        hook.creditSwarmClaim(0, alice, 11e18, proof);

        hook.creditSwarmClaim(0, alice, 10e18, proof);
        assertEq(hook.rightsOf(alice).otherCredited, 10e18);
        vm.expectRevert(abi.encodeWithSelector(UnlockV2Hook.SwarmIndexAlreadyCredited.selector, 0));
        hook.creditSwarmClaim(0, alice, 10e18, proof);
    }

    // ------------------------------------------------------------------ gate logic (harness)

    function _harness() internal returns (HookHarness h) {
        h = new HookHarness(
            IPoolManager(address(manager)),
            address(token),
            address(imd),
            address(this),
            OWNER,
            address(v1),
            address(feed),
            block.chainid
        );
    }

    function test_gateTable() public view {
        uint8[10] memory pcts = [25, 30, 35, 40, 50, 60, 70, 80, 90, 100];
        uint256[10] memory fdvs = [
            uint256(250_000),
            500_000,
            1_000_000,
            2_000_000,
            3_500_000,
            5_000_000,
            8_000_000,
            12_000_000,
            18_000_000,
            25_000_000
        ];
        uint256[10] memory vols = [
            uint256(125_000),
            375_000,
            750_000,
            1_500_000,
            2_500_000,
            4_000_000,
            6_000_000,
            9_000_000,
            12_500_000,
            20_000_000
        ];
        uint256[10] memory burns = [
            uint256(25_000_000),
            22_000_000,
            19_000_000,
            16_000_000,
            13_000_000,
            10_000_000,
            8_000_000,
            6_000_000,
            4_000_000,
            2_000_000
        ];
        for (uint8 i = 1; i <= 10; i++) {
            (uint8 p, uint256 f, uint256 v, uint256 b) = hook.gate(i);
            assertEq(p, pcts[i - 1]);
            assertEq(f, fdvs[i - 1] * 1e18);
            assertEq(v, vols[i - 1] * 1e18);
            assertEq(b, burns[i - 1] * 1e18);
        }
    }

    function test_gatesByVolume_sequentialAndMonotonic() public {
        HookHarness h = _harness();
        h.addVolume(124_999e18);
        h.advance(0, false);
        assertEq(h.gatesOpen(), 0);
        h.addVolume(1e18);
        h.advance(0, false);
        assertEq(h.gatesOpen(), 1);
        // one observation crossing several volume thresholds
        h.addVolume(1_500_000e18);
        h.advance(0, false);
        assertEq(h.gatesOpen(), 4);
        // invalid price does not matter for volume; falling fdv does not relock
        h.advance(0, true);
        assertEq(h.gatesOpen(), 4);
        h.addVolume(100_000_000e18);
        h.advance(0, false);
        assertEq(h.gatesOpen(), 10);
    }

    function test_gatesByBurn_perGateTargets() public {
        HookHarness h = _harness();
        h.addBurn(24_000_000e18);
        h.advance(0, false);
        assertEq(h.gatesOpen(), 0);
        assertEq(h.burnProgress(), 24_000_000e18);
        assertEq(h.gateBurnRemaining(), 1_000_000e18);
        h.addBurn(1_000_000e18); // gate 1 target (25m) met exactly
        h.advance(0, false);
        assertEq(h.gatesOpen(), 1);
        assertEq(h.burnProgress(), 0);
        assertEq(h.gateBurnRemaining(), 22_000_000e18);
        h.addBurn(5_000_000e18);
        // a gate opened by FDV resets the burn counter for the next gate
        h.advance(500_000e18, true);
        assertEq(h.gatesOpen(), 2);
        assertEq(h.burnProgress(), 0);
        assertEq(h.gateBurnRemaining(), 19_000_000e18);
    }

    function testFuzz_gatesNeverDecrease(uint256 fdvA, uint256 fdvB, uint256 vol) public {
        HookHarness h = _harness();
        fdvA = bound(fdvA, 0, 50_000_000e18);
        fdvB = bound(fdvB, 0, 50_000_000e18);
        vol = bound(vol, 0, 50_000_000e18);
        h.advance(fdvA, true);
        uint8 g1 = h.gatesOpen();
        h.advance(fdvB, true);
        assertGe(h.gatesOpen(), g1);
        uint8 g2 = h.gatesOpen();
        h.addVolume(vol);
        h.advance(0, false);
        assertGe(h.gatesOpen(), g2);
        // every open gate had at least one threshold met
        for (uint8 i = 1; i <= h.gatesOpen(); i++) {
            (, uint256 f, uint256 v,) = h.gate(i);
            assertTrue(fdvA >= f || fdvB >= f || vol >= v);
        }
    }
}
