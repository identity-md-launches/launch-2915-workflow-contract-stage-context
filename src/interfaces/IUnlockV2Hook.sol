// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Callbacks the token and the companion contracts make into the hook.
interface IUnlockV2Hook {
    /// @notice Called by the UNLK2 token after a holder burned `amount`.
    function onBurn(address account, uint256 amount) external;

    /// @notice Called by the migration vault after `account` migrated `amount` V1 -> V2.
    function creditMigration(address account, uint256 amount) external;
}
