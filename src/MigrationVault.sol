// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IUnlockV2Hook} from "./interfaces/IUnlockV2Hook.sol";

/// @title UNLOCK V1 -> V2 migration vault
/// @notice Exchanges 1 V1 for 1 V2, locking V1 here forever. Hard aggregate cap of 700,000,000 V2,
///         first come first served. The vault has no owner, no withdrawal, no deadline and no way to
///         release or reuse deposited V1. It is created by the hook's constructor and funded by the
///         owner before activation.
contract MigrationVault {
    using SafeERC20 for IERC20;

    /// @notice Hard aggregate migration cap (the 700m reserve). Smaller than the V1 supply by design.
    uint256 public constant CAP = 700_000_000e18;

    IERC20 public immutable v1;
    IERC20 public immutable v2;
    IUnlockV2Hook public immutable hook;

    /// @notice Total V2 handed out through migration so far.
    uint256 public totalMigrated;

    event Migrated(address indexed account, uint256 amount);

    error ZeroAmount();
    error ExceedsCapacity(uint256 remaining);
    error InsufficientBacking(uint256 backing);

    constructor(address v1_, address v2_) {
        v1 = IERC20(v1_);
        v2 = IERC20(v2_);
        hook = IUnlockV2Hook(msg.sender);
    }

    /// @notice Capacity still available under the hard cap.
    function remainingCapacity() public view returns (uint256) {
        return CAP - totalMigrated;
    }

    /// @notice V2 actually held here and available to back migrations.
    function remainingBacking() public view returns (uint256) {
        return v2.balanceOf(address(this));
    }

    /// @notice True when the vault holds enough V2 to honour every remaining unit of capacity.
    function isFullyFunded() public view returns (bool) {
        return remainingBacking() >= remainingCapacity();
    }

    /// @notice V1 locked here forever.
    function lockedV1() external view returns (uint256) {
        return v1.balanceOf(address(this));
    }

    /// @notice Migrate `amount` V1 into `amount` V2. Caller must have approved this vault for V1.
    /// @dev The amount actually received in V1 must equal `amount` (a fee-on-transfer V1 would
    ///      revert the migration instead of leaving the cap and backing inconsistent).
    function migrate(uint256 amount) external {
        if (amount == 0) revert ZeroAmount();
        uint256 remaining = remainingCapacity();
        if (amount > remaining) revert ExceedsCapacity(remaining);
        uint256 backing = remainingBacking();
        if (backing < amount) revert InsufficientBacking(backing);

        totalMigrated += amount;

        uint256 before = v1.balanceOf(address(this));
        v1.safeTransferFrom(msg.sender, address(this), amount);
        require(v1.balanceOf(address(this)) - before == amount, "V1 amount mismatch");

        v2.safeTransfer(msg.sender, amount);
        hook.creditMigration(msg.sender, amount);
        emit Migrated(msg.sender, amount);
    }
}
