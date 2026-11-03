// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice What the RewardPot needs from the hook that collects the 1% IMD reward fee.
interface IRewardFeeSource {
    /// @notice IMD reward fees already attributed but still held as ERC-6909 claims in the PoolManager.
    function pendingFees() external view returns (uint256);

    /// @notice Permissionless: moves every pending IMD claim from the PoolManager into the RewardPot.
    function redeemFees() external returns (uint256);
}
